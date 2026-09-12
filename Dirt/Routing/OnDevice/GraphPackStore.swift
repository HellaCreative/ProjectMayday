import CoreLocation
import CryptoKit
import Foundation
import Observation

/// Exact route-geometry cache for navigation pack requirements.
///
/// Keeping the coordinate signature (rather than only a hash) makes reuse
/// collision-free while avoiding repeated administrative-polygon walks on an
/// unchanged route.
struct NavigationRegionRequirementCache {
    private struct CoordinateKey: Equatable {
        let latitudeBits: UInt64
        let longitudeBits: UInt64

        nonisolated init(_ coordinate: CLLocationCoordinate2D) {
            latitudeBits = coordinate.latitude.bitPattern
            longitudeBits = coordinate.longitude.bitPattern
        }
    }

    private var coordinateKeys: [CoordinateKey] = []
    private var cachedRegionIds: [String] = []

    mutating func regionIds(
        for coordinates: [CLLocationCoordinate2D],
        resolve: ([CLLocationCoordinate2D]) -> [String]
    ) -> [String] {
        let keys = coordinates.map(CoordinateKey.init)
        if keys == coordinateKeys {
            return cachedRegionIds
        }
        let resolved = resolve(coordinates)
        coordinateKeys = keys
        cachedRegionIds = resolved
        return resolved
    }
}

/// Province / state routing packs for offline detours (download once on Wi‑Fi).
@Observable
@MainActor
final class GraphPackStore {
    enum Phase: Equatable {
        case idle
        case downloading
        case ready
        case skipped(String)
        case failed(String)
    }

    enum InstallState: Equatable {
        case available
        case installed
        case downloading(Double)
        case unavailable
    }

    struct RegionInfo: Identifiable, Equatable {
        enum Country: String {
            case canada
            case unitedStates
        }

        let id: String
        let title: String
        let subtitle: String
        /// Approximate bytes for UI (brain-only until geometry ships).
        let approxBytes: Int64
        var install: InstallState
        var exactBytes: Int64?
        var country: Country
        var revisionState: PackRevisionState = .missing
    }

    struct InstalledPackManagementRow: Identifiable, Equatable {
        let id: String
        let title: String
        let revisionState: PackRevisionState
        let bytes: Int64
        let canDelete: Bool
        let canDownload: Bool

        var revisionLabel: String {
            switch revisionState {
            case .current:
                return "Current approved revision"
            case .stale:
                return "Update available — using installed revision"
            case .missing:
                return "Not installed"
            }
        }
    }

    private enum Prefs {
        static let installed = "dirt.packs.installedRegionIds"
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var loadedRegionIds: [String] = []
    private(set) var activePack: GraphV2Pack?
    private(set) var regions: [RegionInfo] = GraphPackStore.catalogSeed
    private(set) var lastManifestVersion: String = "v1"
    private(set) var verifiedInstalledRegionIds: Set<String> = []
    private(set) var isRefreshingCatalog = false
    /// Fuel stations loaded from installed `fuel.v1.json` sidecars.
    private var packedFuelByRegion: [String: [POIFeature]] = [:]

    /// When true, a checksum-valid installed revision is not replaced in place.
    var protectInstalledRevisions = false

    /// Fired when a quiet pack finishes — unused after waypoint-driven acquisition.
    var onQuietPackReady: ((String) -> Void)?

    private var task: Task<Void, Never>?
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    /// Region ids started by auto-download (cancelled on End Nav).
    private var quietDownloadIds: Set<String> = []
    /// Last primary region we already considered for auto-download (spam guard).
    private var lastAutoDownloadRegionId: String?
    private var publishedIds: Set<String> = ["ns"] // known live until manifest loads
    private var catalogIdentityLoaded = false
    private var manifestFilesByRegion: [String: [PackManifest.File]] = [:]
    @ObservationIgnored private var navigationRegionRequirementCache = NavigationRegionRequirementCache()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 600
        return URLSession(configuration: cfg)
    }()

