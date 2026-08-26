import CoreLocation
import Foundation
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
    static func features(
        from pack: GraphV2Pack,
        minLon: Double,
        minLat: Double,
        maxLon: Double,
        maxLat: Double,
        province: String,
        cap: Int
    ) -> [NetworkLineFeature] {
        var out: [NetworkLineFeature] = []
        out.reserveCapacity(min(cap, 512))
        let from = pack.edgeFrom
        let to = pack.edgeTo
        for ei in 0..<pack.undirectedEdgeCount {
            var hit = false
            if let from, let to, ei < from.count, ei < to.count {
                hit = nodeIn(pack, Int(from[ei]), minLon, minLat, maxLon, maxLat)
                    || nodeIn(pack, Int(to[ei]), minLon, minLat, maxLon, maxLat)
            } else if let geom = pack.geometry {
                let line = geom.polyline(edgeIndex: ei)
                if let p = line.first {
                    hit = p.longitude >= minLon && p.longitude <= maxLon
                        && p.latitude >= minLat && p.latitude <= maxLat
                }
            }
            guard hit else { continue }
            let coords: [NetworkLineFeature.Point]
            if let geom = pack.geometry {
                let line = geom.polyline(edgeIndex: ei)
                coords = line.map { NetworkLineFeature.Point(lat: $0.latitude, lon: $0.longitude) }
            } else if let from, let to, ei < from.count, ei < to.count,
                      let a = nodeCoord(pack, Int(from[ei])),
                      let b = nodeCoord(pack, Int(to[ei])) {
                coords = [
                    NetworkLineFeature.Point(lat: a.latitude, lon: a.longitude),
                    NetworkLineFeature.Point(lat: b.latitude, lon: b.longitude)
                ]
            } else {
                continue
            }
            guard coords.count >= 2 else { continue }
            let attr = pack.edgeAttrs[ei]
            let surface = OnDeviceProfileCosts.surfaceName(code: GraphV2Pack.unpackSurface(attr))
            let accessCode = GraphV2Pack.unpackAccess(attr)
            let access = (accessCode >= 0 && accessCode < pack.accessNames.count)
                ? pack.accessNames[accessCode]
                : "motorized_unknown"
            let leaves = pack.edgeLeaves(ei)
            out.append(
                NetworkLineFeature(
                    edgeId: pack.edgeId(ei),
                    coordinates: coords,
                    surfaceClass: surface,
                    accessClass: access,
                    structureType: GraphV2Pack.structureName(GraphV2Pack.unpackStructure(attr)),
                    province: province,
                    roadClass: GraphV2Pack.roadClassName(GraphV2Pack.unpackRoadClass(attr)),
                    surfaceLeaf: leaves.surfaceLeaf ?? "",
                    surfaceFamily: PackDebugPaint.surfaceFamilyKey(
                        pack.hasLeaves ? pack.surfaceFamily(ei) : nil
                    ),
                    roadClassLeaf: leaves.roadClassLeaf ?? "",
                    roadTier: PackDebugPaint.roadTierKey(
                        pack.hasLeaves ? pack.roadTier(ei) : nil
                    ),
                    accessLeaf: leaves.accessLeaf ?? "",
                    atvDesignated: leaves.atvDesignated
                )
            )
            if out.count >= cap { break }
        }
        return out
    }

    private static func nodeIn(
        _ pack: GraphV2Pack, _ i: Int,
        _ minLon: Double, _ minLat: Double, _ maxLon: Double, _ maxLat: Double
    ) -> Bool {
        guard let c = nodeCoord(pack, i) else { return false }
        return c.longitude >= minLon && c.longitude <= maxLon
            && c.latitude >= minLat && c.latitude <= maxLat
    }

    private static func nodeCoord(_ pack: GraphV2Pack, _ i: Int) -> CLLocationCoordinate2D? {
        guard i >= 0, i < pack.nodeCount else { return nil }
        return CLLocationCoordinate2D(
            latitude: Double(pack.nodeCoords[i * 2 + 1]),
            longitude: Double(pack.nodeCoords[i * 2])
        )
    }
}
