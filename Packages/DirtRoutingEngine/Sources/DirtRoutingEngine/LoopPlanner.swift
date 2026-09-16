import Foundation

public struct LoopRequest: Sendable {
    public let start: Coordinate
    public let headingRadians: Double
    public let targetMeters: Double
    public var profile: ProfilePolicy
    public var access: AccessPolicy
    public var options: SearchOptions
    public var matchRadiusMeters: Double
    public var mapZoom: Double?
    public init(start: Coordinate, headingRadians: Double, targetMeters: Double, style: RidingStyle,
                allowUnknown: Bool = false, seed: UInt64 = 0) {
        self.start = start
        self.headingRadians = headingRadians
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
    public let relaxations: [String]
    public var distanceMeters: Double { outbound.distanceMeters + inbound.distanceMeters }
    public var segments: [RouteSegment] { outbound.segments + inbound.segments }
    public var combined: ComputedRoute {
        ComputedRoute(start: outbound.start, end: inbound.end, segments: segments,
                      distanceMeters: distanceMeters,
                      searchCost: outbound.searchCost + inbound.searchCost,
                      poppedLabels: outbound.poppedLabels + inbound.poppedLabels,
                      arrivalRestrictions: inbound.arrivalRestrictions)
    }
}

public enum LoopFailure: Error, Equatable, Sendable {
    case noOutbound
    case noReturn(outboundMeters: Double, offeredMeters: Double?, detail: String)
}

/// Start pin + heading + target distance. Outbound stops at half the target;
/// the far point is wherever that ride reached. Return excludes outbound edges.
public struct LoopPlanner: Sendable {
    let pack: any RoadGraph
    public init(pack: any RoadGraph) { self.pack = pack }

    public func plan(_ request: LoopRequest, budget: ComputationBudget = .init(seconds: 60)) throws -> LoopPlanResult {
        try budget.check()
        let cap = max(5_000, request.targetMeters / 2)
        do {
            return try circuit(request, cap: cap, budget: budget, discoverOffer: false)
        } catch let failure as LoopFailure {
            guard case .noReturn(let outboundMeters, _, let detail) = failure else { throw failure }
            var offered: Double?
            for scale in [0.7, 0.5] {
                try budget.check()
                request.options.counter?.recordStage("loop-offer-\(Int(scale * 100))", since: ContinuousClock.now)
                if let trial = try? circuit(request, cap: cap * scale, budget: budget, discoverOffer: true) {
                    offered = trial.distanceMeters
                    break
                }
            }
            throw LoopFailure.noReturn(outboundMeters: outboundMeters, offeredMeters: offered, detail: detail)
        }
    }

