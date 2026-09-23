import Foundation

public struct LoopRequest: Sendable {
    public let start: Coordinate
    public let far: Coordinate
    public let targetMeters: Double
    public var profile: ProfilePolicy
    public var access: AccessPolicy
    public var options: SearchOptions
    public var matchRadiusMeters: Double
    public var mapZoom: Double?
    public init(start: Coordinate, far: Coordinate, targetMeters: Double, style: RidingStyle,
                allowUnknown: Bool = false, seed: UInt64 = 0) {
        self.start = start
        self.far = far
        self.targetMeters = targetMeters
        profile = .init(style: style)
        let roundTrip = max(1, start.distance(to: far) * 2)
        profile.wander = min(1, max(0, (max(0, targetMeters) / roundTrip - 1) / 2))
        access = .init(allowUnknown: style == .cleanest ? false : allowUnknown)
        options = .init()
        options.seed = seed
        matchRadiusMeters = 250
    }
}

public struct LoopPlanResult: Sendable {
    public let outbound: ComputedRoute
    public let inbound: ComputedRoute
    public let far: Coordinate
    public var distanceMeters: Double { outbound.distanceMeters + inbound.distanceMeters }
    public var segments: [RouteSegment] { outbound.segments + inbound.segments }
    public var reriddenMeters: Double { RouteQuality(route: combined).reriddenMeters }
    public var returnMeters: Double { RouteQuality(route: combined).returnMeters }
    public var combined: ComputedRoute {
        var route = ComputedRoute(start: outbound.start, end: inbound.end, segments: segments,
                      distanceMeters: distanceMeters,
                      searchCost: outbound.searchCost + inbound.searchCost,
                      poppedLabels: outbound.poppedLabels + inbound.poppedLabels,
                      arrivalRestrictions: inbound.arrivalRestrictions)
        route.startRoadIdentity = outbound.startRoadIdentity
        route.endRoadIdentity = inbound.endRoadIdentity
        return route
    }
}

public enum LoopFailure: Error, Equatable, Sendable {
    case pinUnreachable
}

/// Start pin, rider-dropped far pin, and a distance target. Outbound and return
/// are ordinary styled searches. Complete circuits compare both legal departure
/// directions; unavoidable shared access roads remain possible.
public struct LoopPlanner: Sendable {
    let pack: any RoadGraph
    public init(pack: any RoadGraph) { self.pack = pack }

    public func plan(_ request: LoopRequest, budget: ComputationBudget = .init(seconds: 60),
                     onLeg: ((Int, ComputedRoute) throws -> Void)? = nil) throws -> LoopPlanResult {
        // Start near the pin to avoid turning low-Wander rides into province-wide
        // tours. This is a search hint, never a reachability boundary: retry with
        // the caller's original area if the nearby search cannot connect.
        guard request.options.extentCenter == nil else {
            return try planInArea(request, budget: budget, onLeg: onLeg)
        }
        var nearby = request
        nearby.options.extentCenter = request.start
        nearby.options.maxExtentMeters = request.start.distance(to: request.far) + 2_000
        var selected: LoopPlanResult
        do {
            selected = try planInArea(nearby, budget: budget)
        } catch LoopFailure.pinUnreachable {
            return try planInArea(request, budget: budget, onLeg: onLeg)
        } catch RoutingFailure.noPath {
            return try planInArea(request, budget: budget, onLeg: onLeg)
        }
        // A folded nearby result may improve outside that area, but an optional
        // comparison cannot replace it with a much longer tour or erase success.
        if selected.reriddenMeters > max(500, selected.distanceMeters * 0.05) {
            do {
                let wider = try planInArea(request, budget: budget.limited(to: 2))
                if wider.distanceMeters <= selected.distanceMeters * 1.25,
                   Self.prefersCircuit(wider, over: selected, style: request.profile.style) {
                    selected = wider
                }
            } catch is CancellationError { throw CancellationError() }
            catch LoopFailure.pinUnreachable { }
            catch RoutingFailure.noPath { }
            catch RoutingFailure.resourceLimit { }
        }
        try Task.checkCancellation()
        try onLeg?(0, selected.outbound)
        try onLeg?(1, selected.inbound)
        return selected
    }

