import CoreLocation
import Foundation
import DirtRoutingEngine
import Observation

struct NetworkLineFeature: Sendable {
    struct Point: Sendable { let lat: Double; let lon: Double }
    let edgeId: String
    let coordinates: [Point]
    let surfaceClass: String
    let accessClass: String
    let structureType: String
    let province: String
    let roadClass: String
    /// Graph-v3 leaves (empty on v2 / live debug without leaves).
    let surfaceLeaf: String
    let surfaceFamily: String
    let roadClassLeaf: String
    let roadTier: String
    let accessLeaf: String
    let atvDesignated: Bool
}

private enum NetC {
    static let detailMinZoom = 12.5
    static let corridorKmDetail = 3.0
    static let corridorKmOverview = 2.0
    static let routeArmKmDetail = 10.0
    static let routeArmKmOverview = 20.0
    static let routeSampleStepKm = 3.0
    static let maxAnchors = 8
    static let chunkPadDeg = 0.025
    static let maxFeaturesCorridor = 1600
    static let refreshDelay = UInt64(450_000_000)
    /// Coarse seed spacing for the per-route checkpoint index (see
    /// `RouteAnchorCache`). Small relative to any `routeArmKm*` window, so
    /// the nearest checkpoint is always within one window of the true
    /// nearest vertex even on an out-and-back or loop that revisits the
    /// same physical area far apart in along-route distance.
    static let routeCheckpointStepKm = 5.0
}

/// Paints nearby edges from the installed on-device graph pack.
@MainActor
final class NetworkOverlayManager {
    private let mapState: MapState
    private let graphPacks: GraphPackStore
    private var debounceTask: Task<Void, Never>?

    /// Per-`routeGeneration` cache: the route's flattened coordinates,
    /// cumulative along-route distances, and a coarse checkpoint index.
    /// Built once when the route changes, not on every camera-settle
    /// refresh — a long DIRT route is tens of thousands of vertices, and
    /// re-flattening + re-walking that with a `CLLocation` per vertex every
    /// ~450 ms during a pan/zoom scan is the corridor-overlay half of the
    /// map choke (see `internal/map-freeze.md`, `docs/play-map-freeze.md`).
    private struct RouteAnchorCache {
        let routeGeneration: Int
        let coordinates: [RouteCoordinate]
        /// Monotonic non-decreasing, same length as `coordinates`.
        let cumulative: [Double]
        /// Coarse samples every `NetC.routeCheckpointStepKm`, each paired
        /// with its index into `coordinates`. Always includes the first and
        /// last vertex.
        let checkpoints: [(coordinate: RouteCoordinate, index: Int)]
    }
    private var routeAnchorCache: RouteAnchorCache?

    init(mapState: MapState, graphPacks: GraphPackStore) {
        self.mapState = mapState
        self.graphPacks = graphPacks
        armObservation()
    }

