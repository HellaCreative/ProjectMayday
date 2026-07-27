import CoreLocation
import Foundation
import Observation

// MARK: - Network feature model

struct NetworkLineFeature: Sendable {
    struct Point: Sendable { let lat: Double; let lon: Double }
    let edgeId: String
    let coordinates: [Point]
    let surfaceClass: String     // "access" | "gravel" | "track" | "paved" | "unknown"
    let accessClass: String      // "motorized_permissive" | "motorized_restricted" | "motorized_unknown"
    let structureType: String    // "bridge" | "tunnel" | "none" | ""
    let province: String         // "NS" | "NB" | "QC"
}

// MARK: - Constants (HTML app/index.html CONTEXT_* parity)

private enum NetC {
    /// Detail zoom for corridor-around-focus without an explicit province lens.
    static let detailMinZoom = 12.5
    static let corridorKmDetail = 3.0
    static let corridorKmOverview = 2.0
    static let routeArmKmDetail = 10.0
    static let routeArmKmOverview = 20.0
    static let routeSampleStepKm = 3.0
    static let maxAnchors = 8
    static let chunkPadDeg = 0.025
    static let maxChunksCorridor = 6
    static let maxChunksLens = 8
    static let maxFeaturesCorridor = 1600
    static let maxFeaturesLens = 5000
    static let refreshDelay = UInt64(450_000_000)  // 450 ms

    struct Overlay: Sendable {
        let province: String
        let manifestURL: URL
        let chunkBase: String
    }

    static let overlays: [String: Overlay] = [
        "NS": Overlay(
            province: "NS",
            manifestURL: URL(string: "https://dirt-mayday.vercel.app/app/data/ns-gov-roads.manifest.json")!,
            chunkBase: "https://dirt-mayday.vercel.app/app/data/ns-gov-chunks/"
        ),
        "NB": Overlay(
            province: "NB",
            manifestURL: URL(string: "https://dirt-mayday.vercel.app/app/data/nb-gov-roads.manifest.json")!,
            chunkBase: "https://dirt-mayday.vercel.app/app/data/nb-gov-chunks/"
        ),
        "QC": Overlay(
            province: "QC",
            manifestURL: URL(string: "https://dirt-mayday.vercel.app/app/data/qc-gov-roads.manifest.json")!,
            chunkBase: "https://dirt-mayday.vercel.app/app/data/qc-gov-chunks/"
        )
    ]
}

// MARK: - NetworkOverlayManager

/// Loads provincial road-network GeoJSON chunks from the production Vercel CDN.
///
/// HTML parity (`app/index.html` refreshContextNetwork):
/// - **Lens** (Show NS/NB/QC route lines on): viewport paint for that province.
/// - **Corridor** (toggle off + active route, or detail zoom ≥ 12.5): NS purple/blue
///   lines within 2–3 km of the map focus and route anchors — so riders can see
///   alternatives when they hit a washout / barrier on the planned route.
@MainActor
final class NetworkOverlayManager {
    private let mapState: MapState
    private var manifests:    [String: _NetManifest] = [:]
    private var manifestTasks:[String: Task<_NetManifest, Error>] = [:]
    private var chunkCaches:  [String: [String: [_NetFeature]]] = [:]  // [province: [chunkId: features]]
    private var debounceTask: Task<Void, Never>?

    init(mapState: MapState) {
        self.mapState = mapState
        armObservation()
    }

    // MARK: - Observation loop

