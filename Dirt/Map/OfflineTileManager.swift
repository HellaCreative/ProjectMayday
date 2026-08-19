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

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cacheDirectory = base.appendingPathComponent("dirt-nav-basemap-v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        proxy = OfflineTileProxy(cacheDirectory: cacheDirectory)
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

    // MARK: - Prep (before navigation)

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
        prefetchTask?.cancel()
        prefetchGeneration += 1
        let generation = prefetchGeneration
        currentIdentity = identity
        // keepExisting is retained for call-site clarity / future pruning policy.
        _ = keepExisting
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let plan = CorridorTilePlanner.collectRouteTiles(
            coordinates: coordinates,
            viewportWidth: viewportSize.width,
            viewportHeight: viewportSize.height
        )
        let tiles = plan.tiles
        guard !tiles.isEmpty else {
            phase = .ready(cached: 0, total: 0)
            progress = 1
            return
        }

        let cacheRoot = cacheDirectory
        let alreadyCached = tiles.reduce(into: 0) { count, tile in
            if Self.cachedTileExists(tile, in: cacheRoot) { count += 1 }
        }
        // Same corridor already on disk — skip the download UI churn.
        if alreadyCached == tiles.count {
            phase = .downloading(completed: tiles.count, total: tiles.count)
            progress = 1
            prefetchTask = Task { @MainActor in
                await self.prepareOfflineEngage()
                guard generation == self.prefetchGeneration, !Task.isCancelled else { return }
                self.phase = .ready(cached: tiles.count, total: tiles.count)
                self.progress = 1
            }
            return
        }

        phase = .downloading(completed: alreadyCached, total: tiles.count)
        progress = Double(alreadyCached) / Double(tiles.count)

        prefetchTask = Task { @MainActor in
            var completed = alreadyCached
            var cachedHit = alreadyCached
            let concurrency = 6
            let missing = tiles.filter { !Self.cachedTileExists($0, in: cacheRoot) }
            let tileCount = tiles.count

            await withTaskGroup(of: Bool.self) { group in
                var nextIndex = 0
                var inFlight = 0

                while inFlight < concurrency, nextIndex < missing.count {
                    let tile = missing[nextIndex]
                    nextIndex += 1
                    inFlight += 1
                    group.addTask {
                        await Self.downloadTile(tile, into: cacheRoot)
                    }
                }

                for await hit in group {
                    if Task.isCancelled || generation != self.prefetchGeneration {
                        group.cancelAll()
                        return
                    }
                    inFlight -= 1
                    if hit { cachedHit += 1 }
                    completed += 1
                    self.phase = .downloading(completed: completed, total: tileCount)
                    self.progress = Double(completed) / Double(tileCount)

                    if nextIndex < missing.count {
                        let tile = missing[nextIndex]
                        nextIndex += 1
                        inFlight += 1
                        group.addTask {
                            await Self.downloadTile(tile, into: cacheRoot)
                        }
                    }
                }
            }

            guard generation == self.prefetchGeneration, !Task.isCancelled else { return }
            let successRatio = Double(cachedHit) / Double(max(tileCount, 1))
            if successRatio < 0.7 {
                self.phase = .failed("Couldn’t download enough map tiles. Get a signal and try again.")
                self.progress = successRatio
            } else {
                // Warm proxy + proxied style while the rider reads the success card,
                // so Begin Ride isn’t stuck starting the localhost server on-tap.
                await self.prepareOfflineEngage()
                guard generation == self.prefetchGeneration, !Task.isCancelled else { return }
                self.phase = .ready(cached: cachedHit, total: tileCount)
                self.progress = 1
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
        into cacheRoot: URL
    ) async -> Bool {
        let file = cacheRoot
            .appendingPathComponent("\(tile.z)", isDirectory: true)
            .appendingPathComponent("\(tile.x)", isDirectory: true)
            .appendingPathComponent("\(tile.y).mvt")
        if FileManager.default.fileExists(atPath: file.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let size = attrs[.size] as? NSNumber,
           size.intValue > 0 {
            return true
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: tile.remoteURL)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 500
            guard code == 200, !data.isEmpty else { return false }
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func cancelPrep() {
        prefetchGeneration += 1
        prefetchTask?.cancel()
        prefetchTask = nil
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
            let base = MapStyleCatalog.styleURL()
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
