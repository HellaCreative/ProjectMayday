import Foundation
import MapLibre
import Observation
import UIKit

/// Dual-sport offline basemap: corridor tile download + localhost proxy so
/// MapLibre can render without cell coverage.
///
/// Session rules:
/// 1. Prefetch only when the rider taps Start Navigation.
/// 2. Corridor tiles are content-addressed (z/x/y) — reuse disk cache across routes.
/// 3. Mid-trip recalculate → keep tiles (caller may pass keepExisting).
/// 4. Never wipe the tile directory on a new identity; only fetch missing tiles.
///
/// MapLibre `MLNOfflinePack` stays disabled — it aborts this process on glyph
/// template URLs. Download MVTs ourselves
/// and serve them through a local HTTP proxy pointed at by a rewritten style.
@MainActor
@Observable
final class OfflineTileManager {
    enum Phase: Equatable {
        case idle
        case downloading(completed: Int, total: Int)
        case ready(cached: Int, total: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var currentIdentity: String?
    private(set) var isEngaged = false

    /// Weak map hook for swapping basemap style during nav.
    @ObservationIgnored weak var mapState: MapState?

    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchGeneration = 0
    @ObservationIgnored private let proxy: OfflineTileProxy
    @ObservationIgnored private let cacheDirectory: URL
    @ObservationIgnored private var offlineStyleFileURL: URL?
    @ObservationIgnored private var tilePlanCache = CorridorTilePlanCache()
    @ObservationIgnored private var planPrimeTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundPrefetchTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundPrefetchQueue: [BackgroundPrefetchRequest] = []
    @ObservationIgnored private var queuedBackgroundIdentities = Set<String>()
    @ObservationIgnored private var tileSources = [ShortbreadTileSource.publicOSM]

    private struct TilePreparation: Sendable {
        let plan: CorridorTilePlanner.Plan
        let tiles: [CorridorTilePlanner.Tile]
        let alreadyCached: Int
        let missing: [CorridorTilePlanner.Tile]
        let truncated: Bool
    }

    private struct TileDownloadResult: Sendable {
        let tile: CorridorTilePlanner.Tile
        let succeeded: Bool
        let retries: Int
        let statusCategories: [String]
    }

    private struct BackgroundPrefetchRequest: Sendable {
        let identity: String
        let coordinates: [RouteCoordinate]
        let viewportWidth: Double
        let viewportHeight: Double
    }

    nonisolated private static let tileSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cacheDirectory = base.appendingPathComponent("dirt-nav-basemap-v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        proxy = OfflineTileProxy(
            cacheDirectory: cacheDirectory,
            tileSources: tileSources
        )
        // Leftover MapLibre packs from older builds still crash on resume.
        Self.purgeMapLibrePacks()
    }

    nonisolated static func purgeMapLibrePacks() {
        let storage = MLNOfflineStorage.shared
        for pack in storage.packs ?? [] {
            storage.removePack(pack, withCompletionHandler: nil)
        }
    }

    var progressPercent: Int {
        Int((progress * 100).rounded())
    }

    /// Apply the same health-approved origin to live MapLibre, blocking nav
    /// downloads, and proxy fill-through. Public Shortbread stays second as the
    /// transport fallback; the z/x/y disk cache remains compatible.
    func useTileSource(_ source: ShortbreadTileSource) {
        tileSources = source == .publicOSM ? [.publicOSM] : [source, .publicOSM]
        proxy.configure(tileSources: tileSources)
        offlineStyleFileURL = nil
    }

    // MARK: - Prep (before navigation)