    private func armObservation() {
        withObservationTracking {
            _ = mapState.mapCenter.latitude
            _ = mapState.mapCenter.longitude
            _ = mapState.mapZoom
            _ = mapState.layerPrefsGeneration
            _ = mapState.routeGeneration
        } onChange: {
            Task { @MainActor [weak self] in
                self?.scheduleRefresh()
                self?.armObservation()
            }
        }
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: NetC.refreshDelay)
            guard !Task.isCancelled else { return }
            await self?.performRefresh()
        }
    }

    // MARK: - Refresh

    private func performRefresh() async {
        let zoom = mapState.mapZoom
        let center = mapState.mapCenter
        let prefs = LayerPrefsSnapshot()
        let routeCoords = mapState.routePolylineCoordinates
        let hasRoute = routeCoords.count >= 2
        let detailZoom = zoom >= NetC.detailMinZoom
        let lensCode = prefs.lensProvince

        // Overview without a route and without a province lens → base map only.
        if lensCode == nil && !detailZoom && !hasRoute {
            mapState.updateNetworkFeatures([])
            return
        }

        let focus = RouteCoordinate(longitude: center.longitude, latitude: center.latitude)
        let showAll = lensCode != nil
        let provinceCode = lensCode ?? "NS"  // corridor always uses NS (HTML product law)
        guard let overlay = NetC.overlays[provinceCode] else {
            mapState.updateNetworkFeatures([])
            return
        }

        let corridorKm = showAll
            ? Double.infinity
            : (detailZoom ? NetC.corridorKmDetail : NetC.corridorKmOverview)
        let armKm = detailZoom ? NetC.routeArmKmDetail : NetC.routeArmKmOverview
        let maxChunks = showAll ? NetC.maxChunksLens : NetC.maxChunksCorridor
        let maxFeatures = showAll ? NetC.maxFeaturesLens : NetC.maxFeaturesCorridor

        var anchors: [RouteCoordinate] = []
        if !showAll && hasRoute {
            anchors = sampleRouteAnchors(around: focus, route: routeCoords, armKm: armKm)
        }

        let bbox: _BBox
        if showAll {
            // Approximate viewport from zoom (~ mercator degrees of lon span).
            let halfSpan = 180.0 / pow(2.0, zoom) * 1.4
            bbox = _BBox(
                minLon: center.longitude - halfSpan - NetC.chunkPadDeg,
                minLat: center.latitude - halfSpan * 0.75 - NetC.chunkPadDeg,
                maxLon: center.longitude + halfSpan + NetC.chunkPadDeg,
                maxLat: center.latitude + halfSpan * 0.75 + NetC.chunkPadDeg
            )
        } else {
            var points = [focus] + anchors
            if points.isEmpty { points = [focus] }
            bbox = bboxFrom(points: points, padDeg: NetC.chunkPadDeg)
        }

        // Evict other provinces when in corridor or single-lens mode.
        for code in NetC.overlays.keys where code != provinceCode {
            chunkCaches[code] = nil
        }

        do {
            let manifest = try await ensureManifest(code: provinceCode, overlay: overlay)
            let nearChunks = manifest.chunks
                .filter { bboxIntersects($0.bbox, bbox) }
                .sorted { distSq($0.bbox, center) < distSq($1.bbox, center) }
                .prefix(maxChunks)

            await loadChunks(Array(nearChunks), overlay: overlay, province: provinceCode)

            let keepIds = Set(nearChunks.map(\.id))
            chunkCaches[provinceCode] = chunkCaches[provinceCode]?.filter { keepIds.contains($0.key) }

            var rawPool: [_NetFeature] = []
            for chunk in nearChunks {
                rawPool.append(contentsOf: chunkCaches[provinceCode]?[chunk.id] ?? [])
            }

            let selected: [_NetFeature]
            if showAll {
                selected = Array(rawPool.prefix(maxFeatures))
            } else {
                selected = selectCorridorFeatures(
                    pool: rawPool,
                    focus: focus,
                    anchors: anchors,
                    corridorKm: corridorKm,
                    maxFeatures: maxFeatures
                )
            }

            let painted = selected.map { raw in
                NetworkLineFeature(
                    edgeId: raw.properties.edgeId,
                    coordinates: raw.geometry.coordinates.map { .init(lat: $0[1], lon: $0[0]) },
                    surfaceClass: raw.properties.surfaceClass,
                    accessClass: raw.properties.accessClass,
                    structureType: raw.properties.structureType ?? "none",
                    province: provinceCode
                )
            }
            mapState.updateNetworkFeatures(painted)
        } catch {
            // Keep prior paint on transient failures.
        }
    }

    // MARK: - Corridor selection (HTML selectCorridorFeatures / sampleRouteAnchors)

    private func sampleRouteAnchors(
        around focus: RouteCoordinate,
        route: [RouteCoordinate],
        armKm: Double
    ) -> [RouteCoordinate] {
        guard route.count >= 2 else { return [] }
        let focusLoc = CLLocation(latitude: focus.latitude, longitude: focus.longitude)
        guard let near = GeoMath.nearestVertex(to: focusLoc, in: route) else { return [] }
        if near.meters > (armKm + 8) * 1000 { return [] }

        let alongAt = GeoMath.cumulativeMeters(route)
        let originAlong = alongAt[near.index]
        let minAlong = originAlong - armKm * 1000
        let maxAlong = originAlong + armKm * 1000
        let stepM = NetC.routeSampleStepKm * 1000

        var anchors: [RouteCoordinate] = [route[near.index]]
        var lastKeep = -Double.greatestFiniteMagnitude
        for i in 0..<route.count {
            let along = alongAt[i]
            if along < minAlong || along > maxAlong { continue }
            if !anchors.isEmpty && along - lastKeep < stepM { continue }
            anchors.append(route[i])
            lastKeep = along
        }
        if anchors.count > NetC.maxAnchors {
            var picked: [RouteCoordinate] = []
            let step = Double(anchors.count - 1) / Double(NetC.maxAnchors - 1)
            for i in 0..<NetC.maxAnchors {
                picked.append(anchors[Int((Double(i) * step).rounded())])
            }
            return picked
        }
        return anchors
    }

    private func selectCorridorFeatures(
        pool: [_NetFeature],
        focus: RouteCoordinate,
        anchors: [RouteCoordinate],
        corridorKm: Double,
        maxFeatures: Int
    ) -> [_NetFeature] {
        let refs = [focus] + anchors
        var scored: [(feature: _NetFeature, dist: Double, pri: Int)] = []
        scored.reserveCapacity(min(pool.count, maxFeatures * 2))

        for feature in pool {
            guard let mid = featureMid(feature) else { continue }
            var best = Double.greatestFiniteMagnitude
            for ref in refs {
                let d = GeoMath.meters(mid, ref) / 1000.0
                if d < best { best = d }
                if best <= corridorKm { break }
            }
            if best > corridorKm { continue }
            scored.append((feature, best, surfacePriority(feature)))
        }

        scored.sort {
            if $0.dist != $1.dist { return $0.dist < $1.dist }
            return $0.pri > $1.pri
        }
        return scored.prefix(maxFeatures).map(\.feature)
    }

    private func featureMid(_ feature: _NetFeature) -> RouteCoordinate? {
        let coords = feature.geometry.coordinates
        guard !coords.isEmpty else { return nil }
        let mid = coords[coords.count / 2]
        guard mid.count >= 2 else { return nil }
        return RouteCoordinate(longitude: mid[0], latitude: mid[1])
    }

    private func surfacePriority(_ feature: _NetFeature) -> Int {
        let s = feature.properties.surfaceClass
        if s == "track" { return 4 }
        if s == "access" { return 3 }
        if s == "gravel" { return 2 }
        if feature.properties.structureType == "bridge" { return 3 }
        if feature.properties.structureType == "tunnel" { return 3 }
        if feature.properties.accessClass == "motorized_restricted" { return 1 }
        return 0
    }

    // MARK: - Manifest / chunks

    private func ensureManifest(code: String, overlay: NetC.Overlay) async throws -> _NetManifest {
        if let cached = manifests[code] { return cached }
        if let existing = manifestTasks[code] {
            do {
                let result = try await existing.value
                manifests[code] = result
                return result
            } catch {
                // Failed task must not stick for the session — allow a later refresh to retry.
                manifestTasks[code] = nil
                throw error
            }
        }
        let task = Task<_NetManifest, Error> {
            let (data, _) = try await URLSession.shared.data(from: overlay.manifestURL)
            return try JSONDecoder().decode(_NetManifest.self, from: data)
        }
        manifestTasks[code] = task
        do {
            let result = try await task.value
            manifests[code] = result
            manifestTasks[code] = nil
            return result
        } catch {
            manifestTasks[code] = nil
            throw error
        }
    }

    private func loadChunks(_ chunks: [_NetChunk], overlay: NetC.Overlay, province: String) async {
        var cache = chunkCaches[province] ?? [:]
        await withTaskGroup(of: (String, [_NetFeature])?.self) { group in
            for chunk in chunks where cache[chunk.id] == nil {
                group.addTask { [weak self] in
                    await self?.fetchChunk(chunk, overlay: overlay)
                }
            }
            for await result in group {
                if let (id, features) = result {
                    cache[id] = features
                }
            }
        }
        chunkCaches[province] = cache
    }

    private func fetchChunk(_ chunk: _NetChunk, overlay: NetC.Overlay) async -> (String, [_NetFeature])? {
        guard let url = URL(string: overlay.chunkBase + chunk.file) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let features: [_NetFeature] = try await Task.detached(priority: .background) {
                let raw = try data.gunzipped()
                return try JSONDecoder().decode(_GeoJSONCollection.self, from: raw).features
            }.value
            return (chunk.id, features)
        } catch {
            return nil
        }
    }

    // MARK: - Geometry helpers

    private struct _BBox { let minLon, minLat, maxLon, maxLat: Double }

    private func bboxFrom(points: [RouteCoordinate], padDeg: Double) -> _BBox {
        var minLon = Double.greatestFiniteMagnitude
        var minLat = Double.greatestFiniteMagnitude
        var maxLon = -Double.greatestFiniteMagnitude
        var maxLat = -Double.greatestFiniteMagnitude
        for p in points {
            minLon = min(minLon, p.longitude)
            minLat = min(minLat, p.latitude)
            maxLon = max(maxLon, p.longitude)
            maxLat = max(maxLat, p.latitude)
        }
        return _BBox(
            minLon: minLon - padDeg,
            minLat: minLat - padDeg,
            maxLon: maxLon + padDeg,
            maxLat: maxLat + padDeg
        )
    }

    private func bboxIntersects(_ bbox: [Double], _ b: _BBox) -> Bool {
        guard bbox.count >= 4 else { return false }
        return bbox[0] <= b.maxLon && bbox[2] >= b.minLon &&
               bbox[1] <= b.maxLat && bbox[3] >= b.minLat
    }

    private func distSq(_ bbox: [Double], _ center: CLLocationCoordinate2D) -> Double {
        guard bbox.count >= 4 else { return .greatestFiniteMagnitude }
        let cx = (bbox[0] + bbox[2]) / 2, cy = (bbox[1] + bbox[3]) / 2
        return (cx - center.longitude) * (cx - center.longitude) +
               (cy - center.latitude)  * (cy - center.latitude)
    }
}

// MARK: - Decodable models
// `nonisolated` — default MainActor isolation would make Decodable unusable in Task.detached.

nonisolated private struct _NetManifest: Decodable, Sendable {
    let generatedAt: String
    let chunkDir: String?
    let chunks: [_NetChunk]
}

nonisolated private struct _NetChunk: Decodable, Sendable {
    let id: String
    let file: String
    let bbox: [Double]
}

nonisolated private struct _GeoJSONCollection: Decodable, Sendable {
    let features: [_NetFeature]
}

nonisolated private struct _NetFeature: Decodable, Sendable {
    let geometry: _LineGeometry
    let properties: _NetProps
}

nonisolated private struct _LineGeometry: Decodable, Sendable {
    let coordinates: [[Double]]   // [[lon, lat], ...]
}

nonisolated private struct _NetProps: Decodable, Sendable {
    let edgeId: String
    let surfaceClass: String
    let accessClass: String
    let structureType: String?
}
