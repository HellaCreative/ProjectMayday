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
        return RouteResponse(
            status: response.status,
            error: response.error,
            message: response.message,
            distanceMeters: meters,
            estimatedMovingSeconds: response.estimatedMovingSeconds.map { $0 * fraction },
            estimatedElapsedSeconds: response.estimatedElapsedSeconds.map { $0 * fraction },
            geometry: geometry,
            segments: nil,
            stats: RouteStats(
                dirtPercent: response.stats?.dirtPercent ?? response.dirtPercentValue,
                pavedPercent: response.stats?.pavedPercent ?? response.pavedPercentValue,
                unknownAccessPercent: response.stats?.unknownAccessPercent,
                unknownSurfacePercent: response.stats?.unknownSurfacePercent,
                surfaceFamilyMode: response.stats?.surfaceFamilyMode
            ),
            maneuvers: nil,
            warnings: response.warnings,
            dirtPercentValue: response.dirtPercentValue,
            pavedPercentValue: response.pavedPercentValue,
            backtrackMeters: response.backtrackMeters.map { $0 * fraction },
            backtrackPct: response.backtrackPct,
            arrivalEdgeId: claimedTo >= total - 1 ? response.arrivalEdgeId : nil,
            arrivalRestrictions: claimedTo >= total - 1 ? response.arrivalRestrictions : nil
        )
    }

}