    private func armObservation() {
        withObservationTracking {
            _ = mapState.mapCenter.latitude
            _ = mapState.mapCenter.longitude
            _ = mapState.mapZoom
            _ = mapState.layerPrefsGeneration
            _ = mapState.routeGeneration
            _ = mapState.networkAllowUnknown
            _ = mapState.showRoutingGraphDebug
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

    private func performRefresh() async {
        let zoom = mapState.mapZoom
        let center = mapState.mapCenter
        // Logo-on GRAPH tendrils are `RoutingGraphDebugManager` in every
        // channel (Access legend + dirt tracks, local through province).
        // This corridor stays a close-zoom convenience when the logo is off.
        if mapState.showRoutingGraphDebug {
            mapState.updateNetworkFeatures([])
            return
        }
        let routeCache = cachedRouteAnchors(matching: mapState.routeGeneration)
        let hasRoute = routeCache != nil
        let detailZoom = zoom >= NetC.detailMinZoom
        if !detailZoom {
            mapState.updateNetworkFeatures([])
            return
        }

        let focus = RouteCoordinate(longitude: center.longitude, latitude: center.latitude)
        let inferred = GraphPackStore.primaryRegionId(
            containing: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude)
        )?.uppercased()
        let provinceCode = inferred ?? "NS"

        let corridorKm = detailZoom ? NetC.corridorKmDetail : NetC.corridorKmOverview
        let armKm = detailZoom ? NetC.routeArmKmDetail : NetC.routeArmKmOverview
        let maxFeatures = NetC.maxFeaturesCorridor

        var anchors: [RouteCoordinate] = []
        if hasRoute, let routeCache {
            anchors = sampleRouteAnchors(around: focus, cache: routeCache, armKm: armKm)
        }

        var points = [focus] + anchors
        if points.isEmpty { points = [focus] }
        let bbox = bboxFrom(points: points, padDeg: NetC.chunkPadDeg)

        guard let pack = graphPacks.packIfInstalled(provinceCode) else {
            mapState.updateNetworkFeatures([])
            return
        }

        let minLon = bbox.minLon, minLat = bbox.minLat, maxLon = bbox.maxLon, maxLat = bbox.maxLat
        let pool = await Task.detached(priority: .userInitiated) {
            PackNetworkOverlay.features(
                from: pack,
                minLon: minLon,
                minLat: minLat,
                maxLon: maxLon,
                maxLat: maxLat,
                province: provinceCode,
                cap: maxFeatures * 3,
                preferTendrils: true
            )
        }.value

        var selected = selectCorridorFeatures(
            pool: pool,
            focus: focus,
            anchors: anchors,
            corridorKm: corridorKm,
            maxFeatures: maxFeatures
        )
        if !mapState.networkAllowUnknown {
            selected = selected.filter { feature in
                feature.accessClass != "motorized_unknown"
                    && feature.accessClass != "motorized_excluded"
            }
        }
        mapState.updateNetworkFeatures(selected)
    }

    /// Builds (or reuses) the per-route cache. Rebuilds only when
    /// `routeGeneration` changes — the route's own geometry never moves on
    /// a pan/zoom, only the camera does, so flattening/cumulative-distance
    /// work is done once per route edit rather than on every ~450 ms settle.
    private func cachedRouteAnchors(matching routeGeneration: Int) -> RouteAnchorCache? {
        if let cache = routeAnchorCache, cache.routeGeneration == routeGeneration {
            return cache
        }
        let coordinates = mapState.routePolylineCoordinates
        guard coordinates.count >= 2 else {
            routeAnchorCache = nil
            return nil
        }
        let cumulative = GeoMath.cumulativeMeters(coordinates)
        let checkpoints = Self.buildCheckpoints(coordinates: coordinates, cumulative: cumulative)
        let cache = RouteAnchorCache(
            routeGeneration: routeGeneration,
            coordinates: coordinates,
            cumulative: cumulative,
            checkpoints: checkpoints
        )
        routeAnchorCache = cache
        return cache
    }

    private static func buildCheckpoints(
        coordinates: [RouteCoordinate],
        cumulative: [Double]
    ) -> [(coordinate: RouteCoordinate, index: Int)] {
        guard !coordinates.isEmpty else { return [] }
        var checkpoints: [(coordinate: RouteCoordinate, index: Int)] = [(coordinates[0], 0)]
        let stepM = NetC.routeCheckpointStepKm * 1000
        var nextAt = stepM
        for i in 1..<coordinates.count {
            if cumulative[i] >= nextAt {
                checkpoints.append((coordinates[i], i))
                nextAt = cumulative[i] + stepM
            }
        }
        let lastIndex = coordinates.count - 1
        if checkpoints.last?.index != lastIndex {
            checkpoints.append((coordinates[lastIndex], lastIndex))
        }
        return checkpoints
    }

    private func sampleRouteAnchors(
        around focus: RouteCoordinate,
        cache: RouteAnchorCache,
        armKm: Double
    ) -> [RouteCoordinate] {
        let route = cache.coordinates
        guard route.count >= 2 else { return [] }
        let focusLoc = CLLocation(latitude: focus.latitude, longitude: focus.longitude)
        guard let near = nearestVertexBounded(to: focusLoc, cache: cache, searchWindowKm: armKm + 8)
        else { return [] }
        if near.meters > (armKm + 8) * 1000 { return [] }

        let alongAt = cache.cumulative
        let originAlong = alongAt[near.index]
        let minAlong = originAlong - armKm * 1000
        let maxAlong = originAlong + armKm * 1000
        let stepM = NetC.routeSampleStepKm * 1000

        // `alongAt` is monotonic non-decreasing (built by consecutive-vertex
        // accumulation), so the [minAlong, maxAlong] window is a contiguous
        // index range — binary search it instead of scanning every vertex
        // in the route just to reject the ones outside the arm window.
        let lo = lowerBoundIndex(alongAt, minAlong)
        let hi = upperBoundIndex(alongAt, maxAlong)

        var anchors: [RouteCoordinate] = [route[near.index]]
        var lastKeep = -Double.greatestFiniteMagnitude
        if lo <= hi {
            for i in lo...hi {
                let along = alongAt[i]
                if !anchors.isEmpty && along - lastKeep < stepM { continue }
                anchors.append(route[i])
                lastKeep = along
            }
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

    /// Nearest-vertex search bounded to windows of the route instead of a
    /// full linear scan. Seeds from the coarse `checkpoints` index (cheap —
    /// a 1,500 km route is ~300 checkpoints at `routeCheckpointStepKm`
    /// spacing), ranks every checkpoint by straight-line distance to
    /// `focus`, then refines the full-resolution window around each
    /// checkpoint in that ranked order until the reverse triangle
    /// inequality proves no further checkpoint's window could contain a
    /// closer vertex (`checkpoint.dist - windowM >= bestMeters so far`).
    ///
    /// The single-nearest-checkpoint version of this tried and failed a
    /// standalone correctness check (`/tmp/dirt-anchor-cache-verify`, not
    /// committed) on an out-and-back/loop: the *checkpoint* nearest to
    /// `focus` is not always on the *pass* whose fine-grained vertices are
    /// nearest, because checkpoint spacing is coarser than the gap between
    /// two close-together passes. Ranking + pruning instead of picking one
    /// seed makes this exact, not approximate, while staying bounded — it
    /// explores extra checkpoint windows only when two passes are within
    /// about `searchWindowKm` of each other, which is the only case where
    /// exploring more than one window is actually necessary.
    private func nearestVertexBounded(
        to focus: CLLocation,
        cache: RouteAnchorCache,
        searchWindowKm: Double
    ) -> (index: Int, meters: Double)? {
        guard !cache.checkpoints.isEmpty else { return nil }
        let windowM = max(searchWindowKm, NetC.routeCheckpointStepKm) * 1000

        let ranked = cache.checkpoints
            .map { checkpoint -> (checkpoint: (coordinate: RouteCoordinate, index: Int), dist: Double) in
                let d = focus.distance(from: CLLocation(
                    latitude: checkpoint.coordinate.latitude,
                    longitude: checkpoint.coordinate.longitude
                ))
                return (checkpoint, d)
            }
            .sorted { $0.dist < $1.dist }

        var bestIndex = ranked[0].checkpoint.index
        var bestMeters = ranked[0].dist
        var exploredWindows: [(lo: Int, hi: Int)] = []

        for candidate in ranked {
            if candidate.dist - windowM >= bestMeters { break }
            let centerAlong = cache.cumulative[candidate.checkpoint.index]
            let lo = lowerBoundIndex(cache.cumulative, centerAlong - windowM)
            let hi = upperBoundIndex(cache.cumulative, centerAlong + windowM)
            guard lo <= hi else { continue }
            if exploredWindows.contains(where: { $0.lo <= lo && hi <= $0.hi }) { continue }
            exploredWindows.append((lo, hi))
            for i in lo...hi {
                let d = focus.distance(from: CLLocation(
                    latitude: cache.coordinates[i].latitude,
                    longitude: cache.coordinates[i].longitude
                ))
                if d < bestMeters {
                    bestMeters = d
                    bestIndex = i
                }
            }
        }
        return (bestIndex, bestMeters)
    }

    /// First index in a sorted (non-decreasing) array whose value is >= `target`.
    private func lowerBoundIndex(_ sorted: [Double], _ target: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        if target <= sorted[0] { return 0 }
        if target > sorted[sorted.count - 1] { return sorted.count - 1 }
        var lo = 0, hi = sorted.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Last index in a sorted (non-decreasing) array whose value is <= `target`.
    private func upperBoundIndex(_ sorted: [Double], _ target: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        if target >= sorted[sorted.count - 1] { return sorted.count - 1 }
        if target < sorted[0] { return 0 }
        var lo = 0, hi = sorted.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if sorted[mid] > target { hi = mid - 1 } else { lo = mid }
        }
        return lo
    }

    private func selectCorridorFeatures(
        pool: [NetworkLineFeature],
        focus: RouteCoordinate,
        anchors: [RouteCoordinate],
        corridorKm: Double,
        maxFeatures: Int
    ) -> [NetworkLineFeature] {
        let refs = [focus] + anchors
        var scored: [(feature: NetworkLineFeature, dist: Double, pri: Int)] = []
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
        return Array(scored.prefix(maxFeatures).map(\.feature))
    }

    private func featureMid(_ feature: NetworkLineFeature) -> RouteCoordinate? {
        guard !feature.coordinates.isEmpty else { return nil }
        let mid = feature.coordinates[feature.coordinates.count / 2]
        return RouteCoordinate(longitude: mid.lon, latitude: mid.lat)
    }

    private func surfacePriority(_ feature: NetworkLineFeature) -> Int {
        switch feature.surfaceClass {
        case "track": return 4
        case "access": return 3
        case "gravel": return 2
        default:
            if feature.accessClass == "motorized_restricted" { return 1 }
            return 0
        }
    }

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
}

nonisolated enum PackNetworkOverlay {
    /// Overlay paint keys. Loose/technical dirt and `highway=track|path` must
    /// be `track` so `dirt-net-track` and the GRAPH tendrils actually draw.
    /// A prior `dirt` tag ate the cap and never matched a layer; unknown
    /// surface on a track road also used to vanish.
    static func overlaySurfaceClass(_ family: SurfaceFamily, roadClass: String = "") -> String {
        if family == .loose { return "track" }
        let road = roadClass.lowercased()
        if road == "track" || road == "path" { return "track" }
        if family == .gravel { return "gravel" }
        return family.rawValue
    }

    /// GRAPH legend access keys from legal-topology codes (SOT §10 /
    /// AccessPolicy). Paint-only — PathSearch still reads the raw code.
    static func overlayAccessClass(_ code: UInt8, leaf: String = "") -> String {
        let token = leaf.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch code {
        case 0:
            return token == "permissive" ? "motorized_permissive" : "motorized_verified"
        case 1:
            return "motorized_unknown"
        case 3, 4:
            return "motorized_restricted"
        default:
            return "motorized_excluded"
        }
    }

    /// Coerce live / legacy access strings onto GRAPH legend keys.
    static func overlayAccessName(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "motorized_verified", "verified":
            return "motorized_verified"
        case "motorized_permissive", "permissive":
            return "motorized_permissive"
        case "motorized_unknown", "unknown":
            return "motorized_unknown"
        case "motorized_restricted", "restricted", "destination", "customers",
             "motorized_destination", "motorized_endpoint":
            return "motorized_restricted"
        case "motorized_excluded", "excluded", "motorized_prohibited", "prohibited",
             "motorized_denied", "denied", "motorized_impassable":
            return "motorized_excluded"
        default:
            return raw
        }
    }

    static func isTendrilSurface(_ family: SurfaceFamily, roadClass: String) -> Bool {
        if family == .loose || family == .gravel { return true }
        let road = roadClass.lowercased()
        return road == "track" || road == "path"
    }

    static func features(
        from pack: GraphPack,
        minLon: Double,
        minLat: Double,
        maxLon: Double,
        maxLat: Double,
        province: String,
        cap: Int,
        preferTendrils: Bool = false
    ) -> [NetworkLineFeature] {
        let lonSpan = max(maxLon - minLon, 0.0001)
        let latSpan = max(maxLat - minLat, 0.0001)
        let cols = 12
        let rows = 8
        let perCell = max(16, cap / (cols * rows) + 8)
        var buckets = Array(repeating: [NetworkLineFeature](), count: cols * rows)
        let endpointPad = 0.08

        func cellIndex(lon: Double, lat: Double) -> Int {
            let x = min(cols - 1, max(0, Int(((lon - minLon) / lonSpan) * Double(cols))))
            let y = min(rows - 1, max(0, Int(((lat - minLat) / latSpan) * Double(rows))))
            return y * cols + x
        }

        for edge in 0..<pack.edgeCount {
            if Task.isCancelled { break }
            let road = pack.roadClass(edge)
            let engineSurface = ProfilePolicy.family(pack.surfaceLeaf(edge))
            let family = SurfaceFamily(rawValue: engineSurface.rawValue) ?? .unknown
            let tendril = isTendrilSurface(family, roadClass: road)
            if preferTendrils, !tendril { continue }

            let from = pack.coordinate(node: pack.endpoint(edge, from: true))
            let to = pack.coordinate(node: pack.endpoint(edge, from: false))
            let west0 = min(from.longitude, to.longitude)
            let east0 = max(from.longitude, to.longitude)
            let south0 = min(from.latitude, to.latitude)
            let north0 = max(from.latitude, to.latitude)
            guard east0 >= minLon - endpointPad, west0 <= maxLon + endpointPad,
                  north0 >= minLat - endpointPad, south0 <= maxLat + endpointPad
            else { continue }

            let line = pack.polyline(edge)
            guard line.count >= 2 else { continue }
            var west = line[0].longitude, east = line[0].longitude
            var south = line[0].latitude, north = line[0].latitude
            for point in line {
                west = min(west, point.longitude)
                east = max(east, point.longitude)
                south = min(south, point.latitude)
                north = max(north, point.latitude)
            }
            guard east >= minLon, west <= maxLon, north >= minLat, south <= maxLat else { continue }

            let mid = line[line.count / 2]
            let bucket = cellIndex(lon: mid.longitude, lat: mid.latitude)
            if buckets[bucket].count >= perCell { continue }

            let accessLeaf = pack.accessLeaf(edge)
            buckets[bucket].append(NetworkLineFeature(
                edgeId: pack.edgeID(edge),
                coordinates: line.map { .init(lat: $0.latitude, lon: $0.longitude) },
                surfaceClass: overlaySurfaceClass(family, roadClass: road),
                accessClass: overlayAccessClass(pack.accessCode(edge, forward: true), leaf: accessLeaf),
                structureType: pack.structure(edge),
                province: province,
                roadClass: road,
                surfaceLeaf: pack.surfaceLeaf(edge),
                surfaceFamily: family.rawValue,
                roadClassLeaf: road,
                roadTier: ProfilePolicy.tier(road),
                accessLeaf: accessLeaf,
                atvDesignated: pack.atvDesignated(edge)
            ))
        }

        var sampled: [NetworkLineFeature] = []
        sampled.reserveCapacity(min(cap, buckets.reduce(0) { $0 + $1.count }))
        var depth = 0
        let deepest = buckets.map(\.count).max() ?? 0
        while sampled.count < cap, depth < deepest {
            for bucket in buckets where depth < bucket.count {
                sampled.append(bucket[depth])
                if sampled.count >= cap { break }
            }
            depth += 1
        }
        return sampled
    }
}
