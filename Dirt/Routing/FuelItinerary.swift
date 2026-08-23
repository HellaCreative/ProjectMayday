import CoreLocation
import Foundation

/// Progress-directed fuel stop pick — Layer 1 of itinerary planning.
/// Graph reachability is supplied by the caller (pack Dijkstra). This type
/// only chooses among pumps already proven reachable on the hop.
nonisolated enum FuelItinerary {
    /// Remaining portion of an already-selected ride near the current pump.
    /// This lets live fuel planning reuse one route shape instead of asking the
    /// server for another unconstrained current→B adventure route at every
    /// recursion depth.
    static func routeSuffix(
        from current: RouteCoordinate,
        routeCoordinates: [RouteCoordinate],
        maximumOffRouteMeters: Double = 50_000
    ) -> [RouteCoordinate] {
        guard routeCoordinates.count > 1 else { return [] }
        let cumulative = GeoMath.cumulativeMeters(routeCoordinates)
        let location = CLLocation(latitude: current.latitude, longitude: current.longitude)
        guard let projection = GeoMath.nearestProjection(
            to: location,
            in: routeCoordinates,
            cumulative: cumulative
        ), projection.offMeters <= maximumOffRouteMeters else { return [] }
        let nextVertex = min(routeCoordinates.count - 1, projection.segmentIndex + 1)
        return [current] + Array(routeCoordinates[nextVertex...])
    }

    /// Preserve stations that sit on the selected ride first, then append
    /// forward-progress fallbacks. A bad or disconnected corridor pump must
    /// never erase the next usable town from the search.
    static func mergedCandidateOrder(
        primary: [POIFeature],
        fallback: [POIFeature]
    ) -> [POIFeature] {
        var seen = Set<String>()
        var result: [POIFeature] = []
        result.reserveCapacity(primary.count + fallback.count)
        for fuel in primary + fallback where seen.insert(fuel.id).inserted {
            result.append(fuel)
        }
        return result
    }

    /// Candidate ordering for live planning when no road pack is installed.
    /// Crow-flies distance is only a conservative prefilter/order hint; callers
    /// must verify every returned leg with the live graph before accepting it.
    static func approximateReachableMeters(
        fuels: [POIFeature],
        from: RouteCoordinate,
        tankMeters: Double,
        excluding: Set<String> = []
    ) -> [String: Double] {
        guard tankMeters > 0 else { return [:] }
        var result: [String: Double] = [:]
        result.reserveCapacity(fuels.count)
        for fuel in fuels where !excluding.contains(fuel.id) {
            let at = RouteCoordinate(longitude: fuel.longitude, latitude: fuel.latitude)
            let airMeters = GeoMath.meters(from, at)
            // A road leg cannot be shorter than its endpoints' geodesic distance.
            // Excluding anything outside one tank is therefore safe.
            if airMeters > 8_000, airMeters <= tankMeters {
                result[fuel.id] = airMeters
            }
        }
        return result
    }

    /// Rank live-routing candidates by their position along a graph-produced
    /// route corridor. This is only candidate discovery: every leg still has
    /// to be routed and proven within tank range before it is accepted.
    static func rankedRouteCorridorFuel(
        fuels: [POIFeature],
        from: RouteCoordinate,
        routeCoordinates: [RouteCoordinate],
        tankMeters: Double,
        sessionSeed: UInt64,
        excluding: Set<String> = []
    ) -> [POIFeature] {
        guard tankMeters > 0, routeCoordinates.count > 1 else { return [] }
        let cumulative = GeoMath.cumulativeMeters(routeCoordinates)
        guard let routeMeters = cumulative.last, routeMeters > 13_000 else { return [] }
        let farthestAlong = min(tankMeters, routeMeters - 5_000)
        let preferredAlong = min(
            tankMeters * HopSearchPolicy.fuelPreferTank,
            farthestAlong
        )

        struct Candidate {
            var fuel: POIFeature
            var alongMeters: Double
            var offMeters: Double
            var airMeters: Double
        }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(fuels.count)
        for fuel in fuels where !excluding.contains(fuel.id) {
            let point = RouteCoordinate(longitude: fuel.longitude, latitude: fuel.latitude)
            let airMeters = GeoMath.meters(from, point)
            // Safe lower bound: a road route cannot beat geodesic distance.
            guard airMeters > 8_000, airMeters <= tankMeters else { continue }
            let location = CLLocation(latitude: fuel.latitude, longitude: fuel.longitude)
            guard let projection = GeoMath.nearestProjection(
                to: location,
                in: routeCoordinates,
                cumulative: cumulative
            ),
                  projection.alongMeters > 8_000,
                  projection.alongMeters < farthestAlong,
                  projection.offMeters <= 50_000
            else { continue }
            candidates.append(
                Candidate(
                    fuel: fuel,
                    alongMeters: projection.alongMeters,
                    offMeters: projection.offMeters,
                    airMeters: airMeters
                )
            )
        }

        return candidates.sorted { a, b in
            let aInBand = a.alongMeters >= tankMeters * HopSearchPolicy.fuelMinTank
            let bInBand = b.alongMeters >= tankMeters * HopSearchPolicy.fuelMinTank
            if aInBand != bInBand { return aInBand }
            let aScore = abs(a.alongMeters - preferredAlong) + a.offMeters * 2
            let bScore = abs(b.alongMeters - preferredAlong) + b.offMeters * 2
            if abs(aScore - bScore) > 1_000 { return aScore < bScore }
            if abs(a.alongMeters - b.alongMeters) > 1_000 {
                return a.alongMeters > b.alongMeters
            }
            let ha = HopSearchPolicy.hash(
                sessionSeed, Int(a.alongMeters), Int(a.airMeters)
            )
            let hb = HopSearchPolicy.hash(
                sessionSeed, Int(b.alongMeters), Int(b.airMeters)
            )
            return ha < hb
        }.map(\.fuel)
    }

    /// Among pumps reached within tank range, pick the one that makes the most
    /// progress toward B (not nearest-to-a-line, not crow-flies nearest).
    static func pickProgressFuel(
        fuels: [POIFeature],
        from: RouteCoordinate,
        to: RouteCoordinate,
        reachableMeters: [String: Double],
        tankMeters: Double,
        sessionSeed: UInt64,
        excluding: Set<String> = []
    ) -> POIFeature? {
        rankedProgressFuel(
            fuels: fuels, from: from, to: to, reachableMeters: reachableMeters,
            tankMeters: tankMeters, sessionSeed: sessionSeed, excluding: excluding
        ).first
    }

    /// Ranked pumps toward B. Tank-band first, then more progress, then seed.
    static func rankedProgressFuel(
        fuels: [POIFeature],
        from: RouteCoordinate,
        to: RouteCoordinate,
        reachableMeters: [String: Double],
        tankMeters: Double,
        sessionSeed: UInt64,
        excluding: Set<String> = []
    ) -> [POIFeature] {
        guard tankMeters > 0, !fuels.isEmpty else { return [] }
        let ab = GeoMath.meters(from, to)
        guard ab > 8_000 else { return [] }

        struct Cand {
            var fuel: POIFeature
            var graphMeters: Double
            var progress: Double
            var crossTrack: Double
            var coherent: Bool
        }
        var cands: [Cand] = []
        cands.reserveCapacity(fuels.count)
        for fuel in fuels {
            if excluding.contains(fuel.id) { continue }
            guard let graph = reachableMeters[fuel.id], graph.isFinite, graph > 8_000 else { continue }
            guard graph <= tankMeters * HopSearchPolicy.fuelMaxTank else { continue }
            let at = RouteCoordinate(longitude: fuel.longitude, latitude: fuel.latitude)
            let progress = GeoMath.progressAlongAB(from: from, to: to, point: at)
            // Graph reachability is the route corridor. A straight A→B cross-track
            // gate rejects legitimate mountain/highway detours and can erase the
            // only usable fuel chain. Require real progress toward B instead.
            guard progress > 8_000, progress < ab - 5_000 else { continue }
            let crossTrack = abs(GeoMath.crossTrackMeters(
                point: at.locationCoordinate,
                lineFrom: from.locationCoordinate,
                to: to.locationCoordinate
            ))
            let coherent = !(
                (crossTrack > 50_000 && crossTrack > progress * 0.75 && progress < ab * 0.75)
                    || (progress < max(10_000, ab * 0.18) && crossTrack > 25_000)
            )
            cands.append(Cand(
                fuel: fuel,
                graphMeters: graph,
                progress: progress,
                crossTrack: crossTrack,
                coherent: coherent
            ))
        }
        guard !cands.isEmpty else { return [] }

        let prefer = tankMeters * HopSearchPolicy.fuelPreferTank
        return cands.sorted { a, b in
            // Preserve an off-axis pump as a last-resort connectivity fallback,
            // but never rank it above a route-coherent forward pump.
            if a.coherent != b.coherent { return a.coherent }
            let aInBand = a.graphMeters >= tankMeters * HopSearchPolicy.fuelMinTank
                && a.graphMeters <= tankMeters * HopSearchPolicy.fuelMaxTank
            let bInBand = b.graphMeters >= tankMeters * HopSearchPolicy.fuelMinTank
                && b.graphMeters <= tankMeters * HopSearchPolicy.fuelMaxTank
            if aInBand != bInBand { return aInBand }
            if abs(a.progress - b.progress) > 2_000 { return a.progress > b.progress }
            let da = abs(a.graphMeters - prefer)
            let db = abs(b.graphMeters - prefer)
            if abs(da - db) > 1 { return da < db }
            let ha = HopSearchPolicy.hash(sessionSeed, Int(a.progress), Int(a.graphMeters))
            let hb = HopSearchPolicy.hash(sessionSeed, Int(b.progress), Int(b.graphMeters))
            if ha != hb { return ha < hb }
            return a.progress > b.progress
        }.map(\.fuel)
    }
}
