import CoreLocation
import Foundation

/// Progress-directed fuel stop pick — Layer 1 of itinerary planning.
/// Graph reachability is supplied by the caller (pack Dijkstra). This type
/// only chooses among pumps already proven reachable on the hop.
nonisolated enum FuelItinerary {
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
        }
        var cands: [Cand] = []
        cands.reserveCapacity(fuels.count)
        for fuel in fuels {
            if excluding.contains(fuel.id) { continue }
            guard let graph = reachableMeters[fuel.id], graph.isFinite, graph > 8_000 else { continue }
            guard graph <= tankMeters * HopSearchPolicy.fuelMaxTank else { continue }
            let at = RouteCoordinate(longitude: fuel.longitude, latitude: fuel.latitude)
            let progress = GeoMath.progressAlongAB(from: from, to: to, point: at)
            // Generally toward B — reject backward / sideways grabs.
            guard progress > 8_000, progress < ab - 5_000 else { continue }
            let xt = abs(GeoMath.crossTrackMeters(
                point: CLLocationCoordinate2D(latitude: at.latitude, longitude: at.longitude),
                lineFrom: CLLocationCoordinate2D(latitude: from.latitude, longitude: from.longitude),
                to: CLLocationCoordinate2D(latitude: to.latitude, longitude: to.longitude)
            ))
            guard xt < 40_000 || xt < progress * 0.35 else { continue }
            cands.append(Cand(fuel: fuel, graphMeters: graph, progress: progress))
        }
        guard !cands.isEmpty else { return [] }

        let prefer = tankMeters * HopSearchPolicy.fuelPreferTank
        let band = cands.filter {
            $0.graphMeters >= tankMeters * HopSearchPolicy.fuelMinTank
                && $0.graphMeters <= tankMeters * HopSearchPolicy.fuelMaxTank
        }
        let pool = band.isEmpty ? cands : band
        return pool.sorted { a, b in
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