    /// Build the first blocking corridor while the rider is reviewing the route.
    /// This is deliberately CPU/disk only; no tile is fetched before Start.
    func primeNavigationPlan(
        coordinates: [RouteCoordinate],
        viewportSize: CGSize = CGSize(width: 390, height: 844)
    ) {
        guard coordinates.count >= 2 else { return }
        let width = viewportSize.width
        let height = viewportSize.height
        if tilePlanCache.plan(for: coordinates, viewportWidth: width, viewportHeight: height) != nil {
            return
        }
        planPrimeTask?.cancel()
        let snapshot = coordinates
        planPrimeTask = Task { @MainActor in
            let startedAt = Date()
            let plan = await Task.detached(priority: .utility) {
                CorridorTilePlanner.collectRouteTiles(
                    coordinates: snapshot,
                    viewportWidth: width,
                    viewportHeight: height
                )
            }.value
            guard !Task.isCancelled else { return }
            self.tilePlanCache.store(
                plan,
                for: snapshot,
                viewportWidth: width,
                viewportHeight: height
            )
            RoutingDebugLog.shared.event(
                "navigation map plan primed points=\(snapshot.count) tiles=\(plan.tiles.count) "
                    + "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
            self.planPrimeTask = nil
        }
    }

    /// Begin corridor download. Shows progress UI until `phase == .ready`.
    ///
    /// Corridor tiles are content-addressed by z/x/y — never wipe the cache on a
    /// new route identity. Already-downloaded tiles for this geography are reused;
    /// only missing tiles hit the network.
    func prepareForNavigation(
        identity: String,
        coordinates: [RouteCoordinate],
        keepExisting: Bool,
        viewportSize: CGSize = CGSize(width: 390, height: 844)
    ) {
        planPrimeTask?.cancel()
        planPrimeTask = nil
        cancelBackgroundPrefetch()
        prefetchTask?.cancel()
        prefetchGeneration += 1
        let generation = prefetchGeneration
        currentIdentity = identity
        // keepExisting is retained for call-site clarity / future pruning policy.
        _ = keepExisting
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        // Publish a visible state before route analysis or cache inspection. Long,
        // detailed routes can contain thousands of vertices; doing this work here
        // used to freeze the Start button before the overlay could render.
        phase = .downloading(completed: 0, total: 0)
        progress = 0
        let startedAt = Date()
        let identityKind = identity.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "route"
        RoutingDebugLog.shared.event(
            "navigation map prep begin points=\(coordinates.count) identityKind=\(identityKind)"
        )

        let cacheRoot = cacheDirectory
        let coordinateSnapshot = coordinates
        let viewportWidth = viewportSize.width
        let viewportHeight = viewportSize.height
        let sourceSnapshot = tileSources
        let reusablePlan = tilePlanCache.plan(
            for: coordinates,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight
        )
        prefetchTask = Task { @MainActor in
            await Task.yield()
            let scan = await Task.detached(priority: .userInitiated) {
                let plan = reusablePlan ?? CorridorTilePlanner.collectRouteTiles(
                    coordinates: coordinateSnapshot,
                    viewportWidth: viewportWidth,
                    viewportHeight: viewportHeight
                )
                var alreadyCached = 0
                var missing: [CorridorTilePlanner.Tile] = []
                missing.reserveCapacity(plan.tiles.count)
                for tile in plan.tiles {
                    if Self.cachedTileExists(tile, in: cacheRoot) {
                        alreadyCached += 1
                    } else {
                        missing.append(tile)
                    }
                }
                return TilePreparation(
                    plan: plan,
                    tiles: plan.tiles,
                    alreadyCached: alreadyCached,
                    missing: missing,
                    truncated: plan.truncated
                )
            }.value
            guard generation == self.prefetchGeneration, !Task.isCancelled else { return }

            if reusablePlan == nil {
                self.tilePlanCache.store(
                    scan.plan,
                    for: coordinateSnapshot,
                    viewportWidth: viewportWidth,
                    viewportHeight: viewportHeight
                )
            }

            let tiles = scan.tiles
            let alreadyCached = scan.alreadyCached
            let planCacheLabel = reusablePlan == nil ? "miss" : "hit"
            RoutingDebugLog.shared.event(
                "navigation map prep planned tiles=\(tiles.count) cached=\(alreadyCached) "
                    + "missing=\(scan.missing.count) truncated=\(scan.truncated ? 1 : 0) "
                    + "planCache=\(planCacheLabel) "
                    + "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )

            guard !tiles.isEmpty else {
                self.phase = .ready(cached: 0, total: 0)
                self.progress = 1
                return
            }

            self.phase = .downloading(completed: alreadyCached, total: tiles.count)
            self.progress = Double(alreadyCached) / Double(tiles.count)

            // Same corridor already on disk — skip network work entirely.
            if alreadyCached == tiles.count {
                await self.prepareOfflineEngage()
                guard generation == self.prefetchGeneration, !Task.isCancelled else { return }
                self.phase = .ready(cached: tiles.count, total: tiles.count)
                self.progress = 1
                RoutingDebugLog.shared.event(
                    "navigation map prep ready source=cache tiles=\(tiles.count) "
                        + "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
                )
                return
            }

            var completed = alreadyCached
            var cachedHit = alreadyCached
            var succeeded = 0
            var failed = 0
            var retried = 0
            var failedRequired = 0
            var statusCategories: [String: Int] = [:]
            let concurrency = 6
            let missing = scan.missing
            let tileCount = tiles.count

            await withTaskGroup(of: TileDownloadResult.self) { group in
                var nextIndex = 0
                var inFlight = 0

                while inFlight < concurrency, nextIndex < missing.count {
                    let tile = missing[nextIndex]
                    nextIndex += 1
                    inFlight += 1
                    group.addTask {
                        await Self.downloadTile(tile, into: cacheRoot, sources: sourceSnapshot)
                    }
                }

                for await result in group {
                    if Task.isCancelled || generation != self.prefetchGeneration {
                        group.cancelAll()
                        return
                    }
                    inFlight -= 1
                    retried += result.retries
                    for category in result.statusCategories {
                        statusCategories[category, default: 0] += 1
                    }
                    if result.succeeded {
                        cachedHit += 1
                        succeeded += 1
                    } else {
                        failed += 1
                        if scan.plan.requiredTiles.contains(result.tile) {
                            failedRequired += 1
                        }
                    }
                    completed += 1
                    self.phase = .downloading(completed: completed, total: tileCount)
                    self.progress = Double(completed) / Double(tileCount)

                    if nextIndex < missing.count {
                        let tile = missing[nextIndex]
                        nextIndex += 1
                        inFlight += 1
                        group.addTask {
                            await Self.downloadTile(tile, into: cacheRoot, sources: sourceSnapshot)
                        }
                    }
                }
            }

            guard generation == self.prefetchGeneration, !Task.isCancelled else { return }
            let categorySummary = statusCategories.keys.sorted().map {
                "\($0):\(statusCategories[$0] ?? 0)"
            }.joined(separator: ",")
            let statusSummary = categorySummary.isEmpty ? "none" : categorySummary
            RoutingDebugLog.shared.event(
                "navigation map download requested=\(missing.count) succeeded=\(succeeded) "
                    + "failed=\(failed) retried=\(retried) status=\(statusSummary)"
            )
            let cacheRatio = Double(cachedHit) / Double(max(tileCount, 1))
            if failedRequired > 0 {
                self.phase = .failed("Some map tiles directly on the first riding section are still missing. Check your signal and try again.")
                self.progress = cacheRatio
                RoutingDebugLog.shared.event(
                    "navigation map prep failed cached=\(cachedHit) total=\(tileCount) requiredMissing=\(failedRequired) "
                        + "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
                )
            } else {
                // Warm proxy + proxied style while the rider reads the success card,
                // so Begin Ride isn’t stuck starting the localhost server on-tap.
                await self.prepareOfflineEngage()
                guard generation == self.prefetchGeneration, !Task.isCancelled else { return }
                self.phase = .ready(cached: cachedHit, total: tileCount)
                self.progress = 1
                RoutingDebugLog.shared.event(
                    "navigation map prep ready source=network cached=\(cachedHit) total=\(tileCount) "
                        + "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
                )
            }
        }
    }

    nonisolated private static func cachedTileExists(
        _ tile: CorridorTilePlanner.Tile,
        in cacheRoot: URL
    ) -> Bool {
        let file = cacheRoot
            .appendingPathComponent("\(tile.z)", isDirectory: true)
            .appendingPathComponent("\(tile.x)", isDirectory: true)
            .appendingPathComponent("\(tile.y).mvt")
        guard FileManager.default.fileExists(atPath: file.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? NSNumber else { return false }
        return size.intValue > 0
    }

    /// Background-safe tile fetch — no MainActor / Observable state.
    nonisolated private static func downloadTile(
        _ tile: CorridorTilePlanner.Tile,
        into cacheRoot: URL,
        sources: [ShortbreadTileSource]
    ) async -> TileDownloadResult {
        let file = cacheRoot
            .appendingPathComponent("\(tile.z)", isDirectory: true)
            .appendingPathComponent("\(tile.x)", isDirectory: true)
            .appendingPathComponent("\(tile.y).mvt")
        if FileManager.default.fileExists(atPath: file.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let size = attrs[.size] as? NSNumber,
           size.intValue > 0 {
            return TileDownloadResult(tile: tile, succeeded: true, retries: 0, statusCategories: ["cache"])
        }
        let primaryMaximumAttempts = 2
        var attemptsMade = 0
        var lastCategory = "transport"
        var categories: [String] = []
        for (sourceIndex, source) in sources.enumerated() {
            guard let remoteURL = source.url(for: tile) else {
                categories.append("\(source.provider.rawValue):invalid-url")
                continue
            }
            let maximumAttempts = sourceIndex == 0 ? primaryMaximumAttempts : 1
            for attempt in 1...maximumAttempts {
                attemptsMade += 1
                do {
                    let (data, response) = try await tileSession.data(from: remoteURL)
                    let code = (response as? HTTPURLResponse)?.statusCode
                    lastCategory = "\(source.provider.rawValue):\(statusCategory(for: code, hasData: !data.isEmpty))"
                    categories.append(lastCategory)
                    if code == 200, !data.isEmpty {
                        try FileManager.default.createDirectory(
                            at: file.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try data.write(to: file, options: .atomic)
                        return TileDownloadResult(
                            tile: tile,
                            succeeded: true,
                            retries: max(0, attemptsMade - 1),
                            statusCategories: categories
                        )
                    }
                    guard shouldRetry(statusCode: code, urlErrorCode: nil, attempt: attempt) else {
                        break
                    }
                } catch {
                    let urlCode = (error as? URLError)?.code
                    let detail = urlCode == nil ? "write" : "transport"
                    lastCategory = "\(source.provider.rawValue):\(detail)"
                    categories.append(lastCategory)
                    guard shouldRetry(statusCode: nil, urlErrorCode: urlCode, attempt: attempt) else {
                        break
                    }
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        return TileDownloadResult(
            tile: tile,
            succeeded: false,
            retries: max(0, attemptsMade - 1),
            statusCategories: categories.isEmpty ? [lastCategory] : categories
        )
    }

    nonisolated static func shouldRetry(
        statusCode: Int?,
        urlErrorCode: URLError.Code?,
        attempt: Int
    ) -> Bool {
        guard attempt < 2 else { return false }
        if let statusCode {
            return statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
        }
        guard let urlErrorCode else { return false }
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .resourceUnavailable
        ].contains(urlErrorCode)
    }

    nonisolated private static func statusCategory(for statusCode: Int?, hasData: Bool) -> String {
        guard let statusCode else { return "transport" }
        if statusCode == 200, !hasData { return "empty-2xx" }
        return "\(statusCode / 100)xx"
    }

    // MARK: - One-stage-ahead background preparation

    /// Quietly saves the next riding section after the blocking section is safe.
    /// Requests are serialized by section so navigation never starts a whole-route
    /// bulk download or overwhelms the public development provider.
    func prefetchInBackground(
        identity: String,
        coordinates: [RouteCoordinate],
        viewportSize: CGSize = CGSize(width: 390, height: 844)
    ) {
        guard coordinates.count >= 2,
              queuedBackgroundIdentities.insert(identity).inserted
        else { return }
        backgroundPrefetchQueue.append(
            BackgroundPrefetchRequest(
                identity: identity,
                coordinates: coordinates,
                viewportWidth: viewportSize.width,
                viewportHeight: viewportSize.height
            )
        )
        startNextBackgroundPrefetchIfNeeded()
    }

    private func startNextBackgroundPrefetchIfNeeded() {
        guard backgroundPrefetchTask == nil, !backgroundPrefetchQueue.isEmpty else { return }
        let request = backgroundPrefetchQueue.removeFirst()
        let cacheRoot = cacheDirectory
        let sourceSnapshot = tileSources
        let reusablePlan = tilePlanCache.plan(
            for: request.coordinates,
            viewportWidth: request.viewportWidth,
            viewportHeight: request.viewportHeight
        )
        backgroundPrefetchTask = Task { @MainActor in
            let startedAt = Date()
            let scan = await Task.detached(priority: .utility) {
                let plan = reusablePlan ?? CorridorTilePlanner.collectRouteTiles(
                    coordinates: request.coordinates,
                    viewportWidth: request.viewportWidth,
                    viewportHeight: request.viewportHeight
                )
                let missing = plan.tiles.filter { !Self.cachedTileExists($0, in: cacheRoot) }
                return (plan, missing)
            }.value
            guard !Task.isCancelled else { return }
            if reusablePlan == nil {
                self.tilePlanCache.store(
                    scan.0,
                    for: request.coordinates,
                    viewportWidth: request.viewportWidth,
                    viewportHeight: request.viewportHeight
                )
            }

            var succeeded = 0
            var failed = 0
            var retried = 0
            var statusCategories: [String: Int] = [:]
            let missing = scan.1
            await withTaskGroup(of: TileDownloadResult.self) { group in
                var nextIndex = 0
                var inFlight = 0
                let concurrency = 3
                while inFlight < concurrency, nextIndex < missing.count {
                    let tile = missing[nextIndex]
                    nextIndex += 1
                    inFlight += 1
                    group.addTask {
                        await Self.downloadTile(tile, into: cacheRoot, sources: sourceSnapshot)
                    }
                }
                for await result in group {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    inFlight -= 1
                    retried += result.retries
                    for category in result.statusCategories {
                        statusCategories[category, default: 0] += 1
                    }
                    if result.succeeded { succeeded += 1 } else { failed += 1 }
                    if nextIndex < missing.count {
                        let tile = missing[nextIndex]
                        nextIndex += 1
                        inFlight += 1
                        group.addTask {
                            await Self.downloadTile(tile, into: cacheRoot, sources: sourceSnapshot)
                        }
                    }
                }
            }
            guard !Task.isCancelled else { return }
            let categorySummary = statusCategories.keys.sorted().map {
                "\($0):\(statusCategories[$0] ?? 0)"
            }.joined(separator: ",")
            let statusSummary = categorySummary.isEmpty ? "none" : categorySummary
            RoutingDebugLog.shared.event(
                "navigation map lookahead identity=\(request.identity) requested=\(missing.count) "
                    + "succeeded=\(succeeded) failed=\(failed) retried=\(retried) "
                    + "status=\(statusSummary) "
                    + "elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
            self.backgroundPrefetchTask = nil
            self.startNextBackgroundPrefetchIfNeeded()
        }
    }

    private func cancelBackgroundPrefetch() {
        backgroundPrefetchTask?.cancel()
        backgroundPrefetchTask = nil
        backgroundPrefetchQueue.removeAll()
        queuedBackgroundIdentities.removeAll()
    }

    func cancelPrep() {
        prefetchGeneration += 1
        prefetchTask?.cancel()
        prefetchTask = nil
        cancelBackgroundPrefetch()
        if !isEngaged {
            phase = .idle
            progress = 0
        }
    }

    /// Hide the prep overlay after the rider begins the trek.
    func markPrepConsumed() {
        if case .ready = phase {
            phase = .idle
            progress = 0
        }
    }

    func skip() {
        cancelPrep()
    }

    // MARK: - Engage during navigation

    /// Start proxy + write proxied style ahead of Begin Ride (non-blocking for the button).
    func prepareOfflineEngage() async {
        do {
            if !proxy.isRunning {
                try await proxy.start()
            }
            let port = proxy.port
            let base = MapStyleCatalog.styleURL(tileSource: tileSources[0])
            let styleURL = try await Task.detached(priority: .userInitiated) {
                try Self.writeProxiedStyle(baseStyleURL: base, proxyPort: port)
            }.value
            offlineStyleFileURL = styleURL
        } catch {
            // Begin Ride can still attempt engage; may fall back to live tiles.
            offlineStyleFileURL = nil
        }
    }

    /// Point MapLibre at the local tile proxy and mark offline basemap active.
    func engageOfflineBasemap() async throws {
        if offlineStyleFileURL == nil || !proxy.isRunning {
            await prepareOfflineEngage()
        }
        guard let styleURL = offlineStyleFileURL else {
            throw NSError(domain: "DirtOffline", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Offline basemap style was not prepared."
            ])
        }
        mapState?.applyBasemapStyleURL(styleURL)
        isEngaged = true
    }

    /// Restore catalog style after End Navigation. Keeps tile files for reuse.
    func disengageOfflineBasemap() {
        cancelBackgroundPrefetch()
        isEngaged = false
        offlineStyleFileURL = nil
        mapState?.restoreCatalogBasemapStyle()
        phase = .idle
        progress = 0
    }

    /// Rewrite Shortbread style tiles URL to localhost proxy.
    nonisolated private static func writeProxiedStyle(baseStyleURL: URL, proxyPort: UInt16) throws -> URL {
        let data = try Data(contentsOf: baseStyleURL)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "DirtOffline", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Basemap style is not valid JSON."
            ])
        }
        let tileURL = "http://127.0.0.1:\(proxyPort)/shortbread_v1/{z}/{x}/{y}.mvt"
        if var sources = json["sources"] as? [String: Any] {
            for key in sources.keys {
                guard var source = sources[key] as? [String: Any] else { continue }
                if source["type"] as? String == "vector" {
                    source["tiles"] = [tileURL]
                    sources[key] = source
                }
            }
            json["sources"] = sources
        }
        let out = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirt-offline-style-\(proxyPort).json")
        try out.write(to: file, options: .atomic)
        return file
    }
}
