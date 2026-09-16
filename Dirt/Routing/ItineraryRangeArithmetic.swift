import Foundation

nonisolated enum ItineraryRangeArithmetic {
    static let fuelWaypointSnapMeters = 150.0
    static func comfortCapMeters(
        firstLegMaxMeters: Double,
        usableRangeMeters: Double
    ) -> Double {
        guard usableRangeMeters > 0, firstLegMaxMeters >= 0 else { return 0 }
        return min(firstLegMaxMeters, usableRangeMeters)
    }

    static func fuelStopCountNeeded(
        profileMeters: Double,
        firstLegMaxMeters: Double,
        usableRangeMeters: Double
    ) -> Int {
        guard profileMeters.isFinite, profileMeters >= 0, usableRangeMeters > 0 else { return 0 }
        let firstCap = min(firstLegMaxMeters, usableRangeMeters)
        if profileMeters > firstCap + 1 {
            return Int(ceil((profileMeters - firstCap) / usableRangeMeters))
        }
        // Crossing the watch or preferred zone never manufactures a stop. A
        // reachable destination wins unless its destination-escape requirement
        // proves that a prior refuel is necessary.
        return 0
    }

    /// §5 rule 7: a routed span longer than 400 km is broken at about 375 km.
    static let distanceBreakMinimumMeters = 350_000.0
    static let distanceBreakMaximumMeters = 400_000.0
    static let distanceBreakTargetMeters = 375_000.0
}

@MainActor
extension ItineraryRangeArithmetic {
    static func distanceBreakChunks(_ response: RouteResponse) -> [(response: RouteResponse, endsAtDistanceBreak: Bool)] {
        let total = response.distanceMeters ?? GeoMath.lineMeters(response.coordinates)
        guard total.isFinite, total > distanceBreakMaximumMeters else {
            return [(response, false)]
        }
        var chunks: [(RouteResponse, Bool)] = []
        var cursor = 0.0
        while total - cursor > distanceBreakMaximumMeters {
            let cut = cursor + distanceBreakTargetMeters
            chunks.append((slice(response, claimedFrom: cursor, claimedTo: cut, total: total), true))
            cursor = cut
        }
        chunks.append((slice(response, claimedFrom: cursor, claimedTo: total, total: total), false))
        return chunks
    }

    private static func slice(
        _ response: RouteResponse,
        claimedFrom: Double,
        claimedTo: Double,
        total: Double
    ) -> RouteResponse {
        let coords = response.coordinates
        let geometry: [RouteCoordinate]
        if coords.count >= 2, total > 1 {
            let cumulative = GeoMath.cumulativeMeters(coords)
            let geoTotal = max(cumulative.last ?? 0, 1)
            let scale = total / geoTotal
            func point(at claimed: Double) -> RouteCoordinate {
                let geoAt = claimed / scale
                for index in 1..<coords.count {
                    if cumulative[index] + 0.01 >= geoAt {
                        let span = cumulative[index] - cumulative[index - 1]
                        let fraction = span > 0 ? (geoAt - cumulative[index - 1]) / span : 1
                        return GeoMath.interpolate(coords[index - 1], coords[index], fraction: fraction)
                    }
                }
                return coords.last ?? coords[0]
            }
            var points: [RouteCoordinate] = [point(at: claimedFrom)]
            for index in 1..<coords.count where cumulative[index] > claimedFrom / scale + 1
                && cumulative[index] < claimedTo / scale - 1 {
                points.append(coords[index])
            }
            points.append(point(at: claimedTo))
            geometry = points
        } else {
            geometry = coords
        }
        let meters = max(0, claimedTo - claimedFrom)
        let fraction = total > 0 ? meters / total : 1
        let segments = sliceSegments(
            response.segments,
            claimedFrom: claimedFrom,
            claimedTo: claimedTo,
            claimedTotal: total,
            chunkMeters: meters
        )
        let usesLeaves = response.stats?.surfaceFamilyMode == "leaf-v3"
        let stats = stats(for: segments, parent: response, usesLeaves: usesLeaves)
        return RouteResponse(
            status: response.status,
            error: response.error,
            message: response.message,
            distanceMeters: meters,
            estimatedMovingSeconds: response.estimatedMovingSeconds.map { $0 * fraction },
            estimatedElapsedSeconds: response.estimatedElapsedSeconds.map { $0 * fraction },
            geometry: geometry,
            segments: segments,
            stats: stats,
            maneuvers: nil,
            warnings: response.warnings,
            dirtPercentValue: stats.dirtPercent,
            pavedPercentValue: stats.pavedPercent,
            backtrackMeters: response.backtrackMeters.map { $0 * fraction },
            backtrackPct: response.backtrackPct,
            arrivalEdgeId: claimedTo >= total - 1 ? response.arrivalEdgeId : nil,
            arrivalRestrictions: claimedTo >= total - 1 ? response.arrivalRestrictions : nil
        )
    }