    private func circuit(_ request: LoopRequest, cap: Double, budget: ComputationBudget,
                         discoverOffer: Bool) throws -> LoopPlanResult {
        let matcher = RoadMatcher(pack: pack)
        let radius = min(2000, max(80, request.matchRadiusMeters))
        let starts = try matcher.matches(at: request.start, radius: radius, start: true,
                                         policy: request.access, intent: request.headingRadians * 180 / .pi,
                                         budget: budget)
        guard let start = starts.first else { throw RoutingFailure.noMatch }
        request.options.counter?.recordStage("loop-match", since: ContinuousClock.now)
        var outboundOptions = styledOptions(request)
        outboundOptions.maximumMeters = cap
        outboundOptions.expandToCap = true
        outboundOptions.headingRadians = request.headingRadians
        outboundOptions.corridorMeters = .infinity
        outboundOptions.roadRemaining = nil
        outboundOptions.avoidEdges = []
        let outboundStarted = ContinuousClock.now
        let outbound: ComputedRoute
        do {
            outbound = try PathSearch(pack: pack).search(start: start, end: start, policy: request.profile,
                                                         access: request.access, options: outboundOptions, budget: budget)
        } catch let error as RoutingFailure {
            request.options.counter?.recordStage("loop-outbound", since: outboundStarted)
            if case .resourceLimit = error { throw error }
            throw LoopFailure.noOutbound
        }
        request.options.counter?.recordStage("loop-outbound", since: outboundStarted)
        guard outbound.distanceMeters > 1_000 else { throw LoopFailure.noOutbound }
        let far = outbound.end.coordinate
        let ends = try matcher.matches(at: far, radius: radius, start: true, policy: request.access,
                                       intent: (request.headingRadians + .pi) * 180 / .pi, budget: budget)
        let homes = try matcher.matches(at: request.start, radius: radius, start: false, policy: request.access,
                                        intent: (request.headingRadians + .pi) * 180 / .pi, budget: budget)
        guard let farMatch = ends.first, let home = homes.first else { throw RoutingFailure.noMatch }
        let outboundIDs = outbound.segments.map(\.edgeID).filter { !$0.isEmpty }
        let short = Set(outbound.segments.filter { $0.meters < 250 }.map(\.edgeID))
        let kilometre = Set(outbound.segments.filter { $0.meters < 1_000 }.map(\.edgeID))
        let avoid = Set(outboundIDs)
        guard !avoid.isEmpty else {
            throw LoopFailure.noReturn(outboundMeters: outbound.distanceMeters, offeredMeters: nil,
                                       detail: "Outbound left no independent return corridor.")
        }
        let steps: [(name: String, avoid: Set<String>)] = discoverOffer
            ? [("strict", avoid)]
            : [
                ("strict", avoid),
                ("short-connectors", avoid.subtracting(short)),
                ("widen-1km", avoid.subtracting(kilometre)),
            ]
        var relaxations: [String] = []
        for (index, step) in steps.enumerated() {
            try budget.check()
            guard !step.avoid.isEmpty else {
                relaxations.append("skipped:\(step.name)")
                continue
            }
            var inboundOptions = styledOptions(request)
            inboundOptions.avoidEdges = step.avoid
            inboundOptions.corridorMeters = .infinity
            inboundOptions.maximumMeters = .infinity
            inboundOptions.expandToCap = false
            inboundOptions.headingRadians = nil
            let compassStarted = ContinuousClock.now
            inboundOptions.roadRemaining = try? RoadCompass.toward(end: home, pack: pack, budget: budget).remaining
            request.options.counter?.recordStage("loop-return-compass", since: compassStarted)
            do {
                let inbound = try PathSearch(pack: pack).search(start: farMatch, end: home, policy: request.profile,
                                                                access: request.access, options: inboundOptions, budget: budget)
                if index > 0 { relaxations.append(step.name) }
                request.options.counter?.recordStage("loop-return-\(step.name)", since: compassStarted)
                return LoopPlanResult(outbound: outbound, inbound: inbound, far: far, relaxations: relaxations)
            } catch let error as RoutingFailure {
                if case .resourceLimit = error { throw error }
                relaxations.append("failed:\(step.name)")
                request.options.counter?.recordStage("loop-return-\(step.name)", since: compassStarted)
            } catch {
                relaxations.append("failed:\(step.name)")
                request.options.counter?.recordStage("loop-return-\(step.name)", since: compassStarted)
            }
        }
        throw LoopFailure.noReturn(outboundMeters: outbound.distanceMeters, offeredMeters: nil,
                                   detail: "No return without re-riding the outbound.")
    }

    func styledOptions(_ request: LoopRequest) -> SearchOptions {
        var options = request.options
        options.corridorMeters = .infinity
        options.expandToCap = false
        options.headingRadians = nil
        options.roadRemaining = nil
        options.avoidEdges = []
        switch request.profile.style {
        case .dirt: options.objective = .pavement
        case .balanced, .cleanest: options.objective = .profile
        }
        options.pavedOnly = request.profile.style == .cleanest
        options.varietyEnabled = false
        return options
    }
}
