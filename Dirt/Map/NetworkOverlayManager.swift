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
    static let lensKm = 20.0
    static let routeArmKmDetail = 10.0
    static let routeArmKmOverview = 20.0
    static let routeSampleStepKm = 3.0
    static let maxAnchors = 8
    static let chunkPadDeg = 0.025
    static let maxFeaturesCorridor = 1600
    static let maxFeaturesLens = 5000
    static let refreshDelay = UInt64(450_000_000)
}

/// Paints nearby edges from the installed on-device graph pack.
@MainActor
final class NetworkOverlayManager {
    private let mapState: MapState
    private let graphPacks: GraphPackStore
    private var debounceTask: Task<Void, Never>?

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
        let prefs = LayerPrefsSnapshot()
        let routeCoords = mapState.routePolylineCoordinates
        let hasRoute = routeCoords.count >= 2
        let detailZoom = zoom >= NetC.detailMinZoom
        let lensCode = prefs.lensProvince

        if prefs.showBCOSMHierarchy {
            mapState.updateNetworkFeatures([])
            return
        }

        if lensCode == nil && !detailZoom && !hasRoute {
            mapState.updateNetworkFeatures([])
            return
        }

        let focus = RouteCoordinate(longitude: center.longitude, latitude: center.latitude)
        let showLens = lensCode != nil
        let wantCorridor = hasRoute || detailZoom
        let inferred = GraphPackStore.primaryRegionId(
            containing: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude)
        )?.uppercased()
        let provinceCode = lensCode ?? inferred ?? "NS"

        let corridorKm = detailZoom ? NetC.corridorKmDetail : NetC.corridorKmOverview
        let armKm = detailZoom ? NetC.routeArmKmDetail : NetC.routeArmKmOverview
        let maxFeatures = showLens ? NetC.maxFeaturesLens : NetC.maxFeaturesCorridor

        var anchors: [RouteCoordinate] = []
        if hasRoute {
            anchors = sampleRouteAnchors(around: focus, route: routeCoords, armKm: armKm)
        }

        var bbox: _BBox
        if showLens {
            bbox = bboxFromCircle(center: center, radiusKm: NetC.lensKm, padDeg: NetC.chunkPadDeg)
            if wantCorridor {
                bbox = union(bbox, bboxFrom(points: [focus] + anchors, padDeg: NetC.chunkPadDeg))
            }
        } else {
            var points = [focus] + anchors
            if points.isEmpty { points = [focus] }
            bbox = bboxFrom(points: points, padDeg: NetC.chunkPadDeg)
        }

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
                cap: maxFeatures * 3
            )
        }.value

        var selected: [NetworkLineFeature] = []
        if showLens {
            selected = selectCorridorFeatures(
                pool: pool,
                focus: focus,
                anchors: [],
                corridorKm: NetC.lensKm,
                maxFeatures: maxFeatures
            )
        }
        if wantCorridor {
            let corridor = selectCorridorFeatures(
                pool: pool,
                focus: focus,
                anchors: anchors,
                corridorKm: corridorKm,
                maxFeatures: maxFeatures
            )
            selected = mergeNetworkFeatures(selected, corridor, maxFeatures: maxFeatures)
        }
        if !mapState.networkAllowUnknown {
            selected = selected.filter { feature in
                feature.accessClass != "motorized_unknown"
                    && feature.accessClass != "motorized_excluded"
            }
        }
        mapState.updateNetworkFeatures(selected)
    }

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

    private func bboxFromCircle(
        center: CLLocationCoordinate2D,
        radiusKm: Double,
        padDeg: Double
    ) -> _BBox {
        let latPad = radiusKm / 111.32
        let lonPad = radiusKm / (111.32 * max(0.2, cos(center.latitude * .pi / 180)))
        return _BBox(
            minLon: center.longitude - lonPad - padDeg,
            minLat: center.latitude - latPad - padDeg,
            maxLon: center.longitude + lonPad + padDeg,
            maxLat: center.latitude + latPad + padDeg
        )
    }

    private func union(_ a: _BBox, _ b: _BBox) -> _BBox {
        _BBox(
            minLon: min(a.minLon, b.minLon),
            minLat: min(a.minLat, b.minLat),
            maxLon: max(a.maxLon, b.maxLon),
            maxLat: max(a.maxLat, b.maxLat)
        )
    }

    private func mergeNetworkFeatures(
        _ a: [NetworkLineFeature],
        _ b: [NetworkLineFeature],
        maxFeatures: Int
    ) -> [NetworkLineFeature] {
        var seen = Set<String>()
        var out: [NetworkLineFeature] = []
        for feature in a + b {
            if seen.contains(feature.edgeId) { continue }
            seen.insert(feature.edgeId)
            out.append(feature)
            if out.count >= maxFeatures { break }
        }
        return out
    }
}

nonisolated enum PackNetworkOverlay {
    static func features(from pack: GraphPack,minLon: Double,minLat: Double,maxLon: Double,maxLat: Double,
                         province: String,cap: Int) -> [NetworkLineFeature] {
        var result: [NetworkLineFeature] = []
        for edge in 0..<pack.edgeCount {
            if Task.isCancelled { break }
            let line = pack.polyline(edge)
            guard line.count >= 2,
                  let west = line.map(\.longitude).min(), let east = line.map(\.longitude).max(),
                  let south = line.map(\.latitude).min(), let north = line.map(\.latitude).max(),
                  east >= minLon, west <= maxLon, north >= minLat, south <= maxLat else { continue }
            let surface = ProfilePolicy.family(pack.surfaceLeaf(edge))
            result.append(NetworkLineFeature(edgeId: pack.edgeID(edge),
                coordinates: line.map { .init(lat: $0.latitude,lon: $0.longitude) },
                surfaceClass: surface == .loose ? "dirt" : surface.rawValue,
                accessClass: NativeRoutingAdapter.accessName(pack.accessCode(edge,forward: true)),
                structureType: pack.structure(edge),province: province,roadClass: pack.roadClass(edge),
                surfaceLeaf: pack.surfaceLeaf(edge),surfaceFamily: surface.rawValue,
                roadClassLeaf: pack.roadClass(edge),roadTier: ProfilePolicy.tier(pack.roadClass(edge)),
                accessLeaf: pack.accessLeaf(edge),atvDesignated: pack.atvDesignated(edge)))
            if result.count >= cap { break }
        }
        return result
    }
}