    private var cacheRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("dirt-graph-packs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// True while any quiet auto-download is in flight (one region at a time).
    var isQuietDownloadInFlight: Bool { !quietDownloadIds.isEmpty }

    init() {
        seedLocalV3PacksFromDocumentsIfPresent()
        refreshInstalledFromDisk()
        Task { await refreshCatalog() }
    }

    /// Phase E1 ride-test: drop `graph.v3.bin` + `geometry.v1.bin` into
    /// Documents/DirtLocalPacks/<region>/ and they install into the pack cache
    /// (preferring v3 over catalog v2). Keeps prior v2 bytes untouched.
    private func seedLocalV3PacksFromDocumentsIfPresent() {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let root = docs.appendingPathComponent("DirtLocalPacks", isDirectory: true)
        guard let regions = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for regionURL in regions {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: regionURL.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let id = regionURL.lastPathComponent.lowercased()
            let srcV4 = regionURL.appendingPathComponent("graph.v4.bin")
            let srcGraph = regionURL.appendingPathComponent("graph.v3.bin")
            let srcGeom = regionURL.appendingPathComponent("geometry.v1.bin")
            let dest = regionDir(regionId: id)
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            if fm.fileExists(atPath: srcV4.path), AppConfig.backendEnvironment == .development {
                let destV4 = dest.appendingPathComponent("graph.v4.bin")
                try? fm.removeItem(at: destV4)
                try? fm.copyItem(at: srcV4, to: destV4)
                if fm.fileExists(atPath: srcGeom.path) {
                    let destGeom = dest.appendingPathComponent("geometry.v1.bin")
                    try? fm.removeItem(at: destGeom)
                    try? fm.copyItem(at: srcGeom, to: destGeom)
                }
                let srcSeams = regionURL.appendingPathComponent("cross-pack-seams.v2.json")
                if fm.fileExists(atPath: srcSeams.path) {
                    let destSeams = dest.appendingPathComponent("cross-pack-seams.v2.json")
                    try? fm.removeItem(at: destSeams)
                    try? fm.copyItem(at: srcSeams, to: destSeams)
                }
                let srcFuel = regionURL.appendingPathComponent("fuel.v1.json")
                if fm.fileExists(atPath: srcFuel.path) {
                    let destFuel = dest.appendingPathComponent("fuel.v1.json")
                    try? fm.removeItem(at: destFuel)
                    try? fm.copyItem(at: srcFuel, to: destFuel)
                }
                continue
            }
            guard fm.fileExists(atPath: srcGraph.path) else { continue }
            let destGraph = dest.appendingPathComponent("graph.v3.bin")
            let destGeom = dest.appendingPathComponent("geometry.v1.bin")
            // Preserve shipped/local v2 geometry before overwriting geometry.v1.bin.
            let existingGeom = dest.appendingPathComponent("geometry.v1.bin")
            let rollback = dest.appendingPathComponent("geometry.v1.v2-rollback.bin")
            if fm.fileExists(atPath: existingGeom.path),
               !fm.fileExists(atPath: rollback.path),
               fm.fileExists(atPath: dest.appendingPathComponent("graph.v2.bin").path) {
                try? fm.copyItem(at: existingGeom, to: rollback)
            }
            try? fm.removeItem(at: destGraph)
            try? fm.copyItem(at: srcGraph, to: destGraph)
            if fm.fileExists(atPath: srcGeom.path) {
                try? fm.removeItem(at: destGeom)
                try? fm.copyItem(at: srcGeom, to: destGeom)
            }
            let srcFuel = regionURL.appendingPathComponent("fuel.v1.json")
            if fm.fileExists(atPath: srcFuel.path) {
                let destFuel = dest.appendingPathComponent("fuel.v1.json")
                try? fm.removeItem(at: destFuel)
                try? fm.copyItem(at: srcFuel, to: destFuel)
            }
        }
    }

    // MARK: - Public

    var canRouteOnDevice: Bool { activePack != nil }

    /// Phase E3: always-visible pack format chip (v2 vs v3 leaves).
    struct PackFormatBadge: Equatable, Sendable {
        let regionId: String
        /// `"v3"` when `hasLeaves`, else `"v2"`, or `"—"` when no pack.
        let format: String
        let revision: String
        let hasLeaves: Bool

        var label: String {
            if format == "—" { return "\(regionId) · no pack" }
            return "\(regionId) \(format) · \(revision)"
        }
    }

    func packFormatBadge(at coordinate: CLLocationCoordinate2D) -> PackFormatBadge {
        let region = (Self.primaryRegionId(containing: coordinate) ?? "??").uppercased()
        guard let pack = packIfInstalled(region) else {
            return PackFormatBadge(regionId: region, format: "—", revision: "—", hasLeaves: false)
        }
        let format: String
        if pack.version >= 4 {
            format = "v4"
        } else if pack.hasLeaves {
            format = "v3"
        } else {
            format = "v2"
        }
        return PackFormatBadge(
            regionId: (pack.regionId ?? region).uppercased(),
            format: format,
            revision: packRevisionLabel(regionId: pack.regionId ?? region),
            hasLeaves: pack.hasLeaves
        )
    }

    /// Short revision for the badge: catalog sha8, else `local`, else manifest version.
    func packRevisionLabel(regionId: String) -> String {
        let id = regionId.lowercased()
        if let files = installedPackIdentity(regionId: id) {
            let sha = files["graph.v4.bin"] ?? files["graph.v3.bin"] ?? files["graph.v2.bin"]
            if let sha, sha.count >= 8 { return String(sha.prefix(8)) }
        }
        if let url = findGraphFileURL(regionId: id) {
            if url.lastPathComponent == "graph.v4.bin" { return "v4" }
            if url.lastPathComponent == "graph.v3.bin" { return "local" }
            return lastManifestVersion
        }
        return lastManifestVersion
    }

    @ObservationIgnored private var lastCatalogRefreshAt: Date?

    func refreshCatalog() async {
        isRefreshingCatalog = true
        defer {
            isRefreshingCatalog = false
            lastCatalogRefreshAt = Date()
        }
        do {
            let (data, response) = try await session.data(from: AppConfig.packManifestURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                applyCatalog(published: publishedIds, sizes: [:])
                return
            }
            let manifest = try JSONDecoder().decode(PackManifest.self, from: data)
            lastManifestVersion = manifest.version
            manifestFilesByRegion = Dictionary(uniqueKeysWithValues: manifest.regions.map {
                ($0.id.lowercased(), $0.files.filter { Self.phonePackFileNames.contains($0.name) })
            })
            catalogIdentityLoaded = true
            var sizes: [String: Int64] = [:]
            var published = Set<String>()
            for region in manifest.regions {
                published.insert(region.id.lowercased())
                var total: Int64 = 0
                for file in region.files where Self.phonePackFileNames.contains(file.name) {
                    if let bytes = file.bytes { total += Int64(bytes) }
                }
                if total > 0 {
                    sizes[region.id.lowercased()] = total
                } else if let file = region.files.first(where: { $0.name == "graph.v2.bin" }),
                          let bytes = file.bytes {
                    sizes[region.id.lowercased()] = Int64(bytes)
                }
            }
            publishedIds = published
            verifiedInstalledRegionIds = await Self.verifyInstalledRegions(
                manifest: manifest,
                cacheRoot: cacheRoot
            )
            applyCatalog(published: published, sizes: sizes)
            refreshInstalledFromDisk()
        } catch {
            applyCatalog(published: publishedIds, sizes: [:])
            refreshInstalledFromDisk()
        }
    }

    /// Avoid hammering the CDN on every Start Nav tap.
    func refreshCatalogIfStale(staleSeconds: TimeInterval = 300) async {
        if let last = lastCatalogRefreshAt, Date().timeIntervalSince(last) < staleSeconds {
            return
        }
        await refreshCatalog()
    }

    /// Regions suggested from GPS and/or active route geometry.
    func suggestedRegionIds(
        location: CLLocationCoordinate2D?,
        routeCoordinates: [CLLocationCoordinate2D]
    ) -> [String] {
        var ordered: [String] = []
        func push(_ id: String) {
            let key = id.lowercased()
            if !ordered.contains(key) { ordered.append(key) }
        }
        for id in Self.regionIds(containingAny: routeCoordinates) { push(id) }
        if let location {
            for id in Self.regionIds(containingAny: [location]) { push(id) }
        }
        return ordered
    }

    /// Packs needed for this corridor that are not installed yet (and are published).
    func missingPublishedRegions(for coordinates: [CLLocationCoordinate2D]) -> [String] {
        let needed = Self.regionIds(containingAny: coordinates)
        return needed.filter { publishedIds.contains($0) && !isInstalled($0) }
    }

    /// Decoded pack for an installed region (active pack if it matches).
    func packIfInstalled(_ regionId: String) -> GraphV2Pack? {
        let id = regionId.lowercased()
        if activePack?.regionId?.lowercased() == id { return activePack }
        guard let graphURL = findGraphFileURL(regionId: id) else { return nil }
        return Self.decodePack(
            regionId: id,
            graphURL: graphURL,
            geometryURL: geometryFileURL(regionId: id),
            seamsURL: seamsFileURL(regionId: id)
        )
    }

    func isInstalled(_ regionId: String) -> Bool {
        let id = regionId.lowercased()
        if findGraphFileURL(regionId: id) != nil { return true }
        if activePack?.regionId?.lowercased() == id { return true }
        return loadedRegionIds.contains { $0.lowercased() == id }
    }

    /// Absolute path of the on-disk graph when present (any manifest version folder).
    func installedGraphPath(regionId: String) -> String? {
        findGraphFileURL(regionId: regionId.lowercased())?.path
    }

    func packRevisionState(_ regionID: String) -> PackRevisionState {
        let id = regionID.lowercased()
        guard isInstalled(id) else { return .missing }
        if !catalogIdentityLoaded { return .current }
        return verifiedInstalledRegionIds.contains(id) ? .current : .stale
    }

    func isRoutingPackPublished(_ regionID: String) -> Bool {
        isPublished(regionID)
    }

    static func shouldReplaceInstalledRevision(
        hasChecksumValidInstalledRevision: Bool,
        replaceInstalled: Bool,
        protectInstalledRevisions: Bool
    ) -> Bool {
        guard hasChecksumValidInstalledRevision else { return true }
        if protectInstalledRevisions { return false }
        return replaceInstalled
    }

    static func managementRows(from regions: [RegionInfo]) -> [InstalledPackManagementRow] {
        regions.compactMap { region in
            guard case .installed = region.install else { return nil }
            let state: PackRevisionState = region.revisionState == .missing ? .current : region.revisionState
            return InstalledPackManagementRow(
                id: region.id,
                title: region.title,
                revisionState: state,
                bytes: region.exactBytes ?? region.approxBytes,
                canDelete: true,
                canDownload: false
            )
        }
    }

    var installedManagementRows: [InstalledPackManagementRow] {
        Self.managementRows(from: regions)
    }

    func installVerifiedPacks(_ regionIDs: [String], replaceInstalled: Bool) async throws {
        for raw in regionIDs {
            let id = raw.lowercased()
            guard publishedIds.contains(id) else {
                throw PackAcquisitionError.unavailable(regionID: id)
            }
            let hadInstalled = isInstalled(id)
            do {
                try await performDownload(
                    regionId: id,
                    asNavigationPrep: false,
                    quiet: false,
                    replaceInstalled: replaceInstalled
                )
            } catch {
                throw PackAcquisitionError.downloadFailed(
                    regionID: id,
                    message: error.localizedDescription
                )
            }
            if replaceInstalled || !hadInstalled {
                guard packRevisionState(id) == .current else {
                    throw PackAcquisitionError.checksumMismatch(regionID: id)
                }
            } else if !isInstalled(id) {
                throw PackAcquisitionError.checksumMismatch(regionID: id)
            }
        }
    }

    func installedPackIdentity(regionId: String) -> [String: String]? {
        let id = regionId.lowercased()
        guard verifiedInstalledRegionIds.contains(id),
              let files = manifestFilesByRegion[id] else { return nil }
        return Dictionary(uniqueKeysWithValues: files.compactMap { file in
            guard let sha = file.sha256 else { return nil }
            return (file.name, sha)
        })
    }

    func isPublished(_ regionId: String) -> Bool {
        publishedIds.contains(regionId.lowercased())
    }

    func displayTitle(forRegionId id: String) -> String {
        let key = id.lowercased()
        if let match = regions.first(where: { $0.id == key }) {
            return match.title
        }
        return key.uppercased()
    }

    /// Human titles for packs already on this phone.
    func installedTitles() -> [String] {
        regions.compactMap { row in
            if case .installed = row.install { return row.title }
            return nil
        }
    }

    /// Rider-facing copy when the needed pack is missing or the pins do not connect.
    func offlinePlanningMessage(for coordinates: [CLLocationCoordinate2D]) -> String {
        let needed = Self.regionIds(containingAny: coordinates)
        let installed = installedTitles()
        let installedClause: String = {
            if installed.isEmpty {
                return "No packs on this phone yet."
            }
            if installed.count == 1 {
                return "You have \(installed[0]) on this phone."
            }
            return "On this phone: \(installed.joined(separator: ", "))."
        }()

        if needed.isEmpty {
            return "This pin isn’t in a known pack region. \(installedClause) Place a route through Canada or the United States to install a required pack."
        }

        let missing = needed.filter { !isInstalled($0) }
        if missing.isEmpty {
            return "On-device routing couldn’t connect those pins. \(installedClause) Try pins closer to roads."
        }

        let missingTitles = missing.map { displayTitle(forRegionId: $0) }
        let missingList = missingTitles.joined(separator: ", ")
        let publishedMissing = missing.filter { isPublished($0) }
        let unpublishedMissing = missing.filter { !isPublished($0) }

        if !publishedMissing.isEmpty, unpublishedMissing.isEmpty {
            return "\(missingList) isn’t on this phone. \(installedClause) Connect to the internet and install \(missingList) when asked — or keep your pin inside an installed region."
        }
        if publishedMissing.isEmpty, !unpublishedMissing.isEmpty {
            return "\(missingList) isn’t published as an approved pack yet. \(installedClause) Offline rerouting will not be available for this region."
        }
        return "Need \(missingList) for that pin. \(installedClause) Offline rerouting will not be available until an approved pack can be installed."
    }

    func downloadRegion(_ regionId: String, quiet: Bool = false, replaceInstalled: Bool = false) {
        let id = regionId.lowercased()
        guard publishedIds.contains(id) else { return }
        guard downloadTasks[id] == nil else { return }
        if quiet {
            guard quietDownloadIds.isEmpty else { return }
            quietDownloadIds.insert(id)
        }
        setInstall(id, .downloading(0.02))
        downloadTasks[id] = Task { [weak self] in
            try? await self?.performDownload(
                regionId: id,
                asNavigationPrep: false,
                quiet: quiet,
                replaceInstalled: replaceInstalled
            )
            guard let self else { return }
            self.downloadTasks[id] = nil
            self.quietDownloadIds.remove(id)
            if quiet,
               !self.isInstalled(id),
               self.lastAutoDownloadRegionId == id {
                // A later GPS fix may retry a failed boundary acquisition.
                self.lastAutoDownloadRegionId = nil
            }
        }
    }

    /// Fetch the Cloudflare R2 pack if missing, then wait. Same file PACKS installs.
    /// Live Vercel is not a second fabric.
    func ensureInstalled(_ regionId: String) async {
        let id = regionId.lowercased()
        if isInstalled(id) { return }
        guard publishedIds.contains(id) else { return }
        if let existing = downloadTasks[id] {
            await existing.value
            return
        }
        setInstall(id, .downloading(0.02))
        let task = Task { [weak self] in
            try? await self?.performDownload(regionId: id, asNavigationPrep: false, quiet: false, replaceInstalled: false)
            self?.downloadTasks[id] = nil
        }
        downloadTasks[id] = task
        await task.value
    }

    func deleteRegion(_ regionId: String) {
        let id = regionId.lowercased()
        downloadTasks[id]?.cancel()
        downloadTasks[id] = nil
        quietDownloadIds.remove(id)
        let dir = regionDir(regionId: id)
        try? FileManager.default.removeItem(at: dir)
        packedFuelByRegion.removeValue(forKey: id)
        if activePack?.regionId?.lowercased() == id {
            activePack = nil
            loadedRegionIds.removeAll { $0.lowercased() == id }
            phase = .idle
        }
        refreshInstalledFromDisk()
    }

    /// Start Nav: prepare only the province/state containing the rider's start.
    /// Later regions follow actual rider location and never bulk-download from
    /// the complete itinerary. Checksum-valid installed revisions remain pinned.
    func prepareForNavigation(startingAt coordinate: CLLocationCoordinate2D, keepExisting: Bool) {
        task?.cancel()
        _ = keepExisting // Disk packs and corridor tiles are reused automatically.
        phase = .downloading
        progress = 0.02
        let startedAt = Date()
        RoutingDebugLog.shared.event(
            String(
                format: "navigation routing pack prep begin scope=current point=%.5f,%.5f",
                coordinate.latitude,
                coordinate.longitude
            )
        )
        task = Task { [weak self] in
            guard let self else { return }
            // The app already refreshes this catalog. Reuse a recent result rather
            // than issuing duplicate manifest requests on every Start tap.
            await self.refreshCatalogIfStale()
            guard !Task.isCancelled else { return }

            let needed = self.navigationRegionRequirementCache.regionIds(for: [coordinate]) { route in
                let primaryRegions = Self.regionIds(containingAny: route)
                return primaryRegions.isEmpty ? Self.regionIds(covering: route) : primaryRegions
            }
            guard !needed.isEmpty else {
                self.phase = .skipped("No offline routing region covers this route")
                self.progress = 1
                RoutingDebugLog.shared.event("navigation routing pack prep skipped reason=no-region")
                return
            }
            let published = needed.filter { self.publishedIds.contains($0) }
            let unpublished = needed.filter { !self.publishedIds.contains($0) }
            guard !published.isEmpty else {
                let names = needed.map { self.displayTitle(forRegionId: $0) }.joined(separator: ", ")
                self.phase = .skipped("No offline routing pack is published yet for \(names)")
                self.progress = 1
                RoutingDebugLog.shared.event(
                    "navigation routing pack prep skipped reason=unpublished regions=\(needed.joined(separator: ","))"
                )
                return
            }

            let missing = published.filter { !self.isInstalled($0) }
            RoutingDebugLog.shared.event(
                "navigation routing pack prep regions=\(needed.joined(separator: ",")) "
                    + "missing=\(missing.joined(separator: ","))"
            )
            for (offset, id) in missing.enumerated() {
                guard !Task.isCancelled else { return }
                // Run inside the prep task so Cancel genuinely cancels this download.
                try? await self.performDownload(regionId: id, asNavigationPrep: false, quiet: false, replaceInstalled: false)
                guard !Task.isCancelled else { return }
                guard self.isInstalled(id) else {
                    self.phase = .failed("Couldn’t download the \(self.displayTitle(forRegionId: id)) routing pack. Check your connection and try again.")
                    self.progress = 1
                    RoutingDebugLog.shared.event("navigation routing pack prep failed region=\(id)")
                    return
                }
                self.progress = 0.05 + 0.85 * Double(offset + 1) / Double(max(missing.count, 1))
            }

            await self.ensureActivePackAsync(preferredRegionIds: needed)
            guard !Task.isCancelled else { return }
            guard self.activePack != nil else {
                self.phase = .failed("The downloaded routing pack could not be opened.")
                self.progress = 1
                RoutingDebugLog.shared.event("navigation routing pack prep failed reason=decode")
                return
            }

            self.progress = 1
            self.lastAutoDownloadRegionId = needed.first(where: { self.isInstalled($0) })
            if unpublished.isEmpty {
                self.phase = .ready
            } else {
                let names = unpublished.map { self.displayTitle(forRegionId: $0) }.joined(separator: ", ")
                self.phase = .skipped("No offline routing pack is published yet for \(names)")
            }
            RoutingDebugLog.shared.event(
                "navigation routing pack prep ready loaded=\(self.loadedRegionIds.joined(separator: ",")) "
                    + "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
        }
    }

    /// Mid-ride rolling acquisition. Installed packs switch immediately; a
    /// newly entered published region downloads quietly, one region at a time.
    /// Repeated GPS fixes in the same region are a no-op.
    func prepareCurrentNavigationRegionIfNeeded(at coordinate: CLLocationCoordinate2D) {
        guard let id = NavigationRoutingPackScope.regionTransition(
            currentRegionID: Self.primaryRegionId(containing: coordinate),
            lastPreparedRegionID: lastAutoDownloadRegionId
        ) else { return }

        if isInstalled(id) {
            lastAutoDownloadRegionId = id
            RoutingDebugLog.shared.event(
                "navigation routing pack region=\(id) source=installed action=activate"
            )
            Task { [weak self] in
                await self?.activateInstalledPack(regionId: id)
            }
            return
        }

        guard publishedIds.contains(id) else {
            lastAutoDownloadRegionId = id
            RoutingDebugLog.shared.event(
                "navigation routing pack region=\(id) source=unpublished action=live-only"
            )
            return
        }
        // If a previous boundary download is still finishing, the next GPS fix
        // retries this transition instead of dropping it.
        guard quietDownloadIds.isEmpty else { return }

        lastAutoDownloadRegionId = id
        RoutingDebugLog.shared.event(
            "navigation routing pack region=\(id) source=boundary action=download"
        )
        downloadRegion(id, quiet: true)
    }

    func cancel() {
        task?.cancel()
        task = nil
        if case .downloading = phase { phase = .idle }
    }

    /// Cancel quiet auto-downloads started mid-ride (End Nav). Manual PACKS downloads continue.
    func cancelQuietDownloads() {
        let ids = Array(quietDownloadIds)
        for id in ids {
            downloadTasks[id]?.cancel()
            downloadTasks[id] = nil
            setInstall(id, isInstalled(id) ? .installed : (publishedIds.contains(id) ? .available : .unavailable))
        }
        quietDownloadIds.removeAll()
        lastAutoDownloadRegionId = nil
    }

    func routeOnDevice(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        profile: RouteProfile,
        allowUnknown: Bool,
        avoidEdgeIds: [String] = [],
        priorEdgeIds: Set<String> = [],
        arrivalEdgeId: String? = nil,
        backtrackFactor: Double = 4,
        sessionSeed: UInt64 = 0,
        maxRouteMeters: Double? = nil,
        regionalHopMinimumMeters: [Double] = [],
        startEndpointKind: String? = nil,
        endEndpointKind: String? = nil
    ) async -> OnDeviceRouter.Result? {
        switch await routeOnDeviceDetailed(
            from: from,
            to: to,
            profile: profile,
            allowUnknown: allowUnknown,
            avoidEdgeIds: avoidEdgeIds,
            priorEdgeIds: priorEdgeIds,
            arrivalEdgeId: arrivalEdgeId,
            backtrackFactor: backtrackFactor,
            sessionSeed: sessionSeed,
            maxRouteMeters: maxRouteMeters,
            regionalHopMinimumMeters: regionalHopMinimumMeters,
            startEndpointKind: startEndpointKind,
            endEndpointKind: endEndpointKind
        ) {
        case .success(let result): return result
        case .failure: return nil
        }
    }

    func routeOnDeviceDetailed(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        profile: RouteProfile,
        allowUnknown: Bool,
        avoidEdgeIds: [String] = [],
        priorEdgeIds: Set<String> = [],
        arrivalEdgeId: String? = nil,
        backtrackFactor: Double = 4,
        sessionSeed: UInt64 = 0,
        maxRouteMeters: Double? = nil,
        regionalHopMinimumMeters: [Double] = [],
        cleanMetroMultiplier: Double? = nil,
        avoidMotorways: Bool = false,
        preferBackRoads: Bool = false,
        mapZoom: Double? = nil,
        matchLimitMeters: Double? = nil,
        startEndpointKind: String? = nil,
        endEndpointKind: String? = nil,
        fastSearch: Bool = false,
        deadline: Date? = nil
    ) async -> Result<OnDeviceRouter.Result, OnDeviceRouter.Failure> {
        let fromId = Self.primaryRegionId(containing: from)
        let toId = Self.primaryRegionId(containing: to)
        if let fromId, let toId, fromId != toId,
           isInstalled(fromId), isInstalled(toId) {
            let installed = Set(Self.roadReachableNeighbours.keys.filter { isInstalled($0) })
            guard let regionPath = Self.shortestRegionPath(
                from: fromId,
                to: toId,
                allowedRegionIds: installed
            ), regionPath.count > 1 else { return .failure(.noPath) }
            let packFiles = regionPath.map { id in
                let graph = installedGraphPath(regionId: id).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "-"
                let seams = FileManager.default.fileExists(atPath: seamsFileURL(regionId: id).path) ? 1 : 0
                return "\(id){graph=\(graph),seams=\(seams)}"
            }.joined(separator: ">")
            RoutingDebugLog.shared.event(
                "on-device cross-region from=\(fromId) to=\(toId) "
                    + "path=\(regionPath.joined(separator: ">")) files=\(packFiles)"
            )
            return await routeOnDeviceChained(
                from: from,
                to: to,
                regions: regionPath,
                profile: profile,
                allowUnknown: allowUnknown,
                avoidEdgeIds: avoidEdgeIds,
                priorEdgeIds: priorEdgeIds,
                arrivalEdgeId: arrivalEdgeId,
                backtrackFactor: backtrackFactor,
                sessionSeed: sessionSeed,
                maxRouteMeters: maxRouteMeters,
                regionalHopMinimumMeters: regionalHopMinimumMeters,
                cleanMetroMultiplier: cleanMetroMultiplier,
                avoidMotorways: avoidMotorways,
                preferBackRoads: preferBackRoads,
                mapZoom: mapZoom,
                matchLimitMeters: matchLimitMeters,
                startEndpointKind: startEndpointKind,
                endEndpointKind: endEndpointKind,
                fastSearch: fastSearch,
                deadline: deadline
            )
        }
        return await routeOnDeviceInRegion(
            from: from,
            to: to,
            regionId: nil,
            profile: profile,
            allowUnknown: allowUnknown,
            avoidEdgeIds: avoidEdgeIds,
            priorEdgeIds: priorEdgeIds,
            arrivalEdgeId: arrivalEdgeId,
            backtrackFactor: backtrackFactor,
            sessionSeed: sessionSeed,
            maxRouteMeters: maxRouteMeters,
            cleanMetroMultiplier: cleanMetroMultiplier,
            avoidMotorways: avoidMotorways,
            preferBackRoads: preferBackRoads,
            mapZoom: mapZoom,
            matchLimitMeters: matchLimitMeters,
            startEndpointKind: startEndpointKind,
            endEndpointKind: endEndpointKind,
            fastSearch: fastSearch,
            deadline: deadline
        )
    }

    /// Multi-pack route over factory-proven seams. Each side of a seam is
    /// independently proven and snapped; the phone never invents a connector
    /// from proximity or a rectangular map bound.
    private func routeOnDeviceChained(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        regions: [String],
        profile: RouteProfile,
        allowUnknown: Bool,
        avoidEdgeIds: [String],
        priorEdgeIds: Set<String>,
        arrivalEdgeId: String?,
        backtrackFactor: Double,
        sessionSeed: UInt64,
        maxRouteMeters: Double?,
        regionalHopMinimumMeters: [Double] = [],
        cleanMetroMultiplier: Double? = nil,
        avoidMotorways: Bool = false,
        preferBackRoads: Bool = false,
        mapZoom: Double? = nil,
        matchLimitMeters: Double? = nil,
        startEndpointKind: String? = nil,
        endEndpointKind: String? = nil,
        fastSearch: Bool = false,
        deadline: Date? = nil
    ) async -> Result<OnDeviceRouter.Result, OnDeviceRouter.Failure> {
        guard regions.count >= 2 else { return .failure(.noPath) }
        var lastFailure: OnDeviceRouter.Failure = .noPath
        var seamAttempts = 0
        let maximumSeamAttempts = fastSearch
            ? max(2, min(8, (regions.count - 1) * 2))
            : max(24, min(96, (regions.count - 1) * 8))

        func search(
            regionIndex: Int,
            current: CLLocationCoordinate2D,
            hops: [OnDeviceRouter.Result],
            usedEdges: Set<String>,
            incomingEdgeId: String?,
            completedMeters: Double
        ) async -> OnDeviceRouter.Result? {
            let regionId = regions[regionIndex]
            if regionIndex == regions.count - 1 {
                let final = await routeOnDeviceInRegion(
                    from: current, to: to, regionId: regionId,
                    profile: profile, allowUnknown: allowUnknown, avoidEdgeIds: avoidEdgeIds,
                    priorEdgeIds: usedEdges, arrivalEdgeId: incomingEdgeId,
                    backtrackFactor: backtrackFactor, sessionSeed: sessionSeed,
                    maxRouteMeters: Self.reservedChainHopCap(
                        totalCapMeters: maxRouteMeters,
                        completedMeters: completedMeters,
                        hopIndex: regionIndex,
                        hopCount: regions.count,
                        minimumHopMeters: regionalHopMinimumMeters
                    ),
                    cleanMetroMultiplier: cleanMetroMultiplier,
                    avoidMotorways: avoidMotorways, preferBackRoads: preferBackRoads,
                    mapZoom: mapZoom, matchLimitMeters: matchLimitMeters,
                    startEndpointKind: regionIndex == 0 ? startEndpointKind : nil,
                    endEndpointKind: endEndpointKind,
                    fastSearch: fastSearch,
                    deadline: deadline
                )
                guard case .success(let last) = final, last.coordinates.count > 1 else {
                    if case .failure(let reason) = final { lastFailure = reason }
                    return nil
                }
                return OnDeviceRouter.Result.concatenating(hops + [last])
            }

            let nextRegionId = regions[regionIndex + 1]
            await activateInstalledPack(regionId: regionId)
            guard let localPack = activePack,
                  localPack.regionId?.lowercased() == regionId else { return nil }
            let anchors = CrossPackSeam.candidates(
                from: current,
                to: to,
                anchors: localPack.crossPackSeams[nextRegionId] ?? [],
                urbanCores: localPack.urbanCores
            )
            guard !anchors.isEmpty else { return nil }

            await activateInstalledPack(regionId: nextRegionId)
            guard let remotePack = activePack,
                  remotePack.regionId?.lowercased() == nextRegionId else { return nil }
            let reverseAnchors = remotePack.crossPackSeams[regionId] ?? []

            for anchor in anchors.prefix(fastSearch ? 2 : 8) {
                guard seamAttempts < maximumSeamAttempts else { return nil }
                guard let reverse = reverseAnchors.first(where: {
                    $0.osmWayId == anchor.osmWayId
                        && abs($0.latitude - anchor.latitude) < 0.00002
                        && abs($0.longitude - anchor.longitude) < 0.00002
                        && $0.gapMeters <= 2
                }) else { continue }
                seamAttempts += 1
                let seam = CLLocationCoordinate2D(
                    latitude: (anchor.latitude + reverse.latitude) / 2,
                    longitude: (anchor.longitude + reverse.longitude) / 2
                )
                let hop = await routeOnDeviceInRegion(
                    from: current, to: seam, regionId: regionId,
                    profile: profile, allowUnknown: allowUnknown, avoidEdgeIds: avoidEdgeIds,
                    priorEdgeIds: usedEdges, arrivalEdgeId: incomingEdgeId,
                    backtrackFactor: backtrackFactor, sessionSeed: sessionSeed,
                    maxRouteMeters: Self.reservedChainHopCap(
                        totalCapMeters: maxRouteMeters,
                        completedMeters: completedMeters,
                        hopIndex: regionIndex,
                        hopCount: regions.count,
                        minimumHopMeters: regionalHopMinimumMeters
                    ),
                    cleanMetroMultiplier: cleanMetroMultiplier,
                    avoidMotorways: avoidMotorways, preferBackRoads: preferBackRoads,
                    mapZoom: mapZoom, matchLimitMeters: matchLimitMeters,
                    startEndpointKind: regionIndex == 0 ? startEndpointKind : nil,
                    endEndpointKind: nil,
                    fastSearch: fastSearch,
                    deadline: deadline
                )
                guard case .success(let routed) = hop, routed.coordinates.count > 1 else {
                    if case .failure(let reason) = hop { lastFailure = reason }
                    continue
                }
                if let result = await search(
                    regionIndex: regionIndex + 1,
                    current: seam,
                    hops: hops + [routed],
                    usedEdges: usedEdges.union(routed.edgeIds),
                    incomingEdgeId: routed.edgeIds.last ?? incomingEdgeId,
                    completedMeters: completedMeters + routed.distanceMeters
                ) {
                    return result
                }
            }
            return nil
        }

        if let result = await search(
            regionIndex: 0,
            current: from,
            hops: [],
            usedEdges: priorEdgeIds,
            incomingEdgeId: arrivalEdgeId,
            completedMeters: 0
        ) {
            return .success(result)
        }
        return .failure(lastFailure)
    }

    /// A fuel-leg cap belongs to the complete regional chain. Before the
    /// current hop spends distance on Dirt detours, reserve the graph-proven
    /// minimum for every later province hop.
    nonisolated static func reservedChainHopCap(
        totalCapMeters: Double?,
        completedMeters: Double,
        hopIndex: Int,
        hopCount: Int,
        minimumHopMeters: [Double]
    ) -> Double? {
        guard let totalCapMeters, totalCapMeters.isFinite else { return nil }
        let remaining = max(0, totalCapMeters - max(0, completedMeters))
        guard hopIndex >= 0,
              hopIndex < hopCount,
              minimumHopMeters.count == hopCount,
              minimumHopMeters.allSatisfy({ $0.isFinite && $0 >= 0 })
        else { return remaining }
        let laterMinimum = minimumHopMeters.dropFirst(hopIndex + 1).reduce(0, +)
        return max(0, remaining - laterMinimum)
    }

    private func routeOnDeviceInRegion(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        regionId: String?,
        profile: RouteProfile,
        allowUnknown: Bool,
        avoidEdgeIds: [String],
        priorEdgeIds: Set<String>,
        arrivalEdgeId: String?,
        backtrackFactor: Double,
        sessionSeed: UInt64,
        maxRouteMeters: Double? = nil,
        cleanMetroMultiplier: Double? = nil,
        avoidMotorways: Bool = false,
        preferBackRoads: Bool = false,
        mapZoom: Double? = nil,
        matchLimitMeters: Double? = nil,
        startEndpointKind: String? = nil,
        endEndpointKind: String? = nil,
        fastSearch: Bool = false,
        deadline: Date? = nil
    ) async -> Result<OnDeviceRouter.Result, OnDeviceRouter.Failure> {
        if let regionId {
            await activateInstalledPack(regionId: regionId)
        } else {
            await ensureActivePackAsync(for: [from, to])
        }
        guard let pack = activePack else { return .failure(.noPath) }
        let avoid = Set(avoidEdgeIds)
        let packRef = pack
        let start = from
        let end = to
        let routeProfile = profile
        let allow = allowUnknown
        let seed = sessionSeed
        let metro = cleanMetroMultiplier
        let zoom = mapZoom
        let matchLimit = matchLimitMeters
        let executionCancelled: @Sendable () -> Bool = {
            Task.isCancelled || (deadline.map { Date() >= $0 } ?? false)
        }
        let work = Task.detached(priority: .userInitiated) {
            var router = OnDeviceRouter(pack: packRef)
            router.executionCancelled = executionCancelled
            router.sessionSeed = seed
            router.mapZoom = zoom
            router.matchLimitMeters = matchLimit
            router.fastSearch = fastSearch
            return router.routeDetailed(
                from: start,
                to: end,
                profile: routeProfile,
                allowUnknown: allow,
                avoidEdgeIds: avoid,
                priorEdgeIds: priorEdgeIds,
                arrivalEdgeId: arrivalEdgeId,
                backtrackFactor: backtrackFactor,
                sessionSeed: seed,
                maxRouteMeters: maxRouteMeters,
                cleanMetroMultiplier: metro,
                avoidMotorways: avoidMotorways,
                preferBackRoads: preferBackRoads
            )
        }
        return await withTaskCancellationHandler(
            operation: { await work.value },
            onCancel: { work.cancel() }
        )
    }

    func shortestGraphMeters(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        maxMeters: Double,
        profile: RouteProfile,
        allowUnknown: Bool,
        deadline: Date? = nil
    ) async -> Double? {
        await ensureActivePackAsync(for: [from, to])
        guard let pack = activePack else { return nil }
        let packRef = pack
        let work = Task.detached(priority: .userInitiated) {
            var router = OnDeviceRouter(pack: packRef)
            router.executionCancelled = {
                Task.isCancelled || (deadline.map { Date() >= $0 } ?? false)
            }
            return router.shortestGraphMeters(
                from: from, to: to, maxMeters: maxMeters,
                profile: profile, allowUnknown: allowUnknown
            )
        }
        return await withTaskCancellationHandler(
            operation: { await work.value },
            onCancel: { work.cancel() }
        )
    }

    func reachableFuelMeters(
        from: CLLocationCoordinate2D,
        toward: CLLocationCoordinate2D,
        pumps: [POIFeature],
        maxMeters: Double,
        profile: RouteProfile,
        allowUnknown: Bool,
        deadline: Date? = nil
    ) async -> [String: Double] {
        await ensureActivePackAsync(for: [from, toward])
        guard let pack = activePack else { return [:] }
        // A regional graph cannot prove a pump from a different regional pack.
        // The broad A→B fuel prefilter intentionally includes both sides of a
        // border so later hops can use the next pack, but feeding those pumps
        // into this local flood causes needless snap work and can make a
        // station appear reachable merely because its point lies in the bbox.
        // Keep the station list broad at the itinerary layer and constrain it
        // only for this exact graph proof.
        let localPumps: [POIFeature]
        if let regionID = pack.regionId?.lowercased() {
            localPumps = pumps.filter { pump in
                let point = CLLocationCoordinate2D(
                    latitude: pump.latitude,
                    longitude: pump.longitude
                )
                return Self.primaryRegionId(containing: point)?.lowercased() == regionID
            }
        } else {
            localPumps = pumps
        }
        let packRef = pack
        let work = Task.detached(priority: .userInitiated) {
            var router = OnDeviceRouter(pack: packRef)
            router.executionCancelled = {
                Task.isCancelled || (deadline.map { Date() >= $0 } ?? false)
            }
            return router.reachableGraphMeters(
                from: from, toward: toward, pumps: localPumps, maxMeters: maxMeters,
                profile: profile, allowUnknown: allowUnknown
            )
        }
        return await withTaskCancellationHandler(
            operation: { await work.value },
            onCancel: { work.cancel() }
        )
    }

    /// Immutable metadata view used only to rank already-reachable fuel stops.
    /// It never changes graph topology, costs, or installed pack bytes.
    func fuelAvoidanceBoxes(
        from: CLLocationCoordinate2D,
        toward: CLLocationCoordinate2D
    ) async -> [UrbanCore.Box] {
        await ensureActivePackAsync(for: [from, toward])
        guard let pack = activePack else { return [] }
        return UrbanCore.fuelAvoidanceBoxes(
            embeddedCores: pack.urbanCores,
            embeddedSettlements: pack.settlements,
            regionId: pack.regionId
        )
    }

    /// Explicit road-reachable land/bridge borders and accepted vehicle-ferry
    /// pairs. Rectangular map bounds are deliberately not topology: they create
    /// false neighbours across lakes, water, and point-only state corners.
    static func packsShareABorder(_ left: String, _ right: String) -> Bool {
        let a = left.lowercased()
        let b = right.lowercased()
        if a == b { return true }
        return roadReachableNeighbours[a]?.contains(b) == true
    }

    /// Deterministic adjacency-only path. A point-corner or bbox overlap can
    /// never enter this traversal because it is absent from the registry.
    static func shortestRegionPath(
        from: String,
        to: String,
        allowedRegionIds: Set<String>
    ) -> [String]? {
        let start = from.lowercased()
        let end = to.lowercased()
        if start == end { return [start] }
        guard allowedRegionIds.contains(start), allowedRegionIds.contains(end) else { return nil }
        var queue: [[String]] = [[start]]
        var seen: Set<String> = [start]
        while !queue.isEmpty {
            let path = queue.removeFirst()
            guard let current = path.last else { continue }
            for neighbor in (roadReachableNeighbours[current] ?? []).sorted()
            where allowedRegionIds.contains(neighbor) && !seen.contains(neighbor) {
                let next = path + [neighbor]
                if neighbor == end { return next }
                seen.insert(neighbor)
                queue.append(next)
            }
        }
        return nil
    }

    private static let roadReachableNeighbours: [String: Set<String>] = [
        "bc": ["ab", "yt", "nt", "ak", "wa", "id", "mt"],
        "ab": ["bc", "sk", "nt", "mt"],
        "sk": ["ab", "mb", "mt", "nd"],
        "mb": ["sk", "on", "nd", "mn"],
        "on": ["mb", "qc", "mn", "mi", "ny"],
        "qc": ["on", "nb", "nl", "ny", "vt", "nh", "me"],
        "nb": ["qc", "ns", "pe", "me"],
        "ns": ["nb", "pe", "nl"],
        "pe": ["nb", "ns"],
        "nl": ["qc", "ns"],
        "yt": ["bc", "nt", "ak"],
        "nt": ["yt", "bc", "ab"],
        "nu": [],
        "ak": ["yt", "bc"],
        "al": ["fl", "ga", "ms", "tn"],
        "ar": ["mo", "tn", "ms", "la", "tx", "ok"],
        "az": ["ca", "nv", "ut", "nm"],
        "ca": ["or", "nv", "az"],
        "co": ["wy", "ne", "ks", "ok", "nm", "ut"],
        "ct": ["ny", "ma", "ri"],
        "de": ["md", "pa", "nj"],
        "fl": ["al", "ga"],
        "ga": ["fl", "al", "tn", "nc", "sc"],
        "hi": [],
        "ia": ["mn", "wi", "il", "mo", "ne", "sd"],
        "id": ["wa", "or", "nv", "ut", "wy", "mt", "bc"],
        "il": ["wi", "ia", "mo", "ky", "in"],
        "in": ["mi", "oh", "ky", "il"],
        "ks": ["ne", "mo", "ok", "co"],
        "ky": ["il", "in", "oh", "wv", "va", "tn", "mo"],
        "la": ["tx", "ar", "ms"],
        "ma": ["ri", "ct", "ny", "vt", "nh"],
        "md": ["va", "wv", "pa", "de"],
        "me": ["nh", "qc", "nb"],
        "mi": ["wi", "in", "oh", "on"],
        "mn": ["nd", "sd", "ia", "wi", "on", "mb"],
        "mo": ["ia", "il", "ky", "tn", "ar", "ok", "ks", "ne"],
        "ms": ["la", "ar", "tn", "al"],
        "mt": ["id", "wy", "sd", "nd", "sk", "ab", "bc"],
        "nc": ["va", "tn", "ga", "sc"],
        "nd": ["mt", "sd", "mn", "mb", "sk"],
        "ne": ["sd", "ia", "mo", "ks", "co", "wy"],
        "nh": ["me", "ma", "vt", "qc"],
        "nj": ["ny", "pa", "de"],
        "nm": ["az", "co", "ok", "tx"],
        "nv": ["or", "id", "ut", "az", "ca"],
        "ny": ["pa", "nj", "ct", "ma", "vt", "qc", "on"],
        "oh": ["mi", "pa", "wv", "ky", "in"],
        "ok": ["co", "ks", "mo", "ar", "tx", "nm"],
        "or": ["wa", "id", "nv", "ca"],
        "pa": ["ny", "nj", "de", "md", "wv", "oh"],
        "ri": ["ct", "ma"],
        "sc": ["nc", "ga"],
        "sd": ["nd", "mn", "ia", "ne", "wy", "mt"],
        "tn": ["ky", "va", "nc", "ga", "al", "ms", "ar", "mo"],
        "tx": ["nm", "ok", "ar", "la"],
        "ut": ["id", "wy", "co", "az", "nv"],
        "va": ["md", "wv", "ky", "tn", "nc"],
        "vt": ["ny", "ma", "nh", "qc"],
        "wa": ["bc", "id", "or"],
        "wi": ["mi", "mn", "ia", "il"],
        "wv": ["oh", "pa", "md", "va", "ky"],
        "wy": ["mt", "sd", "ne", "co", "ut", "id"]
    ]

    /// Distance to nearest **routable** pack road, or nil if none within snap radius.
    /// Unknown tracks are skipped unless `allowUnknown` (same policy as route snap).
    /// Runs off MainActor so BC’s large packs cannot freeze toast paint / map gestures.
    func distanceToNearestRoad(
        from coordinate: CLLocationCoordinate2D,
        allowUnknown: Bool = false,
        profile: RouteProfile = .balanced
    ) async -> Double? {
        await ensureActivePackAsync(for: [coordinate])
        guard let pack = activePack else { return nil }
        let packRef = pack
        let allow = allowUnknown
        let routeProfile = profile
        let point = coordinate
        return await Task.detached(priority: .userInitiated) {
            OnDeviceRouter(pack: packRef).distanceToNearestRoad(
                from: point,
                allowUnknown: allow,
                profile: routeProfile
            )
        }.value
    }

    /// Prefetch the installed pack covering this coordinate so the first pin
    /// does not pay decode latency on the routing critical path.
    func warmupActivePack(near coordinate: CLLocationCoordinate2D) async {
        await ensureActivePackAsync(for: [coordinate])
        guard let pack = activePack else { return }
        await Task.detached(priority: .utility) {
            OnDeviceRouter.prewarmSpatialIndex(for: pack)
        }.value
    }

    /// When online, fetch missing `geometry.v1` for installed regions before paint.
    /// Missing sidecars top up in the background — do not block Allow / profile reroutes
    /// on a second Cloudflare pull. Chord paint is enough until shapes land.
    func ensureRoadShapes(for coordinates: [CLLocationCoordinate2D]) async {
        let ids = Set(Self.regionIds(containingAny: coordinates).filter { isInstalled($0) })
        for id in ids {
            let geomPath = geometryFileURL(regionId: id).path
            if FileManager.default.fileExists(atPath: geomPath) {
                if activePack?.regionId?.lowercased() == id, activePack?.geometry == nil {
                    await activateInstalledPack(regionId: id)
                }
                continue
            }
            maybeTopUpGeometry(regionId: id)
        }
    }

    // MARK: - Catalog seed

    private static let catalogSeed: [RegionInfo] = {
        var rows: [RegionInfo] = [
            .init(id: "ns", title: "Nova Scotia", subtitle: "Home turf · dual-sport reference", approxBytes: 101_000_000, install: .unavailable, country: .canada),
            .init(id: "nb", title: "New Brunswick", subtitle: "Maritime connector", approxBytes: 38_000_000, install: .unavailable, country: .canada),
            .init(id: "pe", title: "Prince Edward Island", subtitle: "Island rides", approxBytes: 3_000_000, install: .unavailable, country: .canada),
            .init(id: "qc", title: "Québec", subtitle: "Large province · download on Wi‑Fi", approxBytes: 97_000_000, install: .unavailable, country: .canada),
            .init(id: "on", title: "Ontario", subtitle: "Fresh OSM + MNRF · large pack", approxBytes: 156_000_000, install: .unavailable, country: .canada),
            .init(id: "mb", title: "Manitoba", subtitle: "Prairie / shield", approxBytes: 19_000_000, install: .unavailable, country: .canada),
            .init(id: "sk", title: "Saskatchewan", subtitle: "Prairie", approxBytes: 29_000_000, install: .unavailable, country: .canada),
            .init(id: "ab", title: "Alberta", subtitle: "Fresh OSM + Access Roads", approxBytes: 85_000_000, install: .unavailable, country: .canada),
            .init(id: "bc", title: "British Columbia", subtitle: "OSM highway → ATV/track · mountains & coast", approxBytes: 148_000_000, install: .unavailable, country: .canada),
            .init(id: "nl", title: "Newfoundland and Labrador", subtitle: "OSM + FFA Resource Roads", approxBytes: 22_385_478, install: .unavailable, country: .canada),
            .init(id: "yt", title: "Yukon", subtitle: "North", approxBytes: 3_000_000, install: .unavailable, country: .canada),
            .init(id: "nt", title: "Northwest Territories", subtitle: "North", approxBytes: 3_000_000, install: .unavailable, country: .canada),
            .init(id: "nu", title: "Nunavut", subtitle: "North", approxBytes: 2_000_000, install: .unavailable, country: .canada)
        ]
        let us: [(String, String, Int64)] = [
            ("al", "Alabama", 99252068), ("ak", "Alaska", 15983907), ("az", "Arizona", 121010897), ("ar", "Arkansas", 69446135),
            ("ca", "California", 244199538), ("co", "Colorado", 114113249), ("ct", "Connecticut", 52608872), ("de", "Delaware", 13537231),
            ("fl", "Florida", 120762739), ("ga", "Georgia", 167294463), ("hi", "Hawaii", 10873477), ("id", "Idaho", 72786166),
            ("il", "Illinois", 151287100), ("in", "Indiana", 116302988), ("ia", "Iowa", 55837212), ("ks", "Kansas", 67554405),
            ("ky", "Kentucky", 100264936), ("la", "Louisiana", 62109940), ("me", "Maine", 39266092), ("md", "Maryland", 83840404),
            ("ma", "Massachusetts", 90608647), ("mi", "Michigan", 157694424), ("mn", "Minnesota", 91067488), ("ms", "Mississippi", 56275764),
            ("mo", "Missouri", 128190467), ("mt", "Montana", 55927395), ("ne", "Nebraska", 43248777), ("nv", "Nevada", 68412194),
            ("nh", "New Hampshire", 36822888), ("nj", "New Jersey", 79525284), ("nm", "New Mexico", 63689894), ("ny", "New York", 150764306),
            ("nc", "North Carolina", 60514508), ("nd", "North Dakota", 41562516), ("oh", "Ohio", 75789992), ("ok", "Oklahoma", 84001469),
            ("or", "Oregon", 116478694), ("pa", "Pennsylvania", 96295912), ("ri", "Rhode Island", 12129227), ("sc", "South Carolina", 89943638),
            ("sd", "South Dakota", 28660212), ("tn", "Tennessee", 111948468), ("tx", "Texas", 215225269), ("ut", "Utah", 66130822),
            ("vt", "Vermont", 21195470), ("va", "Virginia", 176209640), ("wa", "Washington", 137352437), ("wv", "West Virginia", 45884796),
            ("wi", "Wisconsin", 109146683), ("wy", "Wyoming", 43861302)
        ]
        for (id, title, bytes) in us {
            rows.append(.init(
                id: id,
                title: title,
                subtitle: "OSM · United States",
                approxBytes: bytes,
                install: .unavailable,
                country: .unitedStates
            ))
        }
        return rows
    }()

    // MARK: - Private

    private func applyCatalog(published: Set<String>, sizes: [String: Int64]) {
        let prior = Dictionary(uniqueKeysWithValues: regions.map { ($0.id, $0.install) })
        regions = Self.catalogSeed.map { seed in
            var row = seed
            if let exact = sizes[seed.id] { row.exactBytes = exact }
            // Preserve in-flight download progress across manifest refreshes.
            if case .downloading(let p) = prior[seed.id] {
                row.install = .downloading(p)
            } else if isInstalled(seed.id) {
                row.install = .installed
            } else if published.contains(seed.id) {
                row.install = .available
            } else {
                row.install = .unavailable
            }
            row.revisionState = packRevisionState(seed.id)
            return row
        }
    }

    private func refreshInstalledFromDisk() {
        loadedRegionIds = Self.catalogSeed.map(\.id).filter { isInstalled($0) }
        regions = regions.map { row in
            var copy = row
            if case .downloading = copy.install { return copy }
            if !publishedIds.contains(row.id), !isInstalled(row.id) {
                copy.install = .unavailable
            } else if isInstalled(row.id) {
                copy.install = .installed
            } else if publishedIds.contains(row.id) {
                copy.install = .available
            }
            copy.revisionState = packRevisionState(row.id)
            return copy
        }
        // Packs decode off MainActor via `ensureActivePackAsync` when routing starts.
    }

    private func setInstall(_ id: String, _ state: InstallState) {
        regions = regions.map { row in
            guard row.id == id else { return row }
            var copy = row
            copy.install = state
            copy.revisionState = packRevisionState(id)
            return copy
        }
    }

    private func regionDir(regionId: String) -> URL {
        cacheRoot
            .appendingPathComponent(lastManifestVersion, isDirectory: true)
            .appendingPathComponent(regionId.lowercased(), isDirectory: true)
    }

    private func graphFileURL(regionId: String) -> URL {
        if let found = findGraphFileURL(regionId: regionId) { return found }
        // Destination for a fresh download into the current manifest version.
        // Prefer v3 when present for local ride-tests; catalog still ships v2.
        return regionDir(regionId: regionId).appendingPathComponent(
            AppConfig.backendEnvironment == .development && regionId.lowercased() == "ns"
                ? "graph.v4.bin"
                : "graph.v3.bin"
        )
    }

    /// Prefer `graph.v3.bin` when present (Phase E1 local packs); else `graph.v2.bin`.
    /// Searches across manifest version folders so a catalog bump does not hide installs.
    private func findGraphFileURL(regionId: String) -> URL? {
        let id = regionId.lowercased()
        let fm = FileManager.default
        let names: [String]
        if AppConfig.backendEnvironment == .development {
            names = ["graph.v4.bin", "graph.v3.bin", "graph.v2.bin"]
        } else {
            names = ["graph.v3.bin", "graph.v2.bin"]
        }

        func firstExisting(in dir: URL) -> URL? {
            for name in names {
                let url = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path) { return url }
            }
            return nil
        }

        if let hit = firstExisting(in: regionDir(regionId: id)) { return hit }

        let legacy = cacheRoot
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        if let hit = firstExisting(in: legacy) { return hit }

        guard let versions = try? fm.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for versionURL in versions {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: versionURL.path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            if let hit = firstExisting(in: versionURL.appendingPathComponent(id, isDirectory: true)) {
                return hit
            }
        }
        return nil
    }

    nonisolated private static let phonePackFileNames: Set<String> = [
        "graph.v2.bin",
        "graph.v3.bin",
        "graph.v4.bin",
        "geometry.v1.bin",
        "fuel.v1.json",
        "cross-pack-seams.v2.json"
    ]

    private func geometryFileURL(regionId: String) -> URL {
        let id = regionId.lowercased()
        let fm = FileManager.default
        // Pair geometry with the graph we will load: v3 → geometry.v1.bin;
        // v2 rollback → geometry.v1.v2-rollback.bin when present.
        if let graph = findGraphFileURL(regionId: id) {
            let dir = graph.deletingLastPathComponent()
            if graph.lastPathComponent == "graph.v2.bin" {
                let rollback = dir.appendingPathComponent("geometry.v1.v2-rollback.bin")
                if fm.fileExists(atPath: rollback.path) { return rollback }
            }
            let sibling = dir.appendingPathComponent("geometry.v1.bin")
            if fm.fileExists(atPath: sibling.path) { return sibling }
        }
        let primary = regionDir(regionId: id).appendingPathComponent("geometry.v1.bin")
        if fm.fileExists(atPath: primary.path) { return primary }
        let legacy = cacheRoot
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("geometry.v1.bin")
        if fm.fileExists(atPath: legacy.path) { return legacy }
        return regionDir(regionId: id).appendingPathComponent("geometry.v1.bin")
    }

    private func fuelFileURL(regionId: String) -> URL {
        let id = regionId.lowercased()
        let fm = FileManager.default
        let primary = regionDir(regionId: id).appendingPathComponent("fuel.v1.json")
        if fm.fileExists(atPath: primary.path) { return primary }
        if let graph = findGraphFileURL(regionId: id) {
            let sibling = graph.deletingLastPathComponent().appendingPathComponent("fuel.v1.json")
            if fm.fileExists(atPath: sibling.path) { return sibling }
        }
        return primary
    }

    private func seamsFileURL(regionId: String) -> URL {
        let id = regionId.lowercased()
        if let graph = findGraphFileURL(regionId: id) {
            return graph.deletingLastPathComponent().appendingPathComponent("cross-pack-seams.v2.json")
        }
        return regionDir(regionId: id).appendingPathComponent("cross-pack-seams.v2.json")
    }

    /// Fuel stations from installed pack sidecars in the A→B box. Offline.
    func fuelStations(from start: RouteCoordinate, to end: RouteCoordinate) -> [POIFeature] {
        // This is only a cheap prefilter. The graph search below proves actual
        // reachability. Mountain road corridors can sit far outside a straight
        // A→B box, so a 40 km pad was deleting valid onward pumps.
        let padDeg = 150_000.0 / 111_000.0
        return fuelStations(
            minLat: min(start.latitude, end.latitude) - padDeg,
            maxLat: max(start.latitude, end.latitude) + padDeg,
            minLon: min(start.longitude, end.longitude) - padDeg,
            maxLon: max(start.longitude, end.longitude) + padDeg
        )
    }

    func fuelStations(
        minLat: Double,
        maxLat: Double,
        minLon: Double,
        maxLon: Double
    ) -> [POIFeature] {
        let coords = [
            CLLocationCoordinate2D(latitude: minLat, longitude: minLon),
            CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon)
        ]
        var ids = Self.regionIds(covering: coords)
        for id in Self.regionIds(containingAny: coords) where !ids.contains(id) {
            ids.append(id)
        }
        if ids.isEmpty, let active = activePack?.regionId?.lowercased() {
            ids = [active]
        }
        var out: [POIFeature] = []
        for id in ids {
            for station in loadedFuel(regionId: id) {
                if station.latitude >= minLat, station.latitude <= maxLat,
                   station.longitude >= minLon, station.longitude <= maxLon {
                    out.append(station)
                }
            }
        }
        // Fuel packs intentionally retain every OSM/provider observation. The
        // routing search does not need to snap the same forecourt repeatedly,
        // though. Collapse only close fuel duplicates; distinct stations and
        // every region remain discoverable.
        return POIDeduper.collapseNearby(out)
    }

