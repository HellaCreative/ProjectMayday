import CoreLocation
import Foundation

/// Selects build-proven OSM seam anchors embedded in `graph.v2.bin`.
/// The pack builder—not the phone—proves that both regions contain the same
/// OSM way and exact vertex. Runtime only ranks those real crossings by the
/// rider's A→B alignment.
enum CrossPackSeam {
    static func candidates(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        anchors: [GraphV2Pack.CrossPackSeamAnchor],
        urbanCores: [UrbanCore.Box]
    ) -> [GraphV2Pack.CrossPackSeamAnchor] {
        anchors
            .filter { $0.gapMeters <= 2 && !$0.osmWayId.isEmpty }
            .filter {
                !UrbanCore.isNear(
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                    boxes: urbanCores
                )
            }
            .sorted {
                distanceToChord($0, from: from, to: to)
                    < distanceToChord($1, from: from, to: to)
            }
    }

    private static func distanceToChord(
        _ anchor: GraphV2Pack.CrossPackSeamAnchor,
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) -> Double {
        let midLat = (from.latitude + to.latitude + anchor.latitude) / 3 * .pi / 180
        let scaleX = cos(midLat)
        let ax = from.longitude * scaleX
        let ay = from.latitude
        let bx = to.longitude * scaleX
        let by = to.latitude
        let px = anchor.longitude * scaleX
        let py = anchor.latitude
        let dx = bx - ax
        let dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared > 0 ? max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / lengthSquared)) : 0
        return hypot(px - (ax + t * dx), py - (ay + t * dy))
    }
}

extension OnDeviceRouter.Result {
    static func concatenating(_ hops: [OnDeviceRouter.Result]) -> OnDeviceRouter.Result? {
        guard let first = hops.first else { return nil }
        if hops.count == 1 { return first }

        var coords = first.coordinates
        var legs = first.legs
        var edgeIds = first.edgeIds
        for hop in hops.dropFirst() {
            if coords.last != nil, let hopFirst = hop.coordinates.first {
                let rest = hop.coordinates.dropFirst()
                let skipDuplicate = CLLocation(latitude: coords[coords.count - 1].latitude, longitude: coords[coords.count - 1].longitude)
                    .distance(from: CLLocation(latitude: hopFirst.latitude, longitude: hopFirst.longitude)) < 8
                if !skipDuplicate {
                    coords.append(hopFirst)
                }
                coords.append(contentsOf: rest)
            } else {
                coords.append(contentsOf: hop.coordinates)
            }
            legs.append(contentsOf: hop.legs)
            edgeIds.append(contentsOf: hop.edgeIds)
        }

        var meters = 0.0
        var dirtMeters = 0.0
        var pavedMeters = 0.0
        var unknownMeters = 0.0
        for leg in legs {
            meters += leg.distanceMeters
            if leg.paintSurfaceName == "paved" {
                pavedMeters += leg.distanceMeters
            } else if OnDeviceProfileCosts.isAdventureSurface(leg.paintSurfaceName) {
                dirtMeters += leg.distanceMeters
            }
            if leg.accessName == "motorized_unknown" {
                unknownMeters += leg.distanceMeters
            }
        }
        guard meters > 0, coords.count >= 2 else { return nil }
        let coarseDirt = Int((dirtMeters / meters * 100).rounded())
        let coarsePaved = Int((pavedMeters / meters * 100).rounded())
        let hasLeaves = legs.contains { $0.surfaceLeaf != nil }
        let reported: SurfaceFamilyStats.Percents
        if hasLeaves {
            let leafLegs = legs.filter {
                !$0.edgeId.hasPrefix("soft-stitch-") &&
                !$0.edgeId.hasPrefix("perm-stitch-") &&
                $0.structureType != "ferry"
            }
            let leafMeters = leafLegs.reduce(0.0) { $0 + $1.distanceMeters }
            reported = SurfaceFamilyStats.honestPercents(
                rows: leafLegs.map { ($0.distanceMeters, $0.surfaceLeaf) },
                distanceMeters: leafMeters
            )
        } else {
            reported = SurfaceFamilyStats.Percents(
                dirtPercent: coarseDirt,
                pavedPercent: coarsePaved,
                gravelPercent: 0,
                unknownSurfacePercent: 0
            )
        }
        return OnDeviceRouter.Result(
            coordinates: coords,
            distanceMeters: meters,
            edgeIds: edgeIds,
            legs: legs,
            dirtPercent: coarseDirt,
            pavedPercent: coarsePaved,
            unknownAccessPercent: Int((unknownMeters / meters * 100).rounded()),
            reportedDirtPercent: reported.dirtPercent,
            reportedPavedPercent: reported.pavedPercent,
            unknownSurfacePercent: reported.unknownSurfacePercent,
            searchMeta: OnDeviceRouter.SearchMeta(
                urbanCoreFallbackUsed: hops.contains { $0.searchMeta.urbanCoreFallbackUsed },
                cleanUnpavedFallbackUsed: hops.contains { $0.searchMeta.cleanUnpavedFallbackUsed },
                settlementFallbackUsed: hops.contains { $0.searchMeta.settlementFallbackUsed }
            )
        )
    }
}
