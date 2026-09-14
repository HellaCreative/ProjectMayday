import Foundation

@MainActor
enum FuelExitAlternative {
    enum Assessment {
        case accepted(OnDeviceRouter.Result)
        case unproved(String)
    }
    struct SourceBoundResult {
        let result: Result<OnDeviceRouter.Result, OnDeviceRouter.Failure>
        let sourceIdentity: String?
    }
    static func calculateBoundExit(expectedIdentity: String,
        currentIdentity: () -> String,
        calculate: () async -> Result<OnDeviceRouter.Result, OnDeviceRouter.Failure>
    ) async -> SourceBoundResult {
        let captured = currentIdentity()
        guard captured == expectedIdentity else {
            return .init(result: .failure(.searchLimit("fuelExitSourceChanged")), sourceIdentity: nil)
        }
        let result = await calculate()
        guard currentIdentity() == captured else {
            return .init(result: .failure(.searchLimit("fuelExitSourceChanged")), sourceIdentity: nil)
        }
        return .init(result: result, sourceIdentity: captured)
    }
    static func sameMatchedEndpoints(_ first: OnDeviceRouter.Result, _ alternate: OnDeviceRouter.Result) -> Bool {
        guard let start = first.matchedStart, let end = first.matchedEnd else { return false }
        return alternate.matchedStart == start && alternate.matchedEnd == end
    }
    static func targetedExclusions(approach: OnDeviceRouter.Result, exit: OnDeviceRouter.Result,
        history: Set<String>, original: Set<String>) -> Set<String>? {
        let roads = exit.legs.filter { $0.edgeIndex != nil && !$0.edgeId.isEmpty }
        var protected: Set<String> = []
        if let edge = roads.first?.edgeId { protected.insert(edge) }
        if let edge = roads.last?.edgeId { protected.insert(edge) }
        if let edge = approach.legs.last(where: { $0.edgeIndex != nil })?.edgeId { protected.insert(edge) }
        let repeats = Set(roads.map(\.edgeId)).intersection(history).subtracting(protected).subtracting(original)
        return repeats.isEmpty ? nil : original.union(repeats)
    }
    static func assess(initial: Result<OnDeviceRouter.Result, OnDeviceRouter.Failure>,
        approach: OnDeviceRouter.Result, history: Set<String>, originalAvoid: Set<String>,
        cap: Double, maximumRepeatedMeters: Double,
        repeatedMeters: (OnDeviceRouter.Result) -> Double,
        alternate: (Set<String>) async -> Result<OnDeviceRouter.Result, OnDeviceRouter.Failure>
    ) async throws -> Assessment {
        try RoutingWorkContext.check()
        guard case .success(let first) = initial else {
            if case .failure(.searchLimit(let reason)) = initial { return .unproved(reason) }
            return .unproved("station_exit_unproved")
        }
        if first.distanceMeters <= cap + 1, repeatedMeters(first) <= maximumRepeatedMeters { return .accepted(first) }
        var current = first
        var exclusions = originalAvoid
        var attempts = 0
        while true {
            try RoutingWorkContext.check()
            guard current.distanceMeters <= cap + 1 else { return .unproved("station_exit_cap_unproved") }
            guard let expanded = targetedExclusions(approach: approach, exit: current,
                history: history, original: exclusions) else {
                return .unproved("station_exit_no_novel_exclusions")
            }
            // Every retry must exclude newly observed repeated through-roads.
            // The finite history and unchanged work deadline bound this loop;
            // no successful progress or new query resets the current window.
            exclusions = expanded
            attempts += 1
            let retried = await alternate(exclusions)
            try RoutingWorkContext.check()
            switch retried {
            case .success(let route):
                let repeated = repeatedMeters(route)
                let sameAnchors = sameMatchedEndpoints(first, route)
                RoutingDebugLog.shared.event("fuel exit alternative attempt=\(attempts) result=route meters=\(route.distanceMeters) "
                    + "repeated=\(repeated) cap=\(cap) sameAnchors=\(sameAnchors) exclusions=\(exclusions.count)")
                guard sameAnchors else { return .unproved("station_exit_matching_changed") }
                guard route.distanceMeters <= cap + 1 else { return .unproved("station_exit_cap_unproved") }
                if repeated <= maximumRepeatedMeters { return .accepted(route) }
                current = route
            case .failure(let reason):
                RoutingDebugLog.shared.event("fuel exit alternative attempt=\(attempts) result=failure cause=\(reason) exclusions=\(exclusions.count)")
                if case .searchLimit(let detail) = reason { return .unproved(detail) }
                return .unproved("station_exit_alternative_unproved")
            }
        }

    }
}