    private static func sliceSegments(
        _ segments: [RouteSegment]?,
        claimedFrom: Double,
        claimedTo: Double,
        claimedTotal: Double,
        chunkMeters: Double
    ) -> [RouteSegment]? {
        guard let segments, !segments.isEmpty else { return nil }
        let spans = segments.map { $0.distanceMeters ?? GeoMath.lineMeters($0.coordinates) }
        let rawTotal = spans.reduce(0, +)
        guard rawTotal > 0, claimedTotal > 0 else { return nil }
        let scale = claimedTotal / rawTotal
        var cursor = 0.0
        var sliced: [RouteSegment] = []
        for (index, segment) in segments.enumerated() {
            let claimedSpan = spans[index] * scale
            let segmentFrom = cursor
            let segmentTo = cursor + claimedSpan
            cursor = segmentTo
            let overlapFrom = max(segmentFrom, claimedFrom)
            let overlapTo = min(segmentTo, claimedTo)
            let overlap = overlapTo - overlapFrom
            guard overlap > 0.5 else { continue }
            let localFrom = claimedSpan > 0 ? (overlapFrom - segmentFrom) / claimedSpan : 0
            let localTo = claimedSpan > 0 ? (overlapTo - segmentFrom) / claimedSpan : 1
            sliced.append(
                copy(
                    segment,
                    distanceMeters: overlap,
                    geometry: sliceGeometry(segment.coordinates, fromFraction: localFrom, toFraction: localTo)
                )
            )
        }
        guard !sliced.isEmpty else { return nil }
        let sum = sliced.compactMap(\.distanceMeters).reduce(0, +)
        let delta = chunkMeters - sum
        if abs(delta) > 0.01, let last = sliced.last {
            sliced[sliced.count - 1] = copy(
                last,
                distanceMeters: max(0, (last.distanceMeters ?? 0) + delta),
                geometry: last.coordinates
            )
        }
        return sliced
    }

    private static func sliceGeometry(
        _ coords: [RouteCoordinate],
        fromFraction: Double,
        toFraction: Double
    ) -> [RouteCoordinate] {
        guard coords.count >= 2 else { return coords }
        let start = min(1, max(0, fromFraction))
        let end = min(1, max(start, toFraction))
        let cumulative = GeoMath.cumulativeMeters(coords)
        let geoTotal = max(cumulative.last ?? 0, 1)
        func point(at fraction: Double) -> RouteCoordinate {
            let geoAt = fraction * geoTotal
            for index in 1..<coords.count {
                if cumulative[index] + 0.01 >= geoAt {
                    let span = cumulative[index] - cumulative[index - 1]
                    let local = span > 0 ? (geoAt - cumulative[index - 1]) / span : 1
                    return GeoMath.interpolate(coords[index - 1], coords[index], fraction: local)
                }
            }
            return coords.last ?? coords[0]
        }
        var points: [RouteCoordinate] = [point(at: start)]
        for index in 1..<coords.count where cumulative[index] > start * geoTotal + 1
            && cumulative[index] < end * geoTotal - 1 {
            points.append(coords[index])
        }
        points.append(point(at: end))
        return points
    }

    private static func copy(
        _ segment: RouteSegment,
        distanceMeters: Double,
        geometry: [RouteCoordinate]
    ) -> RouteSegment {
        RouteSegment(
            surfaceClass: segment.surfaceClass,
            trackClass: segment.trackClass,
            accessClass: segment.accessClass,
            distanceMeters: distanceMeters,
            geometry: geometry.isEmpty ? segment.coordinates : geometry,
            coords: nil,
            edgeId: segment.edgeId,
            structureType: segment.structureType,
            structureLeaf: segment.structureLeaf,
            layer: segment.layer,
            crossingLabel: segment.crossingLabel,
            waterCrossing: segment.waterCrossing,
            surfaceLeaf: segment.surfaceLeaf
        )
    }

    private static func stats(
        for segments: [RouteSegment]?,
        parent: RouteResponse,
        usesLeaves: Bool
    ) -> RouteStats {
        guard let segments, !segments.isEmpty else {
            return RouteStats(
                dirtPercent: parent.stats?.dirtPercent ?? parent.dirtPercentValue,
                pavedPercent: parent.stats?.pavedPercent ?? parent.pavedPercentValue,
                unknownAccessPercent: parent.stats?.unknownAccessPercent,
                unknownSurfacePercent: parent.stats?.unknownSurfacePercent,
                surfaceFamilyMode: parent.stats?.surfaceFamilyMode
            )
        }
        var mix = RouteSurfaceComposition()
        var unknownAccess = 0.0
        var counted = 0.0
        for segment in segments {
            let meters = segment.distanceMeters ?? GeoMath.lineMeters(segment.coordinates)
            guard meters.isFinite, meters > 0 else { continue }
            if segment.structureType != "ferry" {
                mix.add(
                    meters: meters,
                    family: segment.presentationSurfaceFamily(usesSurfaceLeaves: usesLeaves)
                )
                counted += meters
                if segment.accessClass?.lowercased() == "motorized_unknown" {
                    unknownAccess += meters
                }
            }
        }
        return RouteStats(
            dirtPercent: mix.dirtPercent,
            pavedPercent: mix.pavedPercent,
            unknownAccessPercent: counted > 0 ? Int((unknownAccess / counted * 100).rounded()) : parent.stats?.unknownAccessPercent,
            unknownSurfacePercent: mix.unknownPercent,
            surfaceFamilyMode: parent.stats?.surfaceFamilyMode
        )
    }

}
