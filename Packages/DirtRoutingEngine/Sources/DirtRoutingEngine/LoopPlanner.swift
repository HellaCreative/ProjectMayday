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
        ComputedRoute(start: outbound.start, end: inbound.end, segments: segments,
                      distanceMeters: distanceMeters,
                      searchCost: outbound.searchCost + inbound.searchCost,
                      poppedLabels: outbound.poppedLabels + inbound.poppedLabels,
                      arrivalRestrictions: inbound.arrivalRestrictions)
    }
}

public enum LoopFailure: Error, Equatable, Sendable {
    case pinUnreachable
}

/// Start pin, rider-dropped far pin, and a distance target. Outbound and return
/// are ordinary styled searches. Outbound edges are expensive on the return,
/// not forbidden, so a confined network still comes home.
public struct LoopPlanner: Sendable {
    let pack: any RoadGraph
    public init(pack: any RoadGraph) { self.pack = pack }

    public func plan(_ request: LoopRequest, budget: ComputationBudget = .init(seconds: 60)) throws -> LoopPlanResult {
        try budget.check()
        var request = request
        request.profile.wander = aimedWander(start: request.start, far: request.far, target: request.targetMeters)
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
        let outbound: ComputedRoute
        do {
            outbound = try engine.route(outboundRequest, budget: budget)
        } catch is RoutingFailure {
            throw LoopFailure.pinUnreachable
        }
        var inboundRequest = outboundRequest.with(start: request.far, end: request.start)
        inboundRequest.options.repeatEdges = Set(outbound.segments.map(\.edgeID).filter { !$0.isEmpty })
        inboundRequest.options.repeatFactor = 16
        inboundRequest.options.avoidEdges = []
        let inbound: ComputedRoute
        do {
            inbound = try engine.route(inboundRequest, budget: budget)
        } catch {
            inbound = outbound.reversed()
        }
        return LoopPlanResult(outbound: outbound, inbound: inbound, far: request.far)
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