@MainActor
final class FuelExitReuseHolder {
    var saved: FuelExitReuseRecord?
    func take(request: FuelChainRequest, from: RouteCoordinate, to: RouteCoordinate,
        arrival: NativeRoutingContinuation?, history: Set<String>, sourceIdentity: String,
        cap: Double) throws -> OnDeviceRouter.Result? {
        let previous = saved
        saved = nil
        guard let previous else { return nil }
        if let reason = try previous.rejection(request: request, from: from, to: to,
            arrival: arrival, history: history, sourceIdentity: sourceIdentity, cap: cap) {
            RoutingDebugLog.shared.event("fuel exit reuse rejected reason=\(reason.rawValue)")
            return nil
        }
        RoutingDebugLog.shared.event("fuel exit reuse accepted meters=\(previous.route.distanceMeters)")
        return previous.route
    }
}
nonisolated enum FuelExitReuseScope {
    @TaskLocal static var current: FuelExitReuseHolder?
}

/// A single build-owned selected continuation, never a persistent route cache.
@MainActor
struct FuelExitReuseRecord {
    let from: RouteCoordinate
    let to: RouteCoordinate
    let arrival: NativeRoutingContinuation
    let history: Set<String>
    let sourceIdentity: String
    let settings: Data
    let route: OnDeviceRouter.Result

    init?(request: FuelChainRequest, from: RouteCoordinate, to: RouteCoordinate,
        arrival: NativeRoutingContinuation?, history: Set<String>, sourceIdentity: String,
        route: OnDeviceRouter.Result) throws {
        guard let arrival, !sourceIdentity.isEmpty else { return nil }
        self.from = from; self.to = to; self.arrival = arrival; self.history = history
        self.sourceIdentity = sourceIdentity; self.route = route
        self.settings = try Self.signature(request)
    }
    func matching(request: FuelChainRequest, from: RouteCoordinate, to: RouteCoordinate,
        arrival: NativeRoutingContinuation?, history: Set<String>, sourceIdentity: String,
        cap: Double) throws -> OnDeviceRouter.Result? {
        if try rejection(request: request, from: from, to: to, arrival: arrival,
            history: history, sourceIdentity: sourceIdentity, cap: cap) != nil { return nil }
        return route
    }

    enum Rejection: String {
        case origin, destination, arrival, sourceIdentity, additionalRoadHistory, settings, rangeCap
    }

    func rejection(request: FuelChainRequest, from: RouteCoordinate, to: RouteCoordinate,
        arrival: NativeRoutingContinuation?, history: Set<String>, sourceIdentity: String,
        cap: Double) throws -> Rejection? {
        try RoutingWorkContext.check()
        if self.from != from { return .origin }
        if self.to != to { return .destination }
        if self.arrival != arrival { return .arrival }
        if self.sourceIdentity != sourceIdentity { return .sourceIdentity }
        // Native Result.edgeIds excludes these presentation/access stubs, whereas
        // RouteResponse segments (and builder history) retain them. They are not
        // graph road identities and cannot make a previously unseen legal road.
        // Keep their geometry/meters and all downstream overlap checks unchanged.
        let roadHistory = history.filter {
            !$0.hasPrefix("soft-stitch-") && !$0.hasPrefix("perm-stitch-")
        }
        if !roadHistory.isSubset(of: self.history) { return .additionalRoadHistory }
        if self.settings != (try Self.signature(request)) { return .settings }
        if !(route.distanceMeters <= cap + 1) { return .rangeCap }
        return nil
    }
    private static func signature(_ request: FuelChainRequest) throws -> Data {
        var options = request.options ?? RouteRequestOptions()
        options.priorEdgeIds = nil; options.arrivalEdgeId = nil; options.arrivalContinuation = nil
        options.startEndpointKind = "customers"; options.endEndpointKind = nil
        options.maxPathMeters = nil
        options.avoidEdgeIds = Array(Set(options.avoidEdgeIds ?? [])).sorted()
        struct Settings: Encodable {
            let riderLegID: String; let profile: RouteProfile; let vehicle: String
            let access: AccessPolicy; let options: RouteRequestOptions
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Settings(riderLegID: request.fuel.riderLegId,
            profile: request.profile, vehicle: request.vehicle, access: request.accessPolicy, options: options))
    }
}