    private func planInArea(_ request: LoopRequest, budget: ComputationBudget,
                            onLeg: ((Int, ComputedRoute) throws -> Void)? = nil) throws -> LoopPlanResult {
        try budget.check()
        let engine = RoutingEngine(pack: pack)
        var outboundRequest = RoutingRequest(start: request.start, end: request.far,
                                             style: request.profile.style,
                                             allowUnknown: request.access.allowUnknown,
                                             seed: request.options.seed)
        outboundRequest.profile = request.profile
        outboundRequest.access = request.access
        outboundRequest.options = request.options
        outboundRequest.matchRadiusMeters = request.matchRadiusMeters
        outboundRequest.mapZoom = request.mapZoom
        outboundRequest.options.avoidEdges = []
        outboundRequest.options.repeatEdges = []
        outboundRequest.options.maximumMeters = .infinity
        let slack = max(0, request.targetMeters / 2 - request.start.distance(to: request.far))
        outboundRequest.options.loopSlackMeters = slack
        // The pin is a required destination, not a radius around home. Legal
        // roads may pass beyond it to cross a river or reach the other side.
        // Keep any explicit caller extent; do not invent one from pin distance.
        let outbound: ComputedRoute
        do {
            outbound = try engine.route(outboundRequest, budget: budget)
        } catch RoutingFailure.ferriesAvoided {
            throw RoutingFailure.ferriesAvoided
        } catch RoutingFailure.noMatch {
            throw LoopFailure.pinUnreachable
        } catch RoutingFailure.noPath {
            throw LoopFailure.pinUnreachable
        }
        // Every return is searched legally with the far pin's arrival state.
        // A failed search is never permission to reverse directed roads.
        func returning(from first: ComputedRoute, budget: ComputationBudget,
                       departure: RoadMatch? = nil, connecting: Bool = false, separate: Bool = false) throws -> ComputedRoute {
            var back = outboundRequest.with(start: first.end.coordinate, end: first.start.coordinate)
            back.options.repeatEdges = Set(first.segments.map(\.edgeID).filter { !$0.isEmpty })
            back.options.repeatFactor = 16
            if separate { back.options.repeatMinimumCostPerKm = 150 }
            if connecting { back.profile.style = .balanced; back.profile.balancedDirtPreference = 0 }
            if let last = first.segments.last {
                back.options.arrival = .init(edge: pack.restrictionEdge(last.edge),
                    coordinate: first.end.coordinate, restrictions: first.arrivalRestrictions)
                back.options.arrivalEdgeID = pack.identity(of: last.edge)
                back.options.arrivalRestrictions = first.arrivalRestrictions
            }
            if let departure {
                return try engine.route(back, start: departure, end: first.start, budget: budget)
            }
            return try engine.route(back, budget: budget)
        }
        let inbound = try returning(from: outbound, budget: budget)
        var selected = LoopPlanResult(outbound: outbound, inbound: inbound, far: request.far)
        let maximumCandidateMeters = selected.distanceMeters * 1.25
        let comparisonBudget = budget.limited(to: min(6, budget.remainingSeconds * 0.5))
        func otherDirection(_ match: RoadMatch) throws -> RoadMatch? {
            try RoadMatcher(pack: pack).matches(at: match.coordinate, radius: 1, start: true,
                policy: request.access, limit: 64, budget: comparisonBudget).first {
                    $0.edge == match.edge && $0.forward != match.forward
                        && abs($0.alongMeters - match.alongMeters) < 1
                }
        }
        func consider(_ first: ComputedRoute, _ back: ComputedRoute) {
            let candidate = LoopPlanResult(outbound: first, inbound: back, far: request.far)
            guard first.limit == nil, back.limit == nil,
                  candidate.distanceMeters <= maximumCandidateMeters else { return }
            if Self.prefersCircuit(candidate, over: selected, style: request.profile.style) {
                selected = candidate
            }
        }
        // Compare complete circuits from both legal directions of the SAME
        // snapped roads. Never jump to a nearby disconnected/parallel trail.
        do {
            if let opposite = try otherDirection(inbound.start) {
                consider(outbound, try returning(from: outbound, budget: comparisonBudget, departure: opposite))
            }
        } catch is CancellationError { throw CancellationError() }
        catch let failure as RoutingFailure {
            switch failure {
            case .noPath, .resourceLimit: break
            default: throw failure
            }
        }
        do {
            if let opposite = try otherDirection(outbound.start) {
                let first = try engine.route(outboundRequest, start: opposite, end: outbound.end,
                                             budget: comparisonBudget)
                let back = try returning(from: first, budget: comparisonBudget)
                consider(first, back)
                if let other = try otherDirection(back.start) {
                    consider(first, try returning(from: first, budget: comparisonBudget, departure: other))
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch let failure as RoutingFailure {
            switch failure {
            case .noPath, .resourceLimit: break
            default: throw failure
            }
        }
        // Dirt describes the whole ride, not an obligation to hunt for dirt on
        // both halves. Compare a direct connecting half with the dirt-rich half,
        // under the same access, extent and total comparison budget.
        if request.profile.style == .dirt {
            do {
                consider(outbound, try returning(from: outbound, budget: comparisonBudget, separate: true))
                consider(outbound, try returning(from: outbound, budget: comparisonBudget, connecting: true, separate: true))
                var connector = outboundRequest
                connector.profile.style = .balanced
                connector.profile.balancedDirtPreference = 0
                let first = try engine.route(connector, budget: comparisonBudget)
                consider(first, try returning(from: first, budget: comparisonBudget, separate: true))
            } catch is CancellationError { throw CancellationError() }
            catch let failure as RoutingFailure {
                switch failure {
                case .noPath, .resourceLimit: break
                default: throw failure
                }
            }
        }
        try Task.checkCancellation()
        // Only selected, legally completed legs become visible; rejected
        // alternatives never appear as completed rider progress.
        try onLeg?(0, selected.outbound)
        try onLeg?(1, selected.inbound)
        return selected
    }

    static func prefersCircuit(_ candidate: LoopPlanResult, over existing: LoopPlanResult,
                               style: RidingStyle) -> Bool {
        let a = RouteQuality(route: candidate.combined), b = RouteQuality(route: existing.combined)
        // Continuous useful dirt must not lose to a paved-only shortcut.
        if style == .dirt, (a.meaningfulDirtMeters > 0) != (b.meaningfulDirtMeters > 0) {
            return a.meaningfulDirtMeters > 0
        }
        if abs(a.reriddenMeters - b.reriddenMeters) > 500 {
            return a.reriddenMeters < b.reriddenMeters
        }
        if style == .dirt {
            return RouteQuality.prefersDirt(a, over: b, widthA: 0, widthB: 0)
        }
        if style == .balanced, abs(a.knownDirtPercent - 50) != abs(b.knownDirtPercent - 50) {
            return abs(a.knownDirtPercent - 50) < abs(b.knownDirtPercent - 50)
        }
        if style == .cleanest, abs(a.knownDirtPercent - b.knownDirtPercent) > 2 {
            return a.knownDirtPercent < b.knownDirtPercent
        }
        return candidate.distanceMeters < existing.distanceMeters
    }

    /// Distance target sets wander: a pin 20 km away with a 120 km target is a
    /// wandering ride; the same pin with a 50 km target stays tighter. Never
    /// below 0 or above 1, and never at the expense of reaching the pin.
    func aimedWander(start: Coordinate, far: Coordinate, target: Double) -> Double {
        let thereAndBack = max(1, start.distance(to: far) * 2)
        let ratio = max(0, target) / thereAndBack
        return min(1, max(0, (ratio - 1) / 2))
    }
}
