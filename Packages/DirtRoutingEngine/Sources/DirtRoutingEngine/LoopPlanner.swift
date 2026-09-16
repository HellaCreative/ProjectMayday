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
            let result = try circuit(request, cap: cap, budget: budget, discoverOffer: false)
            if result.distanceMeters < request.targetMeters * 0.5 {
                throw LoopFailure.noReturn(outboundMeters: result.outbound.distanceMeters,
                                           offeredMeters: result.distanceMeters,
                                           detail: "No loop near the requested distance without re-riding the outbound.")
            }
            return result
        } catch let failure as LoopFailure {
            guard case .noReturn(let outboundMeters, let alreadyOffered, let detail) = failure else { throw failure }
            if alreadyOffered != nil { throw failure }
            var offered: Double?
            for scale in [0.7, 0.5, 1.5] {
                try budget.check()
                let offerStarted = ContinuousClock.now
                if let trial = try? circuit(request, cap: cap * scale, budget: budget, discoverOffer: true) {
                    offered = trial.distanceMeters
                    request.options.counter?.recordStage("loop-offer-\(Int(scale * 100))", since: offerStarted)
                    break
                }
                request.options.counter?.recordStage("loop-offer-\(Int(scale * 100))", since: offerStarted)
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
        guard outbound.distanceMeters > 250 else { throw LoopFailure.noOutbound }
        let ends = try matcher.matches(at: outbound.end.coordinate, radius: radius, start: true, policy: request.access,
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
        if let result = try returnFrom(outbound, farMatch: farMatch, home: home, request: request,
                                       steps: steps, relaxations: &relaxations, budget: budget) {
            return result
        }
        if !discoverOffer {
            for fraction in [0.2, 0.4] {
                try budget.check()
                guard let trimmed = prefix(outbound, droppingTailMeters: outbound.distanceMeters * fraction) else { continue }
                let trimmedFar = trimmed.end.coordinate
                let trimmedEnds = try matcher.matches(at: trimmedFar, radius: radius, start: true,
                                                      policy: request.access,
                                                      intent: (request.headingRadians + .pi) * 180 / .pi, budget: budget)
                guard let trimmedMatch = trimmedEnds.first else { continue }
                let ids = Set(trimmed.segments.map(\.edgeID).filter { !$0.isEmpty })
                guard !ids.isEmpty else { continue }
                let name = "walk-back-\(Int(fraction * 100))"
                if let found = try returnFrom(trimmed, farMatch: trimmedMatch, home: home, request: request,
                                              steps: [("strict", ids)], relaxations: &relaxations, budget: budget) {
                    relaxations.append(name)
                    return LoopPlanResult(outbound: found.outbound, inbound: found.inbound, far: found.far,
                                          relaxations: relaxations)
                }
                relaxations.append("failed:\(name)")
            }
        }
        throw LoopFailure.noReturn(outboundMeters: outbound.distanceMeters, offeredMeters: nil,
                                   detail: "No return without re-riding the outbound.")
    }

    private func returnFrom(_ outbound: ComputedRoute, farMatch: RoadMatch, home: RoadMatch,
                            request: LoopRequest, steps: [(name: String, avoid: Set<String>)],
                            relaxations: inout [String], budget: ComputationBudget) throws -> LoopPlanResult? {
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
                return LoopPlanResult(outbound: outbound, inbound: inbound, far: outbound.end.coordinate,
                                      relaxations: relaxations)
            } catch let error as RoutingFailure {
                if case .resourceLimit = error { throw error }
                relaxations.append("failed:\(step.name)")
                request.options.counter?.recordStage("loop-return-\(step.name)", since: compassStarted)
            } catch {
                relaxations.append("failed:\(step.name)")
                request.options.counter?.recordStage("loop-return-\(step.name)", since: compassStarted)
            }
        }
        return nil
    }

    private func prefix(_ route: ComputedRoute, droppingTailMeters: Double) -> ComputedRoute? {
        var remain = droppingTailMeters
        var segs = route.segments
        while remain > 0, segs.count > 1 {
            remain -= segs.removeLast().meters
        }
        let meters = segs.reduce(0.0) { $0 + $1.meters }
        guard meters > 250, let last = segs.last, let coord = last.geometry.last else { return nil }
        let end = RoadMatch(edge: last.edge, coordinate: coord, distanceMeters: 0,
                            alongMeters: last.meters, geometryMeters: last.meters, forward: last.forward)
        return ComputedRoute(start: route.start, end: end, segments: segs, distanceMeters: meters,
                             searchCost: route.searchCost, poppedLabels: route.poppedLabels,
                             arrivalRestrictions: route.arrivalRestrictions)
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
