import Foundation

/// Orders work only. Actual native initial approaches establish usable routes;
/// conservative completed bounds establish when no remaining station can win.
@MainActor
enum InitialFuelNearestSelection {
    struct Route<Value> { let value: Value; let meters: Double }
    struct Winner<Value> { let station: POIFeature; let route: Route<Value>; let attempts: Int }
    enum Failure: Error { case incompleteProof, invalidActualDistance }

    static func choose<Value>(candidates: [POIFeature], rangeMeters: Double,
        requiredStationID: String?,
        attempt: (POIFeature, Double) async throws -> Route<Value>?,
        lowerBounds: ([POIFeature], Double) async throws -> [String: Double]?) async throws -> Winner<Value>? {
        let eligible = requiredStationID.map { required in candidates.filter { $0.id == required } } ?? candidates
        var attempts = 0
        var winner: Winner<Value>?
        var next = 0
        while next < eligible.count, winner == nil {
            try RoutingWorkContext.check()
            let station = eligible[next]; next += 1; attempts += 1
            if let route = try await attempt(station, rangeMeters) {
                try RoutingWorkContext.check()
                guard route.meters.isFinite, route.meters >= 0, route.meters <= rangeMeters else {
                    throw Failure.invalidActualDistance
                }
                winner = .init(station: station, route: route, attempts: attempts)
            }
        }
        guard var best = winner else { return nil }
        // An explicit station override asks for a legal approach to that pump,
        // not a claim that this rider-selected pump is the closest station.
        if requiredStationID != nil || next == eligible.count { return best }
        let remaining = Array(eligible[next...])
        guard let bounds = try await lowerBounds(remaining, best.route.meters) else {
            throw Failure.incompleteProof
        }
        try RoutingWorkContext.check()
        let ordered = remaining.sorted {
            let a = bounds[$0.id] ?? 0, b = bounds[$1.id] ?? 0
            return a == b ? $0.id < $1.id : a < b
        }
        for station in ordered {
            try RoutingWorkContext.check()
            let lower = bounds[station.id] ?? 0
            guard !lower.isNaN, lower >= 0 else { throw Failure.incompleteProof }
            if lower > best.route.meters || (lower == best.route.meters && station.id >= best.station.id) { continue }
            attempts += 1
            guard let route = try await attempt(station, rangeMeters) else { continue }
            try RoutingWorkContext.check()
            guard route.meters.isFinite, route.meters >= 0, route.meters <= rangeMeters else {
                throw Failure.invalidActualDistance
            }
            if route.meters < best.route.meters || (route.meters == best.route.meters && station.id < best.station.id) {
                best = .init(station: station, route: route, attempts: attempts)
            }
        }
        try RoutingWorkContext.check()
        return .init(station: best.station, route: best.route, attempts: attempts)
    }
}