    private func loadedFuel(regionId: String) -> [POIFeature] {
        let id = regionId.lowercased()
        if let cached = packedFuelByRegion[id] { return cached }
        let url = fuelFileURL(regionId: id)
        let stations = Self.decodeFuelFile(url)
        packedFuelByRegion[id] = stations
        if !FileManager.default.fileExists(atPath: url.path) {
            maybeTopUpFuel(regionId: id)
        }
        return stations
    }

    nonisolated private static func decodeFuelFile(_ url: URL) -> [POIFeature] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return [] }
        return PackedFuel.decode(data)
    }

    /// Decode pack binaries. Safe to call from a background task.
    nonisolated private static func decodePack(
        regionId: String,
        graphURL: URL,
        geometryURL: URL,
        seamsURL: URL
    ) -> GraphV2Pack? {
        guard let data = try? Data(contentsOf: graphURL, options: [.mappedIfSafe]),
              let pack = try? GraphV2Pack(data: data) else { return nil }
        if pack.regionId == nil { pack.regionId = regionId }
        if FileManager.default.fileExists(atPath: geometryURL.path),
           let geomData = try? Data(contentsOf: geometryURL, options: [.mappedIfSafe]),
           let geom = try? GeometryV1Pack(data: geomData) {
            pack.geometry = geom
        }
        if pack.version >= 4,
           FileManager.default.fileExists(atPath: seamsURL.path),
           let seamData = try? Data(contentsOf: seamsURL),
           (try? pack.applyCrossPackSeams(data: seamData)) == nil {
            return nil
        }
        return pack
    }

    /// Load / switch the active pack off MainActor so toast + map gestures stay live.
    private func ensureActivePackAsync(for coordinates: [CLLocationCoordinate2D]) async {
        let needed = Self.preferredRegionOrder(for: coordinates)
        await ensureActivePackAsync(preferredRegionIds: needed)
    }

    /// Navigation prep has already resolved exact route ownership. Reuse that
    /// ordered result instead of walking every route coordinate a second time.
    private func ensureActivePackAsync(preferredRegionIds needed: [String]) async {
        let preferred = needed.first(where: { isInstalled($0) }) ?? loadedRegionIds.first
        guard let preferred else { return }
        await activateInstalledPack(regionId: preferred)
    }

    private func activateInstalledPack(regionId: String) async {
        let preferred = regionId.lowercased()
        guard isInstalled(preferred) else { return }

        if activePack?.regionId?.lowercased() == preferred {
            if activePack?.geometry == nil {
                maybeTopUpGeometry(regionId: preferred)
            }
            maybeTopUpFuel(regionId: preferred)
            maybeTopUpSeams(regionId: preferred)
            return
        }

        let graphURL = graphFileURL(regionId: preferred)
        let geometryURL = geometryFileURL(regionId: preferred)
        let seamsURL = seamsFileURL(regionId: preferred)
        // Let SwiftUI paint “Calculating route” before we touch disk.
        await Task.yield()
        let pack = await Task.detached(priority: .userInitiated) {
            Self.decodePack(
                regionId: preferred,
                graphURL: graphURL,
                geometryURL: geometryURL,
                seamsURL: seamsURL
            )
        }.value
        guard let pack else { return }
        activePack = pack
        loadedRegionIds = Array(Set(loadedRegionIds + [preferred]))
        if pack.geometry == nil {
            maybeTopUpGeometry(regionId: preferred)
        }
        maybeTopUpFuel(regionId: preferred)
        maybeTopUpSeams(regionId: preferred)
    }

    /// Primary regions for each pin, then any extra bbox hits (cross-border corridors).
    private static func preferredRegionOrder(for coordinates: [CLLocationCoordinate2D]) -> [String] {
        var ordered = regionIds(containingAny: coordinates)
        for id in regionIds(covering: coordinates) where !ordered.contains(id) {
            ordered.append(id)
        }
        return ordered
    }

    /// Quietly fetch geometry.v1 if the graph is installed but shapes are missing.
    private func maybeTopUpGeometry(regionId: String) {
        let id = regionId.lowercased()
        let geomPath = geometryFileURL(regionId: id).path
        guard !FileManager.default.fileExists(atPath: geomPath) else { return }
        guard downloadTasks["\(id)-geom"] == nil else { return }
        downloadTasks["\(id)-geom"] = Task { [weak self] in
            await self?.downloadNamedFile(regionId: id, fileName: "geometry.v1.bin")
            self?.downloadTasks["\(id)-geom"] = nil
            await self?.activateInstalledPack(regionId: id)
        }
    }

    /// Quietly fetch fuel.v1 if the graph is installed but stations are missing.
    private func maybeTopUpFuel(regionId: String) {
        let id = regionId.lowercased()
        let fuelPath = fuelFileURL(regionId: id).path
        guard !FileManager.default.fileExists(atPath: fuelPath) else { return }
        guard downloadTasks["\(id)-fuel"] == nil else { return }
        downloadTasks["\(id)-fuel"] = Task { [weak self] in
            await self?.downloadNamedFile(regionId: id, fileName: "fuel.v1.json")
            self?.downloadTasks["\(id)-fuel"] = nil
            if let self {
                self.packedFuelByRegion[id] = Self.decodeFuelFile(self.fuelFileURL(regionId: id))
            }
        }
    }

    /// A V4 graph is not rebuilt to add cross-border proof. Its small seam
    /// sidecar is downloaded and verified as part of the same catalog identity.
    private func maybeTopUpSeams(regionId: String) {
        let id = regionId.lowercased()
        guard activePack?.regionId?.lowercased() == id,
              activePack?.version ?? 0 >= 4,
              manifestFilesByRegion[id]?.contains(where: { $0.name == "cross-pack-seams.v2.json" }) == true
        else { return }
        let seamPath = seamsFileURL(regionId: id)
        if FileManager.default.fileExists(atPath: seamPath.path),
           let data = try? Data(contentsOf: seamPath),
           let pack = activePack {
            if (try? pack.applyCrossPackSeams(data: data)) != nil { return }
        }
        guard downloadTasks["\(id)-seams"] == nil else { return }
        downloadTasks["\(id)-seams"] = Task { [weak self] in
            await self?.downloadNamedFile(regionId: id, fileName: "cross-pack-seams.v2.json")
            self?.downloadTasks["\(id)-seams"] = nil
            guard let self,
                  let pack = self.activePack,
                  pack.regionId?.lowercased() == id,
                  let data = try? Data(contentsOf: self.seamsFileURL(regionId: id))
            else { return }
            try? pack.applyCrossPackSeams(data: data)
        }
    }

    private func downloadNamedFile(regionId: String, fileName: String) async {
        do {
            let (manifestData, response) = try await session.data(from: AppConfig.packManifestURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return
            }
            let manifest = try JSONDecoder().decode(PackManifest.self, from: manifestData)
            lastManifestVersion = manifest.version
            manifestFilesByRegion = Dictionary(uniqueKeysWithValues: manifest.regions.map {
                ($0.id.lowercased(), $0.files.filter { Self.phonePackFileNames.contains($0.name) })
            })
            catalogIdentityLoaded = true
            guard let region = manifest.regions.first(where: { $0.id.lowercased() == regionId }),
                  let file = region.files.first(where: { $0.name == fileName })
            else { return }
            let dest = regionDir(regionId: regionId)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let fileURL = dest.appendingPathComponent(fileName)
            if Self.fileMatchesIdentity(
                at: fileURL,
                expectedBytes: file.bytes,
                expectedSHA256: file.sha256
            ) { return }
            let remote = AppConfig.packFileURL(
                version: manifest.version,
                regionId: region.id,
                fileName: fileName
            )
            let (tmp, fileResponse) = try await session.download(from: remote)
            if let http = fileResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return
            }
            guard Self.fileMatchesIdentity(
                at: tmp,
                expectedBytes: file.bytes,
                expectedSHA256: file.sha256
            ) else { return }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: fileURL)
            }
            if Self.regionMatchesIdentity(region: region, directory: dest) {
                verifiedInstalledRegionIds.insert(regionId)
            }
        } catch {
            // Best-effort top-up; chord paint remains until shapes land.
        }
    }

    private func performDownload(
        regionId: String,
        asNavigationPrep: Bool = false,
        quiet: Bool = false,
        replaceInstalled: Bool = false
    ) async throws {
        do {
            try Task.checkCancellation()
            if asNavigationPrep {
                phase = .downloading
                progress = 0.05
            }
            let (manifestData, response) = try await session.data(from: AppConfig.packManifestURL)
            try Task.checkCancellation()
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            let manifest = try JSONDecoder().decode(PackManifest.self, from: manifestData)
            lastManifestVersion = manifest.version
            manifestFilesByRegion = Dictionary(uniqueKeysWithValues: manifest.regions.map {
                ($0.id.lowercased(), $0.files.filter { Self.phonePackFileNames.contains($0.name) })
            })
            catalogIdentityLoaded = true
            // Keep published set current so PACKS UI flips Soon → Download after deploy.
            var published = Set<String>()
            var sizes: [String: Int64] = [:]
            for region in manifest.regions {
                published.insert(region.id.lowercased())
                var total: Int64 = 0
                for file in region.files where Self.phonePackFileNames.contains(file.name) {
                    if let bytes = file.bytes { total += Int64(bytes) }
                }
                if total > 0 { sizes[region.id.lowercased()] = total }
            }
            if !published.isEmpty {
                publishedIds = published
                applyCatalog(published: published, sizes: sizes)
            }

            guard let region = manifest.regions.first(where: { $0.id.lowercased() == regionId }),
                  Self.regionHasPhoneGraph(region)
            else {
                setInstall(regionId, .unavailable)
                if asNavigationPrep {
                    phase = .skipped("No pack published for \(regionId)")
                    progress = 1
                }
                return
            }

            let existingGraph = findGraphFileURL(regionId: regionId)
            let hasChecksumValidInstalledRevision = existingGraph != nil
            let existingDir = existingGraph?.deletingLastPathComponent()
            let matchesCurrent = existingDir.map {
                Self.regionMatchesIdentity(region: region, directory: $0)
            } ?? false
            if hasChecksumValidInstalledRevision,
               matchesCurrent
                || !Self.shouldReplaceInstalledRevision(
                    hasChecksumValidInstalledRevision: true,
                    replaceInstalled: replaceInstalled,
                    protectInstalledRevisions: protectInstalledRevisions
                ) {
                if matchesCurrent {
                    verifiedInstalledRegionIds.insert(regionId)
                }
                setInstall(regionId, .installed)
                await activateInstalledPack(regionId: regionId)
                if asNavigationPrep {
                    progress = 1
                    phase = .ready
                }
                refreshInstalledFromDisk()
                return
            }

            let dest = regionDir(regionId: regionId)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let files = region.files.filter { Self.phonePackFileNames.contains($0.name) }
            let total = max(files.count, 1)
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                let fileURL = dest.appendingPathComponent(file.name)
                if Self.fileMatchesIdentity(
                    at: fileURL,
                    expectedBytes: file.bytes,
                    expectedSHA256: file.sha256
                ) {
                    let frac = Double(index + 1) / Double(total)
                    setInstall(regionId, .downloading(0.15 + 0.8 * frac))
                    if asNavigationPrep { progress = 0.15 + 0.8 * frac }
                    continue
                }
                let remote = AppConfig.packFileURL(
                    version: manifest.version,
                    regionId: region.id,
                    fileName: file.name
                )
                let frac = Double(index) / Double(total)
                setInstall(regionId, .downloading(0.1 + 0.8 * frac))
                if asNavigationPrep { progress = 0.1 + 0.8 * frac }
                let (tmp, fileResponse) = try await session.download(from: remote)
                try Task.checkCancellation()
                if let http = fileResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                guard Self.fileMatchesIdentity(
                    at: tmp,
                    expectedBytes: file.bytes,
                    expectedSHA256: file.sha256
                ) else {
                    throw PackIntegrityError.identityMismatch(regionId: regionId, fileName: file.name)
                }
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
                } else {
                    try FileManager.default.moveItem(at: tmp, to: fileURL)
                }
            }

            guard Self.regionMatchesIdentity(region: region, directory: dest) else {
                throw PackIntegrityError.regionIncomplete(regionId: regionId)
            }

            verifiedInstalledRegionIds.insert(regionId)
            setInstall(regionId, .installed)
            packedFuelByRegion.removeValue(forKey: regionId)
            await activateInstalledPack(regionId: regionId)
            if asNavigationPrep {
                progress = 1
                phase = .ready
            }
            refreshInstalledFromDisk()
            if quiet {
                let title = displayTitle(forRegionId: regionId)
                onQuietPackReady?("\(title) pack ready")
            }
        } catch is CancellationError {
            setInstall(regionId, isInstalled(regionId) ? .installed : .available)
            if asNavigationPrep { phase = .idle }
            throw CancellationError()
        } catch {
            setInstall(regionId, publishedIds.contains(regionId) ? .available : .unavailable)
            if asNavigationPrep {
                phase = .skipped(error.localizedDescription)
                progress = 1
            }
            throw error
        }
    }

    /// Bounding-box → region ids we support (corridor / nav prep).
    /// Keep Maritimes rectangles aligned with `routing/regional/select.js` REGION_BBOX
    /// (Halifax must not be NB; Moncton must not be NS).
    static func regionIds(covering coordinates: [CLLocationCoordinate2D]) -> [String] {
        guard !coordinates.isEmpty else { return [] }
        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max()
        else { return [] }

        var ids: [String] = []
        // W,S,E,N — match select.js REGION_BBOX.
        if maxLat >= 43.3, minLat <= 47.2, maxLon >= -66.6, minLon <= -59.5 { ids.append("ns") }
        if maxLat >= 44.5, minLat <= 48.2, maxLon >= -69.3, minLon <= -63.8 { ids.append("nb") }
        if maxLat >= 45.8, minLat <= 47.2, maxLon >= -64.6, minLon <= -61.9 { ids.append("pe") }
        if maxLat >= 46.5, minLat <= 60.5, maxLon >= -67.9, minLon <= -52.5 { ids.append("nl") }
        if maxLat >= 44.9, minLat <= 62.7, maxLon >= -79.8, minLon <= -57.0 { ids.append("qc") }
        if maxLat >= 41.6, minLat <= 56.9, maxLon >= -95.2, minLon <= -74.3 { ids.append("on") }
        if maxLat >= 48.9, minLat <= 60.1, maxLon >= -102.1, minLon <= -95.0 { ids.append("mb") }
        if maxLat >= 48.9, minLat <= 60.1, maxLon >= -110.1, minLon <= -101.3 { ids.append("sk") }
        if maxLat >= 48.9, minLat <= 60.1, maxLon >= -120.1, minLon <= -109.9 { ids.append("ab") }
        if maxLat >= 48.2, minLat <= 60.1, maxLon >= -139.1, minLon <= -114.0 { ids.append("bc") }
        if maxLat >= 59.8, minLat <= 69.7, maxLon >= -141.1, minLon <= -123.8 { ids.append("yt") }
        if maxLat >= 60.0, minLat <= 78.8, maxLon >= -136.5, minLon <= -102.0 { ids.append("nt") }
        if maxLat >= 51.6, minLat <= 83.2, maxLon >= -120.9, minLon <= -60.9 { ids.append("nu") }
        for (id, bounds) in usStateBounds {
            let (west, south, east, north) = bounds
            if maxLat >= south, minLat <= north, maxLon >= west, minLon <= east {
                ids.append(id)
            }
        }
        return ids
    }

    /// Union of per-point **primary** regions (planning pins).
    /// Overlapping bbox hits resolve via `primaryRegionId`.
    static func regionIds(containingAny coordinates: [CLLocationCoordinate2D]) -> [String] {
        var ordered: [String] = []
        for coordinate in coordinates {
            guard let id = primaryRegionId(containing: coordinate), !ordered.contains(id) else { continue }
            ordered.append(id)
        }
        return ordered
    }

    /// Collapse legacy QC quadrant / shard ids to one province pack family.
    /// Lockstep: `scripts/pack-fabric/routing/regional/select.js` `provinceFamily`.
    static func provinceFamily(_ regionId: String) -> String {
        let id = regionId.lowercased()
        if id == "qc" || id.hasPrefix("qc-") { return "qc" }
        return id
    }

    /// Distinct province/state families for endpoints (not internal shard ids).
    /// Use this for cross-region product decisions (force-Clean, fuel windows).
    static func endpointProvinceIds(containingAny coordinates: [CLLocationCoordinate2D]) -> [String] {
        var ordered: [String] = []
        for coordinate in coordinates {
            guard let primary = primaryRegionId(containing: coordinate) else { continue }
            let family = provinceFamily(primary)
            if !ordered.contains(family) { ordered.append(family) }
        }
        return ordered
    }

    /// True only when endpoints sit in different provinces/states.
    static func endpointsCrossProvince(_ coordinates: [CLLocationCoordinate2D]) -> Bool {
        endpointProvinceIds(containingAny: coordinates).count > 1
    }

    /// Prefer the correct province/state when a coordinate sits in overlapping bboxes.
    /// Mirrors `routing/regional/select.js` `primaryRegionForPoint`.
    static func primaryRegionId(containing coordinate: CLLocationCoordinate2D) -> String? {
        let hits = Set(regionIds(covering: [coordinate]))
        guard !hits.isEmpty else { return nil }
        let lon = coordinate.longitude
        let lat = coordinate.latitude

        if let owner = RegionPolygons.polygonOwner(longitude: lon, latitude: lat) {
            return owner
        }

        // Resolve the international border before overlapping Canadian
        // province rectangles. Southern BC is also inside AB's coarse bbox.
        if lat < 49.0 {
            if hits.contains("bc"), hits.contains("wa") { return "wa" }
            if hits.contains("bc"), hits.contains("id") { return "id" }
            if hits.contains("ab"), hits.contains("mt") { return "mt" }
            if hits.contains("sk"), hits.contains("mt") { return "mt" }
            if hits.contains("sk"), hits.contains("nd") { return "nd" }
            if hits.contains("mb"), hits.contains("nd") { return "nd" }
            if hits.contains("mb"), hits.contains("mn") { return "mn" }
        }

        // AB vs BC — rectangles overlap on purpose. North of ~54°N the border is
        // 120°W; south it follows the continental divide (~114–116°W).
        if hits.contains("ab"), hits.contains("bc") {
            if lat >= 54 { return lon < -120 ? "bc" : "ab" }
            // Lake Louise AB ≈ -116.2; Golden BC ≈ -117.0.
            return lon < -116.4 ? "bc" : "ab"
        }

        // Canada↔US — BC/AB rectangles overlap northern US; prefer the 49th parallel.
        if hits.contains("bc"), hits.contains("wa") { return lat >= 49.0 ? "bc" : "wa" }
        if hits.contains("bc"), hits.contains("id") { return lat >= 49.0 ? "bc" : "id" }
        if hits.contains("ab"), hits.contains("mt") { return lat >= 49.0 ? "ab" : "mt" }
        if hits.contains("sk"), hits.contains("mt") { return lat >= 49.0 ? "sk" : "mt" }
        if hits.contains("sk"), hits.contains("nd") { return lat >= 49.0 ? "sk" : "nd" }
        if hits.contains("mb"), hits.contains("nd") { return lat >= 49.0 ? "mb" : "nd" }
        if hits.contains("mb"), hits.contains("mn") { return lat >= 49.0 ? "mb" : "mn" }
        if hits.contains("nb"), hits.contains("me") {
            return lon <= -67.78 ? "me" : "nb"
        }

        // QC↔US — 45th for NY/VT/NH; Maine's rectangle must not steal Beauce.
        if hits.contains("qc"), hits.contains("ny") { return lat >= 45.01 ? "qc" : "ny" }
        if hits.contains("qc"), hits.contains("vt") { return lat >= 45.01 ? "qc" : "vt" }
        if hits.contains("qc"), hits.contains("nh") { return lat >= 45.01 ? "qc" : "nh" }
        if hits.contains("qc"), hits.contains("me") {
            if lon <= -70.55 { return "qc" }
            if lat >= 47.35, lon <= -69.05 { return "qc" }
            return "me"
        }

        // ON↔US — Niagara / St. Lawrence / Detroit River (pack id, not a scenic funnel).
        if hits.contains("on"), hits.contains("ny") {
            if lat < 43.9, lon > -79.12 { return "ny" }
            if lat < 44.3, lon > -76.5 { return "ny" }
            return "on"
        }
        if hits.contains("on"), hits.contains("mi") {
            if lat < 42.55 { return lon <= -83.045 ? "mi" : "on" }
            if lat < 43.2 { return lon <= -82.42 ? "mi" : "on" }
            return "on"
        }

        if hits.contains("on"), hits.contains("mb") {
            return lon < -95.15 ? "mb" : "on"
        }
        // ON vs MN — MN's NE rectangle covers Thunder Bay / north of Pigeon River (ON).
        if hits.contains("on"), hits.contains("mn") {
            if lat >= 48.05, lon >= -91.5 { return "on" }
            return "mn"
        }
        if hits.contains("mb"), hits.contains("sk") {
            return lon < -101.36 ? "sk" : "mb"
        }
        if hits.contains("sk"), hits.contains("ab") {
            return lon < -110.0 ? "ab" : "sk"
        }

        // ON vs Quebec — Ottawa River bank split (select.js parity).
        if hits.contains("on"), hits.contains("qc") {
            if lon >= -74.5 { return "qc" }
            if lat >= 45.9, lon >= -76.0 { return "qc" }
            if isNorthOfOttawaRiver(lon: lon, lat: lat) { return "qc" }
            return "on"
        }

        // NS vs NB — Tantramar / Missaguash. Must run before NB↔QC: Quebec’s
        // rectangular bbox covers the Maritimes and would steal Amherst as NB.
        // NS’s bbox also covers PE + Cape Jourimain — never claim those as NS.
        if hits.contains("ns"), hits.contains("nb"), hits.contains("pe") {
            if lat < 46.0 { return lon >= -64.27 ? "ns" : "nb" }
            if lon >= -63.75 { return "pe" }
            return "nb"
        }
        if hits.contains("ns"), hits.contains("pe"), !hits.contains("nb") {
            return "pe"
        }
        if hits.contains("ns"), hits.contains("nb") {
            // NB's coarse east edge covers Digby / Annapolis / Kentville. Those
            // points are deep inside NS and only skim NB — keep them Nova Scotia.
            // Missaguash (~-64.27) applies when the point is not clearly deeper in NS.
            let nsScore = canadaBboxInteriorScore(lon: lon, lat: lat, regionId: "ns")
            let nbScore = canadaBboxInteriorScore(lon: lon, lat: lat, regionId: "nb")
            if nsScore > nbScore * 1.5 { return "ns" }
            if lon >= -64.27 { return "ns" }
            return "nb"
        }

        // NB vs PE — Northumberland Strait / Confederation Bridge.
        if hits.contains("nb"), hits.contains("pe") {
            if lat < 46.0 { return "nb" }
            if lon >= -63.75 { return "pe" }
            return "nb"
        }

        // NB vs Quebec river corridor (Dégelis / Témiscouata) only — not Maritimes.
        if hits.contains("nb"), hits.contains("qc"), !hits.contains("ns"), !hits.contains("pe") {
            if lon <= -68.45 { return "qc" }
            if lat >= 47.7, lon <= -68.2 { return "qc" }
            if lon <= -67.2, lat >= 47.0 { return "nb" }
        }

        // Overlapping US rectangles: pick the state the point sits deeper inside
        // (WA/OR Columbia, CA/OR 42nd). Not a named mountain pass.
        let usHits = hits.filter { usStateBounds[$0] != nil }
        if usHits.count >= 2 {
            return usHits.max(by: {
                bboxInteriorScore(lon: lon, lat: lat, regionId: $0) < bboxInteriorScore(lon: lon, lat: lat, regionId: $1)
            })
        }

        // Smallest overlapping bbox wins (ME↔NB, remaining Canada overlaps).
        // Do not use a fixed "compact province" priority — that stole Moncton as NS and Bangor as NB.
        let areas: [(String, Double)] = hits.map { id in
            (id, bboxArea(forRegionId: id))
        }
        return areas.min(by: { $0.1 < $1.1 })?.0
    }

    private static func isNorthOfOttawaRiver(lon: Double, lat: Double) -> Bool {
        if lon < -76.5 || lon > -74.5 { return false }
        if lon >= -75.55 { return lat >= 45.475 }
        if lon >= -75.75 { return lat >= 45.44 }
        if lon >= -75.95 { return lat >= 45.4 }
        return lat >= 45.38
    }

    private static func bboxInteriorScore(lon: Double, lat: Double, regionId: String) -> Double {
        guard let b = usStateBounds[regionId] else { return -Double.greatestFiniteMagnitude }
        let (west, south, east, north) = b
        return min(lon - west, east - lon, lat - south, north - lat)
    }

    private static func canadaBboxInteriorScore(lon: Double, lat: Double, regionId: String) -> Double {
        guard let b = bbox(forRegionId: regionId) else { return -Double.greatestFiniteMagnitude }
        let (west, south, east, north) = b
        return min(lon - west, east - lon, lat - south, north - lat)
    }

    private static func bbox(forRegionId id: String) -> (Double, Double, Double, Double)? {
        switch id {
        case "ns": return (-66.6, 43.3, -59.5, 47.2)
        case "nb": return (-69.3, 44.5, -63.8, 48.2)
        case "pe": return (-64.6, 45.8, -61.9, 47.2)
        case "nl": return (-67.9, 46.5, -52.5, 60.5)
        case "qc": return (-79.8, 44.9, -57.0, 62.7)
        case "on": return (-95.2, 41.6, -74.3, 56.9)
        case "mb": return (-102.1, 48.9, -95.0, 60.1)
        case "sk": return (-110.1, 48.9, -101.3, 60.1)
        case "ab": return (-120.1, 48.9, -109.9, 60.1)
        case "bc": return (-139.1, 48.2, -114.0, 60.1)
        case "yt": return (-141.1, 59.8, -123.8, 69.7)
        case "nt": return (-136.5, 60.0, -102.0, 78.8)
        case "nu": return (-120.9, 51.6, -60.9, 83.2)
        default: return usStateBounds[id]
        }
    }

    private static func bboxArea(forRegionId id: String) -> Double {
        switch id {
        case "ns": return (-59.5 - -66.6) * (47.2 - 43.3)
        case "nb": return (-63.8 - -69.3) * (48.2 - 44.5)
        case "pe": return (-61.9 - -64.6) * (47.2 - 45.8)
        case "nl": return (-52.5 - -67.9) * (60.5 - 46.5)
        case "qc": return (-57.0 - -79.8) * (62.7 - 44.9)
        case "on": return (-74.3 - -95.2) * (56.9 - 41.6)
        case "mb": return (-95.0 - -102.1) * (60.1 - 48.9)
        case "sk": return (-101.3 - -110.1) * (60.1 - 48.9)
        case "ab": return (-109.9 - -120.1) * (60.1 - 48.9)
        case "bc": return (-114.0 - -139.1) * (60.1 - 48.2)
        case "yt": return (-123.8 - -141.1) * (69.7 - 59.8)
        case "nt": return (-102.0 - -136.5) * (78.8 - 60.0)
        case "nu": return (-60.9 - -120.9) * (83.2 - 51.6)
        default:
            guard let b = usStateBounds[id] else { return Double.greatestFiniteMagnitude }
            return (b.2 - b.0) * (b.3 - b.1)
        }
    }

    private static let usStateBounds: [String: (Double, Double, Double, Double)] = [
        "ak": (-180.0, 51.6, -130.0, 71.4),
        "al": (-88.5, 30.2, -84.9, 35.0),
        "ar": (-94.6, 33.0, -89.7, 36.5),
        "az": (-114.8, 31.3, -109.0, 37.0),
        "ca": (-124.4, 32.5, -114.1, 42.0),
        "co": (-109.1, 37.0, -102.0, 41.0),
        "ct": (-73.7, 41.0, -71.8, 42.1),
        "de": (-75.8, 38.5, -75.0, 39.8),
        "fl": (-87.6, 25.1, -80.0, 31.0),
        "ga": (-85.6, 30.4, -80.9, 35.0),
        "hi": (-159.8, 18.9, -154.8, 22.2),
        "ia": (-96.6, 40.4, -90.1, 43.5),
        "id": (-117.2, 42.0, -111.0, 49.0),
        "il": (-91.5, 37.0, -87.5, 42.5),
        "in": (-88.1, 37.8, -84.8, 41.8),
        "ks": (-102.1, 37.0, -94.6, 40.0),
        "ky": (-89.4, 36.5, -82.0, 39.1),
        "la": (-94.0, 29.0, -89.0, 33.0),
        "ma": (-73.5, 41.5, -69.9, 42.9),
        "md": (-79.5, 37.9, -75.0, 39.7),
        "me": (-71.1, 43.1, -67.0, 47.5),
        "mi": (-90.4, 41.7, -82.4, 48.2),
        "mn": (-97.2, 43.5, -89.6, 49.4),
        "mo": (-95.8, 36.0, -89.1, 40.6),
        "ms": (-91.6, 30.2, -88.1, 35.0),
        "mt": (-116.0, 44.4, -104.0, 49.0),
        "nc": (-84.3, 33.8, -75.7, 36.6),
        "nd": (-104.0, 45.9, -96.6, 49.0),
        "ne": (-104.1, 40.0, -95.3, 43.0),
        "nh": (-72.5, 42.7, -70.7, 45.3),
        "nj": (-75.6, 39.0, -73.9, 41.4),
        "nm": (-109.0, 31.3, -103.0, 37.0),
        "nv": (-120.0, 35.0, -114.0, 42.0),
        "ny": (-79.8, 40.5, -72.1, 45.0),
        "oh": (-84.8, 38.4, -80.5, 42.0),
        "ok": (-103.0, 33.6, -94.4, 37.0),
        "or": (-124.6, 42.0, -116.5, 46.3),
        "pa": (-80.5, 39.7, -74.7, 42.3),
        "ri": (-71.9, 41.3, -71.1, 42.0),
        "sc": (-83.3, 32.0, -78.5, 35.2),
        "sd": (-104.1, 42.5, -96.4, 45.9),
        "tn": (-90.3, 35.0, -81.7, 36.7),
        "tx": (-106.6, 25.9, -93.5, 36.5),
        "ut": (-114.0, 37.0, -109.0, 42.0),
        "va": (-83.7, 36.5, -75.2, 39.5),
        "vt": (-73.4, 42.7, -71.5, 45.0),
        "wa": (-124.7, 45.5, -116.9, 49.0),
        "wi": (-92.9, 42.5, -87.0, 47.0),
        "wv": (-82.6, 37.2, -77.7, 40.6),
        "wy": (-111.1, 41.0, -104.1, 45.0)
    ]

    /// Clear copy when a pack covers the pin but nearest-road snap / path failed.
    func onDeviceRouteFailureMessage(
        for coordinates: [CLLocationCoordinate2D],
        reason: OnDeviceRouter.Failure? = nil
    ) -> String {
        let needed = Self.regionIds(containingAny: coordinates)
        let titles = needed.map { displayTitle(forRegionId: $0) }
        let regionClause: String = {
            if titles.isEmpty { return "this area" }
            if titles.count == 1 { return titles[0] }
            return titles.joined(separator: " / ")
        }()
        switch reason {
        case .cannotSnapStart:
            return "Your start isn’t close enough to a mapped road in \(regionClause) (limit \(Int(OnDeviceRouter.preferredMatchMeters)) m). Move closer or drop A on the road — B stays put."
        case .cannotSnapEnd:
            return "Point B isn’t close enough to a mapped road in \(regionClause) (limit \(Int(OnDeviceRouter.preferredMatchMeters)) m). Nudge B onto the roadway centerline."
        case .identicalEnds:
            return "Start and finish locked to the same junction. Move B farther along the road."
        case .noPath:
            return "No on-device path between those points in \(regionClause). The pack roads near A and B don’t connect under this profile — try Balanced, nudge B onto a through-road, or turn on Allow unknown."
        case .searchLimit(let limit):
            return "The on-device route search reached its \(limit) safety limit in \(regionClause). Try a shorter stage or add an intermediate waypoint."
        case .none:
            return "Couldn’t build an on-device route in \(regionClause). Check which end is off the roadway and nudge that pin."
        }
    }

    nonisolated static func fileMatchesIdentity(
        at url: URL,
        expectedBytes: Int?,
        expectedSHA256: String?
    ) -> Bool {
        guard let expectedBytes,
              let expectedSHA256,
              expectedSHA256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              values.fileSize == expectedBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return false }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest.caseInsensitiveCompare(expectedSHA256) == .orderedSame
    }

    nonisolated private static func regionHasPhoneGraph(_ region: PackManifest.Region) -> Bool {
        region.files.contains {
            $0.name == "graph.v4.bin" || $0.name == "graph.v3.bin" || $0.name == "graph.v2.bin"
        }
    }

    nonisolated private static func regionMatchesIdentity(
        region: PackManifest.Region,
        directory: URL
    ) -> Bool {
        let files = region.files.filter { phonePackFileNames.contains($0.name) }
        guard regionHasPhoneGraph(region) else { return false }
        return files.allSatisfy { file in
            fileMatchesIdentity(
                at: directory.appendingPathComponent(file.name),
                expectedBytes: file.bytes,
                expectedSHA256: file.sha256
            )
        }
    }

    nonisolated private static func verifyInstalledRegions(
        manifest: PackManifest,
        cacheRoot: URL
    ) async -> Set<String> {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            var verified = Set<String>()
            let versionRoot = cacheRoot.appendingPathComponent(manifest.version, isDirectory: true)
            let legacyRoot = cacheRoot.appendingPathComponent("v1", isDirectory: true)
            let versionFolders = (try? fm.contentsOfDirectory(
                at: cacheRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for region in manifest.regions {
                let id = region.id.lowercased()
                let roots = [versionRoot, legacyRoot] + versionFolders
                if roots.contains(where: { root in
                    regionMatchesIdentity(
                        region: region,
                        directory: root.appendingPathComponent(id, isDirectory: true)
                    )
                }) {
                    verified.insert(id)
                }
            }
            return verified
        }.value
    }
}

private enum PackIntegrityError: LocalizedError {
    case identityMismatch(regionId: String, fileName: String)
    case regionIncomplete(regionId: String)

    var errorDescription: String? {
        switch self {
        case .identityMismatch(let regionId, let fileName):
            return "Downloaded \(regionId)/\(fileName) did not match the approved catalog identity."
        case .regionIncomplete(let regionId):
            return "Installed \(regionId) pack is incomplete or does not match the approved catalog identity."
        }
    }
}

private struct PackManifest: Decodable, Sendable {
    var version: String
    var regions: [Region]

    struct Region: Decodable, Sendable {
        var id: String
        var files: [File]
    }

    struct File: Decodable, Sendable {
        var name: String
        var bytes: Int?
        var sha256: String?
    }
}
