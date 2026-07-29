import CoreLocation
import Foundation
import Observation

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
    }

    private enum Prefs {
        static let autoNext = "dirt.packs.autoDownloadNextRegion"
        static let installed = "dirt.packs.installedRegionIds"
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var loadedRegionIds: [String] = []
    private(set) var activePack: GraphV2Pack?
    private(set) var regions: [RegionInfo] = GraphPackStore.catalogSeed
    private(set) var lastManifestVersion: String = "v1"
    private(set) var isRefreshingCatalog = false

    /// When online near a border, quietly fetch the next published region.
    var autoDownloadNextRegion: Bool {
        didSet { UserDefaults.standard.set(autoDownloadNextRegion, forKey: Prefs.autoNext) }
    }

    /// Fired when a quiet (auto) neighbor pack finishes — e.g. "New Brunswick pack ready".
    var onQuietPackReady: ((String) -> Void)?

    private var task: Task<Void, Never>?
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    /// Region ids started by auto-download (cancelled on End Nav).
    private var quietDownloadIds: Set<String> = []
    /// Last primary region we already considered for auto-download (spam guard).
    private var lastAutoDownloadRegionId: String?
    private var publishedIds: Set<String> = ["ns"] // known live until manifest loads

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
        autoDownloadNextRegion = UserDefaults.standard.object(forKey: Prefs.autoNext) as? Bool ?? true
        refreshInstalledFromDisk()
        Task { await refreshCatalog() }
    }

    // MARK: - Public

    var canRouteOnDevice: Bool { activePack != nil }

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
        for id in Self.regionIds(covering: routeCoordinates) { push(id) }
        if let location {
            for id in Self.regionIds(covering: [location]) { push(id) }
        }
        return ordered
    }

    /// Packs needed for this corridor that are not installed yet (and are published).
    func missingPublishedRegions(for coordinates: [CLLocationCoordinate2D]) -> [String] {
        let needed = Self.regionIds(containingAny: coordinates)
        return needed.filter { publishedIds.contains($0) && !isInstalled($0) }
    }

    func isInstalled(_ regionId: String) -> Bool {
        FileManager.default.fileExists(atPath: graphFileURL(regionId: regionId).path)
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

    /// Rider-facing offline planning copy when live `/api/route` is unavailable.
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
            return "You’re offline and this pin isn’t in a known pack region. \(installedClause) Open PACKS on Wi‑Fi to download where you ride — or reconnect for live routing."
        }

        let missing = needed.filter { !isInstalled($0) }
        if missing.isEmpty {
            return "You’re offline and on-device routing couldn’t connect those pins. \(installedClause) Try pins closer to roads, or reconnect for live routing."
        }

        let missingTitles = missing.map { displayTitle(forRegionId: $0) }
        let missingList = missingTitles.joined(separator: ", ")
        let publishedMissing = missing.filter { isPublished($0) }
        let unpublishedMissing = missing.filter { !isPublished($0) }

        if !publishedMissing.isEmpty, unpublishedMissing.isEmpty {
            return "\(missingList) isn’t on this phone. \(installedClause) Connect to the internet and download \(missingList) from PACKS — or keep your pin inside a downloaded region."
        }
        if publishedMissing.isEmpty, !unpublishedMissing.isEmpty {
            return "\(missingList) isn’t published for offline packs yet. \(installedClause) Plan inside a downloaded region offline, or reconnect for live routing."
        }
        return "Need \(missingList) for that pin. \(installedClause) Open PACKS when you have internet to download what’s published — or reconnect for live routing."
    }

    func downloadRegion(_ regionId: String, quiet: Bool = false) {
        let id = regionId.lowercased()
        guard publishedIds.contains(id) else { return }
        guard downloadTasks[id] == nil else { return }
        if quiet {
            guard quietDownloadIds.isEmpty else { return }
            quietDownloadIds.insert(id)
        }
        setInstall(id, .downloading(0.02))
        downloadTasks[id] = Task { [weak self] in
            await self?.performDownload(regionId: id, asNavigationPrep: false, quiet: quiet)
            self?.downloadTasks[id] = nil
            self?.quietDownloadIds.remove(id)
        }
    }

    func deleteRegion(_ regionId: String) {
        let id = regionId.lowercased()
        downloadTasks[id]?.cancel()
        downloadTasks[id] = nil
        quietDownloadIds.remove(id)
        let dir = regionDir(regionId: id)
        try? FileManager.default.removeItem(at: dir)
        if activePack?.regionId?.lowercased() == id {
            activePack = nil
            loadedRegionIds.removeAll { $0.lowercased() == id }
            phase = .idle
        }
        refreshInstalledFromDisk()
    }

    /// Start Nav / mid-ride: activate an installed pack covering the corridor; download if missing.
    func prepareForNavigation(coordinates: [CLLocationCoordinate2D], keepExisting: Bool) {
        task?.cancel()
        // Prefer primary provinces (Kelowna → bc), not raw overlapping bboxes (ab+bc).
        let regions = Self.preferredRegionOrder(for: coordinates)
        let preferred = regions.first { isInstalled($0) } ?? regions.first

        if keepExisting,
           let pack = activePack,
           let id = pack.regionId?.lowercased(),
           regions.contains(id) || regions.isEmpty {
            phase = .ready
            progress = 1
            return
        }

        if let preferred, isInstalled(preferred), let pack = loadPackFromDisk(regionId: preferred) {
            activePack = pack
            loadedRegionIds = [preferred]
            phase = .ready
            progress = 1
            // Optionally prefetch neighbors when online + toggle on (caller may trigger).
            return
        }

        let missing = missingPublishedRegions(for: coordinates)
        guard let first = missing.first ?? preferred else {
            phase = .skipped("No pack region for this corridor yet")
            progress = 1
            return
        }

        if !publishedIds.contains(first) {
            phase = .skipped("No pack published for \(first)")
            progress = 1
            return
        }

        phase = .downloading
        progress = 0
        task = Task { [weak self] in
            await self?.performDownload(regionId: first, asNavigationPrep: true)
        }
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
        avoidEdgeIds: [String] = []
    ) -> OnDeviceRouter.Result? {
        switch routeOnDeviceDetailed(
            from: from,
            to: to,
            profile: profile,
            allowUnknown: allowUnknown,
            avoidEdgeIds: avoidEdgeIds
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
        avoidEdgeIds: [String] = []
    ) -> Result<OnDeviceRouter.Result, OnDeviceRouter.Failure> {
        ensureActivePack(for: [from, to])
        guard let pack = activePack else { return .failure(.noPath) }
        return OnDeviceRouter(pack: pack).routeDetailed(
            from: from,
            to: to,
            profile: profile,
            allowUnknown: allowUnknown,
            avoidEdgeIds: Set(avoidEdgeIds)
        )
    }

    /// When online, fetch missing `geometry.v1` for installed regions before paint.
    func ensureRoadShapes(for coordinates: [CLLocationCoordinate2D]) async {
        let ids = Set(Self.regionIds(containingAny: coordinates).filter { isInstalled($0) })
        for id in ids {
            let geomPath = geometryFileURL(regionId: id).path
            if FileManager.default.fileExists(atPath: geomPath) {
                if activePack?.regionId?.lowercased() == id, activePack?.geometry == nil,
                   let pack = loadPackFromDisk(regionId: id) {
                    activePack = pack
                }
                continue
            }
            await downloadNamedFile(regionId: id, fileName: "geometry.v1.bin")
            if let pack = loadPackFromDisk(regionId: id) {
                activePack = pack
                if !loadedRegionIds.contains(id) { loadedRegionIds.append(id) }
            }
        }
    }

    /// If auto-download is on, quietly fetch one missing published region covering these coords.
    /// One region at a time; no-ops while a quiet download is already running.
    /// Call with the rider GPS while navigating, or the route corridor at Start Nav.
    func maybeAutoDownloadNeighbors(for coordinates: [CLLocationCoordinate2D], online: Bool) {
        guard autoDownloadNextRegion, online else { return }
        guard !coordinates.isEmpty else { return }
        guard quietDownloadIds.isEmpty else { return }

        let missing = missingPublishedRegions(for: coordinates)
        guard let id = missing.first else {
            // Track primary GPS region so crossing into a new pack re-arms the trigger.
            if let primary = Self.primaryRegionId(containing: coordinates[0]) {
                lastAutoDownloadRegionId = primary
            }
            return
        }

        // One kick per region visit (cleared on End Nav / leaving the region).
        if lastAutoDownloadRegionId == id { return }
        lastAutoDownloadRegionId = id
        downloadRegion(id, quiet: true)
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
            .init(id: "bc", title: "British Columbia", subtitle: "OSM + DRA resource/trail · mountains & coast", approxBytes: 148_000_000, install: .unavailable, country: .canada),
            .init(id: "nl", title: "Newfoundland and Labrador", subtitle: "Atlantic", approxBytes: 13_000_000, install: .unavailable, country: .canada),
            .init(id: "yt", title: "Yukon", subtitle: "North", approxBytes: 3_000_000, install: .unavailable, country: .canada),
            .init(id: "nt", title: "Northwest Territories", subtitle: "North", approxBytes: 3_000_000, install: .unavailable, country: .canada),
            .init(id: "nu", title: "Nunavut", subtitle: "North", approxBytes: 2_000_000, install: .unavailable, country: .canada)
        ]
        let us: [(String, String)] = [
            ("al", "Alabama"), ("ak", "Alaska"), ("az", "Arizona"), ("ar", "Arkansas"),
            ("ca", "California"), ("co", "Colorado"), ("ct", "Connecticut"), ("de", "Delaware"),
            ("fl", "Florida"), ("ga", "Georgia"), ("hi", "Hawaii"), ("id", "Idaho"),
            ("il", "Illinois"), ("in", "Indiana"), ("ia", "Iowa"), ("ks", "Kansas"),
            ("ky", "Kentucky"), ("la", "Louisiana"), ("me", "Maine"), ("md", "Maryland"),
            ("ma", "Massachusetts"), ("mi", "Michigan"), ("mn", "Minnesota"), ("ms", "Mississippi"),
            ("mo", "Missouri"), ("mt", "Montana"), ("ne", "Nebraska"), ("nv", "Nevada"),
            ("nh", "New Hampshire"), ("nj", "New Jersey"), ("nm", "New Mexico"), ("ny", "New York"),
            ("nc", "North Carolina"), ("nd", "North Dakota"), ("oh", "Ohio"), ("ok", "Oklahoma"),
            ("or", "Oregon"), ("pa", "Pennsylvania"), ("ri", "Rhode Island"), ("sc", "South Carolina"),
            ("sd", "South Dakota"), ("tn", "Tennessee"), ("tx", "Texas"), ("ut", "Utah"),
            ("vt", "Vermont"), ("va", "Virginia"), ("wa", "Washington"), ("wv", "West Virginia"),
            ("wi", "Wisconsin"), ("wy", "Wyoming")
        ]
        for (id, title) in us {
            rows.append(.init(
                id: id,
                title: title,
                subtitle: "United States · coming later",
                approxBytes: 20_000_000,
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
            } else if published.contains(seed.id) {
                row.install = isInstalled(seed.id) ? .installed : .available
            } else {
                row.install = .unavailable
            }
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
            return copy
        }
        if activePack == nil, let first = loadedRegionIds.first {
            activePack = loadPackFromDisk(regionId: first)
        }
    }

    private func setInstall(_ id: String, _ state: InstallState) {
        regions = regions.map { row in
            guard row.id == id else { return row }
            var copy = row
            copy.install = state
            return copy
        }
    }

    private func regionDir(regionId: String) -> URL {
        cacheRoot
            .appendingPathComponent(lastManifestVersion, isDirectory: true)
            .appendingPathComponent(regionId.lowercased(), isDirectory: true)
    }

    private func graphFileURL(regionId: String) -> URL {
        // Prefer current manifest version folder; also accept legacy v1 path.
        let primary = regionDir(regionId: regionId).appendingPathComponent("graph.v2.bin")
        if FileManager.default.fileExists(atPath: primary.path) { return primary }
        let legacy = cacheRoot
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent(regionId.lowercased(), isDirectory: true)
            .appendingPathComponent("graph.v2.bin")
        return legacy
    }

    private static let phonePackFileNames: Set<String> = [
        "graph.v2.bin",
        "geometry.v1.bin"
    ]

    private func geometryFileURL(regionId: String) -> URL {
        let primary = regionDir(regionId: regionId).appendingPathComponent("geometry.v1.bin")
        if FileManager.default.fileExists(atPath: primary.path) { return primary }
        return cacheRoot
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent(regionId.lowercased(), isDirectory: true)
            .appendingPathComponent("geometry.v1.bin")
    }

    private func loadPackFromDisk(regionId: String) -> GraphV2Pack? {
        let url = graphFileURL(regionId: regionId)
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let pack = try? GraphV2Pack(data: data) else { return nil }
        if pack.regionId == nil { pack.regionId = regionId }
        let geomURL = geometryFileURL(regionId: regionId)
        if FileManager.default.fileExists(atPath: geomURL.path),
           let geomData = try? Data(contentsOf: geomURL, options: [.mappedIfSafe]),
           let geom = try? GeometryV1Pack(data: geomData) {
            pack.geometry = geom
        }
        return pack
    }

    private func ensureActivePack(for coordinates: [CLLocationCoordinate2D]) {
        let needed = Self.preferredRegionOrder(for: coordinates)
        // Always prefer the primary province for these pins (bc before ab in Okanagan).
        if let preferred = needed.first(where: { isInstalled($0) }) {
            if activePack?.regionId?.lowercased() == preferred {
                if activePack?.geometry == nil {
                    maybeTopUpGeometry(regionId: preferred)
                }
                return
            }
            if let pack = loadPackFromDisk(regionId: preferred) {
                activePack = pack
                loadedRegionIds = Array(Set(loadedRegionIds + [preferred]))
                if pack.geometry == nil {
                    maybeTopUpGeometry(regionId: preferred)
                }
                return
            }
        }
        if let any = loadedRegionIds.first, let pack = loadPackFromDisk(regionId: any) {
            activePack = pack
            if pack.geometry == nil {
                maybeTopUpGeometry(regionId: any)
            }
        }
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
            if let pack = self?.loadPackFromDisk(regionId: id) {
                self?.activePack = pack
            }
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
            guard let region = manifest.regions.first(where: { $0.id.lowercased() == regionId }),
                  region.files.contains(where: { $0.name == fileName })
            else { return }
            let dest = regionDir(regionId: regionId)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let fileURL = dest.appendingPathComponent(fileName)
            guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
            let remote = AppConfig.packFileURL(
                version: manifest.version,
                regionId: region.id,
                fileName: fileName
            )
            let (tmp, fileResponse) = try await session.download(from: remote)
            if let http = fileResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return
            }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        } catch {
            // Best-effort top-up; chord paint remains until shapes land.
        }
    }

    private func performDownload(
        regionId: String,
        asNavigationPrep: Bool = false,
        quiet: Bool = false
    ) async {
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
                  region.files.contains(where: { $0.name == "graph.v2.bin" })
            else {
                setInstall(regionId, .unavailable)
                if asNavigationPrep {
                    phase = .skipped("No pack published for \(regionId)")
                    progress = 1
                }
                return
            }

            let dest = regionDir(regionId: regionId)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let files = region.files.filter { Self.phonePackFileNames.contains($0.name) }
            let total = max(files.count, 1)
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                let fileURL = dest.appendingPathComponent(file.name)
                if FileManager.default.fileExists(atPath: fileURL.path) {
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
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                try FileManager.default.moveItem(at: tmp, to: fileURL)
            }

            setInstall(regionId, .installed)
            if let pack = loadPackFromDisk(regionId: regionId) {
                activePack = pack
                if !loadedRegionIds.contains(regionId) {
                    loadedRegionIds.append(regionId)
                }
            }
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
        } catch {
            setInstall(regionId, publishedIds.contains(regionId) ? .available : .unavailable)
            if asNavigationPrep {
                phase = .skipped(error.localizedDescription)
                progress = 1
            }
        }
    }

    /// Bounding-box → region ids we support (corridor / nav prep).
    /// AB/BC rectangles intentionally overlap (continental divide ≠ 120°W south of 54°N).
    static func regionIds(covering coordinates: [CLLocationCoordinate2D]) -> [String] {
        guard !coordinates.isEmpty else { return [] }
        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max()
        else { return [] }

        var ids: [String] = []
        if maxLat >= 43.3, minLat <= 47.2, maxLon >= -66.6, minLon <= -59.5 { ids.append("ns") }
        if maxLat >= 44.2, minLat <= 48.2, maxLon >= -69.3, minLon <= -63.5 { ids.append("nb") }
        if maxLat >= 45.8, minLat <= 47.2, maxLon >= -64.5, minLon <= -61.9 { ids.append("pe") }
        if maxLat >= 46.5, minLat <= 60.5, maxLon >= -67.9, minLon <= -52.5 { ids.append("nl") }
        if maxLat >= 44.8, minLat <= 50.5, maxLon >= -74.8, minLon <= -63.5 { ids.append("qc") }
        if maxLat >= 41.5, minLat <= 57.0, maxLon >= -95.2, minLon <= -74.3 { ids.append("on") }
        if maxLat >= 48.8, minLat <= 60.0, maxLon >= -102.1, minLon <= -88.9 { ids.append("mb") }
        if maxLat >= 48.9, minLat <= 60.0, maxLon >= -110.1, minLon <= -101.3 { ids.append("sk") }
        if maxLat >= 48.9, minLat <= 60.0, maxLon >= -120.1, minLon <= -109.9 { ids.append("ab") }
        if maxLat >= 48.2, minLat <= 60.1, maxLon >= -139.1, minLon <= -114.0 { ids.append("bc") }
        return ids
    }

    /// Union of per-point **primary** regions (planning pins).
    /// Overlapping bbox hits resolve via `primaryRegionId` (web `select.js` parity).
    static func regionIds(containingAny coordinates: [CLLocationCoordinate2D]) -> [String] {
        var ordered: [String] = []
        for coordinate in coordinates {
            guard let id = primaryRegionId(containing: coordinate), !ordered.contains(id) else { continue }
            ordered.append(id)
        }
        return ordered
    }

    /// Prefer the correct province when a coordinate sits in overlapping bboxes.
    /// Mirrors `routing/regional/select.js` `primaryRegionForPoint` — especially AB/BC,
    /// where Alberta’s smaller bbox must not steal Kelowna / the Okanagan / Kootenays.
    static func primaryRegionId(containing coordinate: CLLocationCoordinate2D) -> String? {
        let hits = Set(regionIds(covering: [coordinate]))
        guard !hits.isEmpty else { return nil }
        let lon = coordinate.longitude
        let lat = coordinate.latitude

        // AB vs BC — rectangles overlap on purpose. North of ~54°N the border is
        // 120°W; south it follows the continental divide (~114–116°W).
        if hits.contains("ab"), hits.contains("bc") {
            if lat >= 54 { return lon < -120 ? "bc" : "ab" }
            // Lake Louise AB ≈ -116.2; Golden BC ≈ -117.0.
            return lon < -116.4 ? "bc" : "ab"
        }

        if hits.contains("on"), hits.contains("mb") {
            return lon < -95.15 ? "mb" : "on"
        }
        if hits.contains("mb"), hits.contains("sk") {
            return lon < -101.36 ? "sk" : "mb"
        }
        if hits.contains("sk"), hits.contains("ab") {
            return lon < -110.0 ? "ab" : "sk"
        }

        // Compact provinces first when Maritimes / QC rectangles overlap.
        let priority = ["pe", "ns", "nb", "nl", "yt", "nt", "nu", "qc", "mb", "sk", "bc", "ab", "on"]
        return priority.first(where: { hits.contains($0) }) ?? hits.first
    }

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
            return "Couldn’t lock onto a road at your GPS fix in \(regionClause). Move to a clearer spot, or drop Plan pins on the road."
        case .cannotSnapEnd:
            return "Couldn’t snap that pin to a road in \(regionClause). Nudge it onto the roadway centerline and try again."
        case .identicalEnds:
            return "Start and finish locked to the same junction. Move the pin farther along the road."
        case .noPath:
            return "No on-device path between those points in \(regionClause). Try another profile or turn on Allow unknown — live routing isn’t used when this pack covers the pins."
        case .none:
            return "Couldn’t build an on-device route in \(regionClause). Nudge pins onto the roadway."
        }
    }
}

private struct PackManifest: Decodable {
    var version: String
    var regions: [Region]

    struct Region: Decodable {
        var id: String
        var files: [File]
    }

    struct File: Decodable {
        var name: String
        var bytes: Int?
        var sha256: String?
    }
}
