import Foundation

/// Internal stages for a rider-to-rider leg that spans two or more packs.
/// Three-plus packs use overlapping two-pack windows so border seams stay
/// searchable. Exactly two packs on a long geodesic stage as single-pack hops
/// with a seam handover — needed so Ontario South/North (and later QC/CA
/// halves) clear the label budget instead of joining both halves into one graph.
public enum StagedRouter {
    public static let longGeodesicMeters = 400_000.0
    /// Two-pack corridors (subregion halves) stage earlier than multi-province.
    public static let twoPackGeodesicMeters = 100_000.0
    /// How many diversified corridor pins to try before giving up a hop.
    public static let handoverCandidateLimit = 12

    /// Preserve structural facts until handover ranking has selected a pin.
    /// Water-like and stub candidates remain legal fallbacks; they are never
    /// discarded — only demoted so giant-component land seams try first.
    /// `stubOnSearch` = missing from the stage-window giant (hopLooksLive class).
    /// `stubOnNext` = missing from the next pack giant (onward commitment).
    struct HandoverCandidate {
        let coordinate: Coordinate
        let waterLike: Bool
        let stubOnSearch: Bool
        let stubOnNext: Bool

        init(coordinate: Coordinate, waterLike: Bool,
             stubOnSearch: Bool = false, stubOnNext: Bool = false) {
            self.coordinate = coordinate
            self.waterLike = waterLike
            self.stubOnSearch = stubOnSearch
            self.stubOnNext = stubOnNext
        }

        /// Backward-compatible combined demotion used by older call sites/tests.
        var stubIsland: Bool { stubOnSearch || stubOnNext }
    }

    /// Dirt only: leave wall-clock for later pins so one dead seam cannot burn
    /// the parent budget (Providence 012024Z). Cap is higher than FuelPlanner's
    /// 20s fuel-hop ceiling — staged Dirt personality searches need tens of
    /// seconds on nb+qc-s / prairie windows (005137Z stage timings).
    static func dirtCandidateSliceSeconds(remainingSeconds: Double, candidatesLeft: Int) -> Double {
        let later = max(0, candidatesLeft - 1)
        let reserve = Double(later) * 20
        let available = max(0, remainingSeconds - reserve)
        return min(remainingSeconds, max(20, available))
    }

    static func budgetForHandoverCandidate(_ budget: ComputationBudget, style: RidingStyle,
                                           attempt: Int, candidateCount: Int) -> ComputationBudget {
        guard style == .dirt else { return budget }
        let candidatesLeft = max(1, candidateCount - attempt)
        // The final remaining candidate gets the full parent remainder.
        guard candidatesLeft > 1 else { return budget }
        return budget.limited(to: dirtCandidateSliceSeconds(
            remainingSeconds: budget.remainingSeconds, candidatesLeft: candidatesLeft))
    }

    public static func shouldStage(regionCount: Int, start: Coordinate, end: Coordinate) -> Bool {
        let span = start.distance(to: end)
        if regionCount >= 3 { return span > longGeodesicMeters }
        if regionCount == 2 { return span > twoPackGeodesicMeters }
        return false
    }

    public static func overlappingWindows(_ chain: [String]) -> [[String]] {
        guard chain.count >= 2 else { return chain.isEmpty ? [] : [chain] }
        // Two-pack long corridors: sequential single-pack stages + seam pin.
        if chain.count == 2 { return [[chain[0]], [chain[1]]] }
        return (0..<(chain.count - 1)).map { [chain[$0], chain[$0 + 1]] }
    }

    public static func route(_ request: RoutingRequest, repository: PackRepository,
                             regions: [String], budget: ComputationBudget,
                             prepared: PreparedGraphStore = PreparedGraphStore(),
                             compassStore: RoadCompassStore? = nil,
                             renewAfterCommittedStage: Bool = false) throws -> ComputedRoute {
        let connectionsStarted = ContinuousClock.now
        let unique = Array(Set(regions)).sorted()
        let startRegion = try containingRegion(request.start, regions: unique, repository: repository,
                                               budget: budget, prepared: prepared, access: request.access, start: true)
        let endRegion = try containingRegion(request.end, regions: unique, repository: repository,
                                             budget: budget, prepared: prepared, access: request.access, start: false)
        let neighbors = try neighborMap(unique, repository: repository)
        var roads: [String:Set<String>] = [:]
        for id in unique {
            try budget.check()
            if let roadNeighbors = try repository.roadNeighborIDs(id) {
                roads[id] = roadNeighbors.intersection(Set(unique))
            }
        }
        let chains = try RegionConnectivity(neighbors: neighbors).chains(from: startRegion, to: endRegion,
                                                                          roadNeighbors: roads)
        if chains.count == 1 {
            return try routeChain(request, chain: chains[0], repository: repository, budget: budget,
                prepared: prepared, compassStore: compassStore, renewAfterCommittedStage: renewAfterCommittedStage)
        }
        return try firstCompletedConnection(chains, budget: budget) { chain, attemptBudget in
            let candidate = try routeChain(request, chain: chain, repository: repository, budget: attemptBudget,
                prepared: prepared, compassStore: compassStore, renewAfterCommittedStage: false)
            request.options.counter?.recordStage("connectionReady:\(chain.joined(separator: "+"))", since: connectionsStarted)
            return candidate
        }
    }

    /// Existing early-return implementation, pending journey-selection repair.
    /// The owner rejects using storage boundaries/discovery order to choose a ride.
    /// Preserve bounded failure recovery and cancellation when replacing it.
    static func firstCompletedConnection(_ chains: [[String]], budget: ComputationBudget,
        build: ([String], ComputationBudget) throws -> ComputedRoute) throws -> ComputedRoute {
        var outcomes: [String] = []
        var incomplete: RoutingFailure?
        for (index, chain) in chains.enumerated() {
            let attemptBudget = budget.limited(to: budget.remainingSeconds / Double(chains.count - index))
            do {
                try attemptBudget.check()
                var candidate = try build(chain, attemptBudget)
                if let limit = candidate.limit { throw RoutingFailure.resourceLimit(limit) }
                outcomes.append("\(chain.joined(separator: "+")):\(Int(candidate.distanceMeters))m")
                candidate.searchSummary = "connections[\(outcomes.joined(separator: ","))];" + (candidate.searchSummary ?? "")
                return candidate
            } catch RoutingFailure.noPath {
                outcomes.append("\(chain.joined(separator: "+")):noPath")
            } catch let failure as RoutingFailure {
                switch failure {
                case .resourceLimit:
                    incomplete = failure
                    outcomes.append("\(chain.joined(separator: "+")):\(failure)")
                default: throw failure
                }
            }
        }
        if let incomplete { throw incomplete }
        throw RoutingFailure.noPath
    }

    private static func routeChain(_ request: RoutingRequest, chain: [String], repository: PackRepository,
                                   budget: ComputationBudget, prepared: PreparedGraphStore,
                                   compassStore: RoadCompassStore?, renewAfterCommittedStage: Bool) throws -> ComputedRoute {
        let windows = overlappingWindows(chain)
        guard windows.count >= 2 else {
            return try routeWindow(windows.first ?? chain, request: request, repository: repository,
                                   budget: budget, prepared: prepared, compassStore: compassStore)
        }
        var parts: [ComputedRoute] = []
        var cursor = request.start
        // True two-pack halves (on-s|on-n, nb|me as [[nb],[me]]): try each
        // handover pin as an atomic stage0+stage1 pair so a pin live in one half
        // but stub in the other cannot commit. Overlapping multi-pack windows
        // such as [[ns,nb],[nb,me]] also have count==2 — those must use the
        // multi-pack loop (Providence 20260919 host matrix).
        if windows.count == 2,
           windows[0].count == 1, windows[1].count == 1,
           let originPack = windows[0].last, let destPack = windows[1].last {
            // Same staged-aim contract as multi-pack. Two-pack has no onward seam
            // belt, so chainLocalAim returns the rider destination.
            let toward = try chainLocalAim(windows: windows, stageIndex: 0, next: destPack,
                                           finalDestination: request.end, repository: repository,
                                           currentShared: originPack)
            let prepareStarted = ContinuousClock.now
            let graphs = try prepared.indexedWindows(windows, repository: repository, budget: budget)
            request.options.counter?.recordStage("prepareWindows", since: prepareStarted)
            let firstGraph = graphs[0]
            let secondGraph = graphs[1]
            // Rank against the origin-half giant (not solo shared/next packs): coastal
            // nb↔me proofs can sit in both solo giants yet be islands in [ns]/[nb].
            let anchors = try handoverCandidates(from: originPack, into: destPack, from: cursor,
                                              toward: toward, repository: repository,
                                              searchGraph: firstGraph, budget: budget,
                                              access: request.access)
            let pins = try sharedHandoverPoints(anchors, first: firstGraph, next: secondGraph,
                access: request.access, budget: budget)
            guard !pins.isEmpty else { throw RoutingFailure.noPath }
            var lastError: Error = RoutingFailure.noPath
            var incomplete: RoutingFailure?
            var reach0: EndpointReachability?
            var reach1: EndpointReachability?
            for (attempt, hopEnd) in pins.enumerated() {
                try budget.check()
                // Directed reachability on both halves — overlap stubs that Balanced
                // would burn ~20s on fail here in well under a second after the first
                // arc-index build. Do not use Cleanest preflight: those hops are long.
                let filterStarted = ContinuousClock.now
                let live = try seamPinLooksLive(hopEnd, origin: cursor, destination: request.end,
                                                first: firstGraph, second: secondGraph,
                                                request: request, budget: budget,
                                                reach0: &reach0, reach1: &reach1)
                request.options.counter?.recordStage("seamFilter", since: filterStarted)
                guard live else {
                    lastError = RoutingFailure.noPath
                    continue
                }
                let candidatesLeft = max(1, pins.count - attempt)
                let sliceSeconds = request.profile.style == .dirt && candidatesLeft > 1
                    ? dirtCandidateSliceSeconds(remainingSeconds: budget.remainingSeconds,
                                                candidatesLeft: candidatesLeft)
                    : budget.remainingSeconds
                let attemptBudget = budgetForHandoverCandidate(
                    budget, style: request.profile.style, attempt: attempt, candidateCount: pins.count)
                do {
                    var hop0 = request.with(start: cursor, end: hopEnd)
                    let sharedMatches = try RoadMatcher(pack: secondGraph).matches(
                        at: hopEnd, radius: 1, start: true, policy: request.access,
                        limit: 64, budget: attemptBudget)
                    hop0.options.requiredArrivalRoads = Set(sharedMatches.filter {
                        secondGraph.accessCode($0.edge, forward: $0.forward != false) == 0
                    }.map { secondGraph.identity(of: $0.edge) })
                    guard !hop0.options.requiredArrivalRoads.isEmpty else { throw RoutingFailure.noMatch }
                    hop0.options.compassMaxRemaining = max(450_000, cursor.distance(to: hopEnd) * 2.5)
                    let started0 = ContinuousClock.now
                    var part0 = try RoutingEngine(pack: firstGraph, compassStore: compassStore)
                        .route(hop0, budget: attemptBudget)
                    part0 = try handoverBeforeFinalRoad(part0, request: hop0, graph: firstGraph,
                        nextGraph: secondGraph, budget: attemptBudget)
                    if let limit = part0.limit { throw RoutingFailure.resourceLimit(limit) }
                    hop0.options.counter?.recordStage("stage0:\(windows[0].joined(separator: ","))", since: started0)
                    if attempt > 0 {
                        hop0.options.counter?.recordStage("handoverRetry:\(attempt)", since: started0)
                    }
                    if request.profile.style == .dirt {
                        hop0.options.counter?.recordStage(
                            "handoverSlice:\(attempt):\(Int(sliceSeconds.rounded()))s", since: started0)
                    }
                    var hop1 = request.with(start: part0.end.coordinate, end: request.end)
                    hop1.options.compassMaxRemaining = max(450_000, part0.end.coordinate.distance(to: request.end) * 2.5)
                    hop1.options.precedingMeters = part0.distanceMeters
                    hop1.options.precedingDirtMeters = knownDirtMeters(part0)
                    hop1.options.priorEdges.formUnion(part0.segments.map { firstGraph.identity(of: $0.edge) })
                    // Local array numbering belongs to the originating pack.
                    // Carry original topology identity into the next window.
                    hop1.options.arrivalEdgeID = part0.segments.last.map { firstGraph.identity(of: $0.edge) }
                    hop1.options.continuationForward = part0.segments.last?.forward
                    guard part0.arrivalRestrictions.isEmpty else {
                        throw RoutingFailure.unsupported("Active turn sequence requires a continuous regional search")
                    }
                    hop1.options.counter = request.options.counter
                    let started1 = ContinuousClock.now
                    let part1 = try routeAvoidingEarlierRoads(hop1, graph: secondGraph,
                        compassStore: compassStore, budget: attemptBudget)
                    hop1.options.counter?.recordStage("stage1:\(windows[1].joined(separator: ","))", since: started1)
                    return try stitch([part0, part1], windows: windows)
                } catch RoutingFailure.noPath {
                    lastError = RoutingFailure.noPath
                    continue
                } catch RoutingFailure.noMatch {
                    lastError = RoutingFailure.noMatch
                    continue
                } catch let RoutingFailure.resourceLimit(kind) where kind == "labels" || kind == "time" {
                    // Providence Dirt (012024Z) burned 60s on a dead nb→me pin;
                    // try the next diversified handover instead of aborting.
                    incomplete = RoutingFailure.resourceLimit(kind)
                    lastError = RoutingFailure.resourceLimit(kind)
                    continue
                }
            }
            throw incomplete ?? lastError
        }
        // Multi-pack (NS→NB→QC class): warm the first window, then prefetch the
        // next while searching so later hops hit the store without loading every
        // overlapping pair into RSS at once.
        let prepareStarted = ContinuousClock.now
        _ = try prepared.indexed(windows[0], repository: repository, budget: budget)
        if windows.count > 1 {
            _ = try prepared.indexed(windows[1], repository: repository, budget: budget)
        }
        request.options.counter?.recordStage("prepareWindows", since: prepareStarted)
        var stageBudget = budget
        var incomingIdentity: String?
        var traversedRoads = request.options.priorEdges
        for (index, window) in windows.enumerated() {
            let budget = stageBudget
            try budget.check()
            // Open the stage graph before ranking so stub-island demotion uses the
            // joined window's giant component (Providence nb↔me class).
            let indexed = try openWindow(window, repository: repository, budget: budget, prepared: prepared)
            let candidates: [Coordinate]
            if index + 1 < windows.count, let next = windows[index + 1].last, let shared = window.last {
                // Aim intermediate handovers along the pack chain, not at the
                // ultimate destination. NS→BC otherwise ranks nb→qc-s pins toward
                // Whistler and burns the candidate list on western stubs before
                // the search ever reaches Manitoba / SK / AB.
                let toward = try chainLocalAim(
                    windows: windows,
                    stageIndex: index,
                    next: next,
                    finalDestination: request.end,
                    repository: repository,
                    currentShared: shared
                )
                candidates = try handoverCandidates(
                    from: shared,
                    into: next,
                    from: cursor,
                    toward: toward,
                    repository: repository,
                    searchGraph: indexed,
                    budget: budget,
                    access: request.access
                )
            } else {
                candidates = [request.end]
            }
            guard !candidates.isEmpty else { throw RoutingFailure.noPath }
            // Keep only the active and next window resident; completed routes own
            // geometry, not their prepared graphs.
            var prefetch: DispatchWorkItem?
            if index + 1 < windows.count {
                prefetch = prepared.prefetch(windows[index + 1], repository: repository, budget: budget)
            }
            defer { prefetch?.wait() }
            var lastError: Error = RoutingFailure.noPath
            var incomplete: RoutingFailure?
            var advanced = false
            var reach: EndpointReachability?
            var onwardReach: EndpointReachability?
            for (attempt, hopEnd) in candidates.enumerated() {
                try budget.check()
                // Same stub filter as the two-pack path — NS→NB→QC handovers
                // otherwise burn full searches on dead border pins.
                if index + 1 < windows.count {
                    let filterStarted = ContinuousClock.now
                    let live = try hopLooksLive(hopEnd, origin: cursor, graph: indexed,
                                                request: request, budget: budget, reach: &reach)
                    request.options.counter?.recordStage("seamFilter", since: filterStarted)
                    guard live else {
                        lastError = RoutingFailure.noPath
                        continue
                    }
                    if index + 2 == windows.count {
                        // Before spending a whole first-stage search, prove that
                        // the final window at least has a topological continuation
                        // from this seam to the rider's destination. A shared ferry
                        // can end in a third region absent from a short chain.
                        let onwardStarted = ContinuousClock.now
                        let nextGraph = try openWindow(windows[index + 1], repository: repository,
                            budget: budget, prepared: prepared)
                        let onward = try hopLooksLive(request.end, origin: hopEnd, graph: nextGraph,
                            request: request, budget: budget, reach: &onwardReach)
                        request.options.counter?.recordStage("onwardFilter", since: onwardStarted)
                        guard onward else {
                            lastError = RoutingFailure.noPath
                            continue
                        }
                    }
                }
                let candidatesLeft = max(1, candidates.count - attempt)
                let sliceSeconds = request.profile.style == .dirt && index + 1 < windows.count && candidatesLeft > 1
                    ? dirtCandidateSliceSeconds(remainingSeconds: budget.remainingSeconds,
                                                candidatesLeft: candidatesLeft)
                    : budget.remainingSeconds
                let attemptBudget = budgetForHandoverCandidate(
                    budget, style: request.profile.style, attempt: attempt, candidateCount: candidates.count)
                var hop = request.with(start: cursor, end: hopEnd)
                hop.options.priorEdges = traversedRoads
                let span = cursor.distance(to: hopEnd)
                hop.options.compassMaxRemaining = max(450_000, span * 2.5)
                if let previous = parts.last {
                    hop.options.precedingMeters = parts.reduce(0) { $0 + $1.distanceMeters }
                    hop.options.precedingDirtMeters = parts.reduce(0) { $0 + knownDirtMeters($1) }
                    hop.options.arrivalEdgeID = incomingIdentity
                    hop.options.continuationForward = previous.segments.last?.forward
                    guard previous.arrivalRestrictions.isEmpty else {
                        throw RoutingFailure.unsupported("Active turn sequence requires a continuous regional search")
                    }
                }
                let started = ContinuousClock.now
                hop.options.counter?.recordStage("handoverTarget:\(index):\(attempt):\(hopEnd.longitude),\(hopEnd.latitude)", since: started)
                do {
                    var part = try routeAvoidingEarlierRoads(hop, graph: indexed,
                        compassStore: compassStore, budget: attemptBudget)
                    hop.options.counter?.recordStage(
                        "stage\(index):\(window.joined(separator: ","))", since: started)
                    if attempt > 0 {
                        hop.options.counter?.recordStage("handoverRetry:\(attempt)", since: started)
                    }
                    if request.profile.style == .dirt, index + 1 < windows.count {
                        hop.options.counter?.recordStage(
                            "handoverSlice:\(attempt):\(Int(sliceSeconds.rounded()))s", since: started)
                    }
                    guard part.limit == nil else { throw RoutingFailure.resourceLimit(part.limit!) }
                    if index + 1 < windows.count {
                        let nextGraph = try openWindow(windows[index + 1], repository: repository,
                            budget: budget, prepared: prepared)
                        part = try handoverBeforeFinalRoad(part, request: hop, graph: indexed,
                            nextGraph: nextGraph, budget: budget)
                        guard let arrivalIdentity = part.segments.last.map({ indexed.identity(of: $0.edge) }) else {
                            throw RoutingFailure.noMatch
                        }
                        let continuations = try RoadMatcher(pack: nextGraph).matches(at: part.end.coordinate,
                            radius: 1, start: true, policy: request.access, limit: 64, budget: budget)
                        guard continuations.contains(where: {
                            nextGraph.matches($0.edge, identities: [arrivalIdentity]) && $0.forward == part.segments.last?.forward
                                && canContinueForward($0, graph: nextGraph, request: request)
                        }) else { throw RoutingFailure.noMatch }
                    }
                    incomingIdentity = part.segments.last.map { indexed.identity(of: $0.edge) }
                    // Remember original road identities before evicting this window.
                    // The next window has different local indices but the same roads.
                    traversedRoads.formUnion(part.segments.map { indexed.identity(of: $0.edge) })
                    parts.append(part)
                    cursor = part.end.coordinate
                    advanced = true
                    break
                } catch RoutingFailure.noPath {
                    lastError = RoutingFailure.noPath
                    continue
                } catch RoutingFailure.noMatch {
                    lastError = RoutingFailure.noMatch
                    continue
                } catch let RoutingFailure.resourceLimit(kind) where kind == "labels" || kind == "time" {
                    // Overlap stubs / long Dirt hops can burn labels or the wall
                    // clock on a dead pin — keep walking the diversified list.
                    incomplete = RoutingFailure.resourceLimit(kind)
                    lastError = RoutingFailure.resourceLimit(kind)
                    continue
                }
            }
            if !advanced { throw incomplete ?? lastError }
            prefetch?.wait()
            prefetch = nil // DispatchWorkItem permits only one successful wait.
            if renewAfterCommittedStage, index + 1 < windows.count {
                stageBudget = try budget.afterCommittedStage()
            }
        }
        return try stitch(parts, windows: windows)
    }

    /// Cut inside a real shared road, not at its entry junction. At the junction
    /// a valid approach can still have a local incoming road absent from the next
    /// pack. A point on the shared geometry gives both stages the same incoming
    /// identity without manufacturing a connector or moving any rider waypoint.
    static func sharedHandoverPoints(_ anchors: [Coordinate], first: any RoadGraph,
                                     next: any RoadGraph, access: AccessPolicy,
                                     budget: ComputationBudget) throws -> [Coordinate] {
        var groups: [[Coordinate]] = []
        var seen = Set<String>()
        for anchor in anchors {
            var points: [Coordinate] = []
            let matches = try RoadMatcher(pack: next).matches(at: anchor, radius: 1,
                start: true, policy: access, limit: 64, budget: budget)
            for match in matches where next.accessCode(match.edge, forward: match.forward != false) == 0 {
                try budget.check()
                let line = next.polyline(match.edge)
                guard line.count >= 2 else { continue }
                let point: Coordinate
                if match.fraction < 0.001 || match.fraction > 0.999 {
                    let a = match.fraction < 0.5 ? line[0] : line[line.count-2]
                    let b = match.fraction < 0.5 ? line[1] : line[line.count-1]
                    var dx = b.longitude-a.longitude
                    if dx > 180 { dx -= 360 }; if dx < -180 { dx += 360 }
                    let lon = (a.longitude + dx/2 + 540).truncatingRemainder(dividingBy: 360)-180
                    point = .init(longitude: lon, latitude: (a.latitude+b.latitude)/2)
                } else { point = match.coordinate }
                let identity = next.identity(of: match.edge)
                let key = "\(identity):\(point.longitude):\(point.latitude)"
                guard seen.insert(key).inserted else { continue }
                let inFirst = try RoadMatcher(pack: first).matches(at: point, radius: 1,
                    start: false, policy: access, limit: 64, budget: budget)
                guard inFirst.contains(where: {
                    first.matches($0.edge, identities: [identity])
                        && first.accessCode($0.edge, forward: $0.forward != false) == 0
                }) else { continue }
                points.append(point)
            }
            if !points.isEmpty { groups.append(points) }
        }
        // Preserve the existing candidate bound and geographic diversification.
        var result: [Coordinate] = []
        for column in 0..<(groups.map(\.count).max() ?? 0) {
            for group in groups where column < group.count {
                result.append(group[column])
                if result.count == handoverCandidateLimit { return result }
            }
        }
        return result
    }

    /// A shared incoming road can be only a stub in the next pack. A cut at
    /// its end needs a legal onward exit; its mere presence is not continuity.
    static func canContinueForward(_ match: RoadMatch, graph: any RoadGraph, request: RoutingRequest) -> Bool {
        guard let forward = match.forward else { return false }
        let node = graph.endpoint(match.edge, from: !forward)
        if match.coordinate.distance(to: graph.coordinate(node: node)) >= 1 { return true }
        let incoming = graph.restrictionEdge(match.edge)
        for at in [node] + graph.coincidentSiblings(node) {
            for arc in graph.outgoing(at) {
                guard graph.restrictionEdge(arc.edge) != incoming, graph.distance(arc.edge) > 0.01 else { continue }
                let code = graph.accessCode(arc.edge, forward: arc.forward)
                let shortUnknown = request.profile.style != .cleanest && code == 1 && graph.distance(arc.edge) <= 100
                guard request.access.permits(code, isStart: false, isEnd: false) || shortUnknown else { continue }
                if graph.restrictionIndex.advance([], from: incoming,
                    to: graph.restrictionEdge(arc.edge), at: at) != nil { return true }
            }
        }
        return false
    }

    /// A generated border target is not a rider waypoint. If the previous
    /// junction already has the same incoming road in the next graph, hand over
    /// there instead of forcing a ride down the last road solely to reach a pin.
    /// The next search decides whether that road is useful for the onward ride.
    static func handoverBeforeFinalRoad(_ route: ComputedRoute, request: RoutingRequest,
                                       graph: any RoadGraph, nextGraph: any RoadGraph,
                                       budget: ComputationBudget) throws -> ComputedRoute {
        guard route.limit == nil, route.segments.count > 1 else { return route }
        let prefix = Array(route.segments.dropLast())
        guard let last = prefix.last, last.access == 0, let point = last.geometry.last,
              point.distance(to: route.start.coordinate) > 1 else { return route }
        let matches = try RoadMatcher(pack: nextGraph).matches(at: point, radius: 1, start: true,
            policy: request.access, limit: 64, budget: budget)
        guard matches.contains(where: { nextGraph.matches($0.edge, identities: [graph.identity(of: last.edge)]) && $0.forward == last.forward
                && canContinueForward($0, graph: nextGraph, request: request) }) else {
            return route
        }
        // Recover the legal prefix state from the already proved path. Never
        // truncate a via-way restriction into an unrestricted regional start.
        var active = request.options.arrival?.restrictions ?? request.options.arrivalRestrictions
        for i in prefix.indices.dropFirst() {
            if i & 255 == 0 { try budget.check() }
            let prior = prefix[i-1], segment = prefix[i]
            guard let advanced = graph.restrictionIndex.advance(active,
                from: graph.restrictionEdge(prior.edge), to: graph.restrictionEdge(segment.edge),
                at: graph.endpoint(segment.edge, from: segment.forward)) else { return route }
            active = advanced
        }
        guard active.isEmpty else { return route }
        let geometry = graph.polyline(last.edge)
        let length = zip(geometry, geometry.dropFirst()).reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        let end = RoadMatch(edge: last.edge, coordinate: point, distanceMeters: 0,
            alongMeters: last.forward ? length : 0, geometryMeters: length, forward: last.forward)
        var result = ComputedRoute(start: route.start, end: end, segments: prefix,
            distanceMeters: prefix.reduce(0) { $0+$1.meters }, searchCost: route.searchCost,
            poppedLabels: route.poppedLabels, arrivalRestrictions: active)
        result.searchSummary = "handover-before-final-road[\(route.searchSummary ?? "-")]"
        result.qualityUrbanBoxes = route.qualityUrbanBoxes
        result.maneuvers = NavigationCues.make(route: result, graph: graph, access: request.access,
                                             arrival: request.options.arrival)
        return result
    }

    /// Try a fresh continuation before charging the ordinary repeat penalty.
    /// Necessary access can still reuse a road if excluding it proves no path;
    /// both attempts share the existing window deadline and caller exclusions.
    static func routeAvoidingEarlierRoads(_ request: RoutingRequest, graph: any RoadGraph,
                                         compassStore: RoadCompassStore?, budget: ComputationBudget) throws -> ComputedRoute {
        let engine = RoutingEngine(pack: graph, compassStore: compassStore)
        guard request.profile.style == .dirt, !request.options.priorEdges.isEmpty else {
            return try engine.route(request, budget: budget)
        }
        var fresh = request
        fresh.options.avoidEdges.formUnion(request.options.priorEdges)
        do { return try engine.route(fresh, budget: budget) }
        catch RoutingFailure.noPath {
            try budget.check()
            return try engine.route(request, budget: budget)
        }
    }

    static func neighborMap(_ regions: [String], repository: PackRepository) throws -> [String:Set<String>] {
        let wanted = Set(regions)
        var map: [String:Set<String>] = [:]
        for id in regions {
            let present = try repository.seamNeighborIDs(id).intersection(wanted)
            map[id, default: []].formUnion(present)
            for neighbor in present { map[neighbor, default: []].insert(id) }
        }
        return map
    }

    static func containingRegion(_ point: Coordinate, regions: [String], repository: PackRepository,
                                 budget: ComputationBudget,
                                 prepared: PreparedGraphStore = PreparedGraphStore(),
                                 access: AccessPolicy = .init(), start: Bool = true) throws -> String {
        let ranked = regions.sorted { repository.graphBytes($0) < repository.graphBytes($1) }
        var contained: [String] = []
        for id in ranked {
            try budget.check()
            if try repository.planningEnvelope(id, budget: budget).contains(point) { contained.append(id) }
        }
        if contained.count == 1 { return contained[0] }
        // Boxes are only a shortlist. Overlap must be resolved by real road
        // matching, never by pack size or an arbitrary last-region fallback.
        var best: (region: String, distance: Double)?
        for id in contained.isEmpty ? ranked : contained {
            let graph = try prepared.indexed([id], repository: repository, budget: budget)
            let matches = try RoadMatcher(pack: graph).matches(at: point, radius: 2_000,
                start: start, policy: access, intent: nil, budget: budget)
            if let match = matches.min(by: { $0.distanceMeters < $1.distanceMeters }),
               best == nil || match.distanceMeters < best!.distance {
                best = (id, match.distanceMeters)
            }
        }
        guard let best else { throw RoutingFailure.noMatch }
        return best.region
    }

    static func sampledBox(_ pack: GraphPack) -> GeographicBox {
        sampledBox(pack as any RoadGraph, nodeCount: pack.nodeCount)
    }

    static func sampledBox(_ graph: any RoadGraph) -> GeographicBox {
        sampledBox(graph, nodeCount: graph.nodeCount)
    }

    static func sampledBox(_ graph: any RoadGraph, nodeCount: Int) -> GeographicBox {
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        let step = max(1, nodeCount / 4_000)
        for node in stride(from: 0, to: nodeCount, by: step) {
            let point = graph.coordinate(node: node)
            guard point.isValid else { continue }
            minLat = min(minLat, point.latitude)
            maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude)
            maxLon = max(maxLon, point.longitude)
        }
        return .init(minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon, name: nil)
    }

    static func handover(from shared: String, into next: String, from origin: Coordinate, toward dest: Coordinate,
                         repository: PackRepository) throws -> Coordinate {
        let candidates = try handoverCandidates(from: shared, into: next, from: origin,
                                                toward: dest, repository: repository)
        guard let best = candidates.first else { throw RoutingFailure.noPath }
        return best
    }

    static func handoverCandidates(from shared: String, into next: String, from origin: Coordinate,
                                   toward dest: Coordinate, repository: PackRepository,
                                   searchGraph: (any RoadGraph)? = nil,
                                   budget: ComputationBudget = .init(seconds: 120),
                                   access: AccessPolicy = .init()) throws -> [Coordinate] {
        let anchors = try repository.loadSeams(shared).neighbors[next]
            ?? repository.loadSeams(next).neighbors[shared]
            ?? []
        // Keep every seam row; water-like / stub demotion is a rank key, not an
        // exclude. Prefer seams in the *origin's* weak component of the search
        // window (not the graph-wide giant — NS+NB joins can make an NB-only
        // island the largest component) and in the next pack's giant.
        let stubFlags = try stubIslandFlags(
            origin: origin, shared: shared, next: next, anchors: anchors,
            repository: repository, searchGraph: searchGraph, budget: budget,
            access: access)
        let points = anchors.compactMap { row -> HandoverCandidate? in
            guard row.coordinate.count == 2 else { return nil }
            let point = Coordinate(longitude: row.coordinate[0], latitude: row.coordinate[1])
            guard point.isValid else { return nil }
            let flags = stubFlags[row.osmNodeId] ?? (true, true)
            return .init(
                coordinate: point,
                waterLike: isWaterLike(row.edge),
                stubOnSearch: flags.onSearch,
                stubOnNext: flags.onNext
            )
        }
        return pickHandoverCandidates(from: points, origin: origin, toward: dest,
                                      limit: handoverCandidateLimit)
    }

    /// Per-OSM-id stub flags for ranking. Search-side stub = not in the origin's
    /// weak component (aligns with hopLooksLive). Next-side stub = not in next
    /// pack giant (onward commitment).
    static func stubIslandFlags(origin: Coordinate, shared: String, next: String,
                                anchors: [SeamDocument.Anchor],
                                repository: PackRepository,
                                searchGraph: (any RoadGraph)?,
                                budget: ComputationBudget,
                                access: AccessPolicy) throws -> [String: (onSearch: Bool, onNext: Bool)] {
        let currentGraph: any RoadGraph
        if let searchGraph {
            currentGraph = searchGraph
        } else {
            currentGraph = try repository.open(shared, requireSeams: false, budget: budget).graph
        }
        let nextPack = try repository.open(next, requireSeams: false, budget: budget).graph
        let currentIds = WeakComponents.ids(in: currentGraph, allowUnknown: access.includesUnknownConnectivity)
        let nextIds = WeakComponents.ids(in: nextPack, allowUnknown: access.includesUnknownConnectivity)
        let originComponent = try originWeakComponent(
            origin: origin, graph: currentGraph, ids: currentIds, access: access, budget: budget)
            ?? giantComponentId(from: currentIds)
        let nextGiant = giantComponentId(from: nextIds)
        let wanted = Set(anchors.map(\.osmNodeId))
        guard !wanted.isEmpty else { return [:] }
        let currentNodes = osmNodeIndex(in: currentGraph, wanted: wanted)
        let nextNodes = osmNodeIndex(in: nextPack, wanted: wanted)
        var flags: [String: (onSearch: Bool, onNext: Bool)] = [:]
        for id in wanted {
            let onSearch = !(currentNodes[id].map { currentIds[$0] == originComponent } ?? false)
            let onNext = !(nextNodes[id].map { nextIds[$0] == nextGiant } ?? false)
            flags[id] = (onSearch, onNext)
        }
        return flags
    }

    /// Weak-component id of the best match at `origin`, when matching succeeds.
    static func originWeakComponent(origin: Coordinate, graph: any RoadGraph, ids: [Int],
                                    access: AccessPolicy, budget: ComputationBudget) throws -> Int? {
        let indexed: IndexedGraph
        if let warm = graph as? IndexedGraph {
            indexed = warm
        } else {
            indexed = try IndexedGraph(graph, budget: budget)
        }
        let matcher = RoadMatcher(pack: indexed)
        let matches = try matcher.matches(at: origin, radius: 2_000, start: true,
                                          policy: access, intent: nil, budget: budget)
        guard let match = matches.first else { return nil }
        return WeakComponents.of(match: match, pack: indexed, ids: ids)
    }

    static func giantComponentId(from ids: [Int]) -> Int {
        var sizes: [Int: Int] = [:]
        for id in ids { sizes[id, default: 0] += 1 }
        return sizes.max(by: { $0.value < $1.value })?.key ?? 0
    }

    static func osmNodeIndex(in pack: any RoadGraph, wanted: Set<String>) -> [String: Int] {
        var found: [String: Int] = [:]
        for n in 0..<pack.nodeCount {
            let id = String(pack.osmNodeID(n))
            if wanted.contains(id) { found[id] = n }
        }
        return found
    }

    /// Values are from `routing/lib/structure.js:isWaterCrossing`; timed
    /// crossings are included because published V4 packs can omit a ferry leaf.
    static func isWaterLike(_ edge: SeamDocument.EdgeProof) -> Bool {
        let leaf = edge.structureLeaf?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let timedFerry = edge.crossingSeconds.map { $0 > 0 } ?? false
        return timedFerry
            || leaf == "ferry"
            || ["ford", "low_water_crossing", "stepping_stones", "stream", "tidal"].contains(leaf)
    }

    /// Intermediate hops aim at the next pack's onward seam belt. The final hop
    /// still aims at the rider destination. Keeps Canada↔Canada westbound rides
    /// from poisoning Maritimes/QC handovers with a Rockies geodesic.
    ///
    /// When the onward belt is far beyond the *current* seam (Winnipeg/BC class
    /// at qc-s↔on-n aiming at on-n↔mb), rank against a capped aim just past the
    /// current belt so western vs eastern pins still differentiate.
    static let onwardAimCapMeters = 350_000.0

    static func chainLocalAim(
        windows: [[String]],
        stageIndex: Int,
        next: String,
        finalDestination: Coordinate,
        repository: PackRepository,
        currentShared: String? = nil
    ) throws -> Coordinate {
        let raw: Coordinate
        if stageIndex + 2 < windows.count, let following = windows[stageIndex + 2].last {
            let anchors = try repository.loadSeams(next).neighbors[following]
                ?? repository.loadSeams(following).neighbors[next]
                ?? []
            let points = anchors.compactMap { row -> Coordinate? in
                guard row.coordinate.count == 2 else { return nil }
                let point = Coordinate(longitude: row.coordinate[0], latitude: row.coordinate[1])
                return point.isValid ? point : nil
            }
            raw = centroid(of: points) ?? finalDestination
        } else {
            raw = finalDestination
        }
        guard let shared = currentShared else { return raw }
        let currentAnchors = try repository.loadSeams(shared).neighbors[next]
            ?? repository.loadSeams(next).neighbors[shared]
            ?? []
        let currentPoints = currentAnchors.compactMap { row -> Coordinate? in
            guard row.coordinate.count == 2 else { return nil }
            let point = Coordinate(longitude: row.coordinate[0], latitude: row.coordinate[1])
            return point.isValid ? point : nil
        }
        guard let belt = centroid(of: currentPoints) else { return raw }
        return cappedAim(from: belt, toward: raw, maxMeters: onwardAimCapMeters)
    }

    static func cappedAim(from belt: Coordinate, toward far: Coordinate, maxMeters: Double) -> Coordinate {
        let span = belt.distance(to: far)
        guard span > maxMeters, span > 0 else { return far }
        var lo = 0.0, hi = 1.0
        var best = far
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            let point = Coordinate(
                longitude: belt.longitude + (far.longitude - belt.longitude) * mid,
                latitude: belt.latitude + (far.latitude - belt.latitude) * mid
            )
            guard point.isValid else { break }
            best = point
            if belt.distance(to: point) > maxMeters { hi = mid } else { lo = mid }
        }
        return best
    }

    static func centroid(of points: [Coordinate]) -> Coordinate? {
        guard !points.isEmpty else { return nil }
        let lon = points.map(\.longitude).reduce(0, +) / Double(points.count)
        let lat = points.map(\.latitude).reduce(0, +) / Double(points.count)
        let point = Coordinate(longitude: lon, latitude: lat)
        return point.isValid ? point : nil
    }

    /// Corridor-ranked, longitude-diversified seam pins. Must stay O(n):
    /// subregion pairs can retain tens of thousands of legal proofs, and an
    /// all-pairs spacing scan on that set blows the wall clock before search.
    /// Geographic "best" alone is not enough — overlap stubs can look perfect
    /// on detour while remaining unreachable in one half, so callers try
    /// several diversified pins. Rank order: land before water-like, then
    /// giant-component before stub-island, then interquartile seam belt before
    /// anti-progress lon fringe (replaces NB/ME lon gate), then detour.
    static func pickHandoverCandidates(from points: [Coordinate], origin: Coordinate,
                                       toward dest: Coordinate, limit: Int) -> [Coordinate] {
        pickHandoverCandidates(from: points.map {
            .init(coordinate: $0, waterLike: false, stubOnSearch: false, stubOnNext: false)
        }, origin: origin, toward: dest, limit: limit)
    }

    /// Pins on the longitude-IQR fringe *opposite* travel toward `dest` are
    /// coastal/island or stub fringes (Passamaquoddy when riding west). The
    /// progress-side fringe stays eligible — western qc-s↔on-n pins must
    /// remain available when the next aim is on-n↔mb (Winnipeg/BC class).
    static func seamFringeFlags(for points: [HandoverCandidate], toward dest: Coordinate) -> [Bool] {
        guard points.count >= 8 else { return Array(repeating: false, count: points.count) }
        let lons = points.map(\.coordinate.longitude).sorted()
        let q1Lon = lons[lons.count / 4]
        let q3Lon = lons[(3 * lons.count) / 4]
        let mid = (q1Lon + q3Lon) / 2
        return points.map { point in
            let lon = point.coordinate.longitude
            if lon > q3Lon && dest.longitude <= mid { return true }
            if lon < q1Lon && dest.longitude >= mid { return true }
            return false
        }
    }

    static func pickHandoverCandidates(from points: [HandoverCandidate], origin: Coordinate,
                                       toward dest: Coordinate, limit: Int) -> [Coordinate] {
        guard !points.isEmpty, limit > 0 else { return [] }
        let direct = max(1, origin.distance(to: dest))
        let fringe = seamFringeFlags(for: points, toward: dest)
        let ranked = zip(points, fringe).map { point, isFringe -> (
            score: Double, point: Coordinate, waterLike: Bool,
            stubOnSearch: Bool, stubOnNext: Bool, fringe: Bool
        ) in
            let via = origin.distance(to: point.coordinate) + point.coordinate.distance(to: dest)
            return (via / direct, point.coordinate, point.waterLike,
                    point.stubOnSearch, point.stubOnNext, isFringe)
        }.sorted(by: handoverRankLessThan)

        // Keep the best pin per geographic cell so stub clusters cannot crowd
        // out usable corridor pins. A longitude-only grid collapses dense
        // north–south belts (co↔ks ~0.07° lon; nb↔ns only 3 lon cells across
        // 2°). Use a coarse 2D cell so both axes diversify.
        var byCell: [Int:(
            score: Double, point: Coordinate, waterLike: Bool,
            stubOnSearch: Bool, stubOnNext: Bool, fringe: Bool
        )] = [:]
        for row in ranked {
            let lonCell = Int((row.point.longitude * 5.0).rounded(.towardZero))
            let latCell = Int((row.point.latitude * 5.0).rounded(.towardZero))
            let cell = lonCell &* 10_000 &+ latCell
            if byCell[cell] == nil { byCell[cell] = row }
        }
        let diversified = byCell.values.sorted(by: handoverRankLessThan).map(\.point)
        var spaced: [Coordinate] = []
        for point in diversified {
            if spaced.contains(where: { $0.distance(to: point) < 8_000 }) { continue }
            spaced.append(point)
            if spaced.count >= max(limit * 2, limit) { break }
        }
        // Geodesic-best cells on a huge north cut are often overlap stubs;
        // connected highway pins sit farther east. Interleave front and mid
        // only on long corridors so short cross-half rides keep nearest pins.
        var ordered: [Coordinate] = spaced
        if origin.distance(to: dest) > 500_000, spaced.count > 3 {
            let mid = spaced.count / 2
            var interleaved: [Coordinate] = []
            var lo = 0, hi = mid
            while interleaved.count < spaced.count {
                if lo < mid { interleaved.append(spaced[lo]); lo += 1 }
                if hi < spaced.count { interleaved.append(spaced[hi]); hi += 1 }
            }
            ordered = interleaved
        }
        // A short border can fit in one cell. Diversity must not erase the
        // other topology choices when its first arrival cannot continue.
        // Keep the existing bound and try these only after the diverse choices.
        if ordered.count < limit {
            for row in ranked where !ordered.contains(row.point) {
                ordered.append(row.point)
                if ordered.count >= limit { break }
            }
        }
        return Array(ordered.prefix(limit))
    }

    static func pickHandover(from points: [Coordinate], origin: Coordinate, toward dest: Coordinate) -> Coordinate? {
        pickHandoverCandidates(from: points, origin: origin, toward: dest, limit: 1).first
    }

    /// Shared sort key: land → window-giant → next-giant → belt → detour.
    /// Split search/next stubs so Providence window-live / next-stub pins still
    /// outrank coastal islands that fail hopLooksLive in [ns,nb].
    static func handoverRankLessThan(
        _ a: (score: Double, point: Coordinate, waterLike: Bool,
              stubOnSearch: Bool, stubOnNext: Bool, fringe: Bool),
        _ b: (score: Double, point: Coordinate, waterLike: Bool,
              stubOnSearch: Bool, stubOnNext: Bool, fringe: Bool)
    ) -> Bool {
        if a.waterLike != b.waterLike { return !a.waterLike }
        if a.stubOnSearch != b.stubOnSearch { return !a.stubOnSearch }
        if a.stubOnNext != b.stubOnNext { return !a.stubOnNext }
        if a.fringe != b.fringe { return !a.fringe }
        return a.score < b.score
    }

    static func openWindow(_ regions: [String], repository: PackRepository,
                           budget: ComputationBudget,
                           prepared: PreparedGraphStore = PreparedGraphStore()) throws -> IndexedGraph {
        try prepared.indexed(regions, repository: repository, budget: budget)
    }

    static func routeWindow(_ regions: [String], request: RoutingRequest, repository: PackRepository,
                            budget: ComputationBudget,
                            prepared: PreparedGraphStore = PreparedGraphStore(),
                            compassStore: RoadCompassStore? = nil) throws -> ComputedRoute {
        let indexed = try openWindow(regions, repository: repository, budget: budget, prepared: prepared)
        return try RoutingEngine(pack: indexed, compassStore: compassStore).route(request, budget: budget)
    }

    /// Directed connectivity on both halves before a full Balanced/Dirt search.
    /// Never rules out a pin the search could still connect.
    static func seamPinLooksLive(_ hop: Coordinate, origin: Coordinate, destination: Coordinate,
                                 first: IndexedGraph, second: IndexedGraph,
                                 request: RoutingRequest, budget: ComputationBudget,
                                 reach0: inout EndpointReachability?,
                                 reach1: inout EndpointReachability?) throws -> Bool {
        try hopLooksLive(hop, origin: origin, graph: first, request: request, budget: budget, reach: &reach0)
            && hopLooksLive(destination, origin: hop, graph: second, request: request, budget: budget, reach: &reach1)
    }

    static func hopLooksLive(_ hop: Coordinate, origin: Coordinate, graph: IndexedGraph,
                             request: RoutingRequest, budget: ComputationBudget,
                             reach: inout EndpointReachability?) throws -> Bool {
        let matcher = RoadMatcher(pack: graph)
        let radius = min(2000, max(80, request.matchRadiusMeters))
        let intent = origin.bearing(to: hop) * 180 / .pi
        let starts = try matcher.matches(at: origin, radius: radius, start: true,
                                         policy: request.access, intent: intent, budget: budget)
        let ends = try matcher.matches(at: hop, radius: radius, start: false,
                                       policy: request.access, intent: intent + 180, budget: budget)
        guard !starts.isEmpty, !ends.isEmpty else { return false }
        // Clean cannot use the short uncertain-access connectors permitted by
        // Dirt/Balanced. Do not spend an entire window approaching a border road
        // that is connected only through one of those uncertain roads.
        let clean = request.profile.style == .cleanest
        let components = WeakComponents.ids(in: graph,
            allowUnknown: !clean && request.access.includesUnknownConnectivity)
        let checker = try reach ?? EndpointReachability(graph: graph, budget: budget) { edge in
            !clean || graph.accessCode(edge, forward: true) == 0 || graph.accessCode(edge, forward: false) == 0
        }
        reach = checker
        // Intent ranks matches, but the first direction can lead into a dead
        // end or a clipped overlap. This is a necessary-only preflight: reject
        // only when every candidate pair the router can try is disconnected.
        for start in starts {
            for end in ends where WeakComponents.of(match: start, pack: graph, ids: components)
                == WeakComponents.of(match: end, pack: graph, ids: components) {
                if try checker.mayConnect(start: start, end: end, budget: budget) { return true }
            }
        }
        return false
    }

    static func knownDirtMeters(_ route: ComputedRoute) -> Double {
        route.segments.filter { $0.structure != "ferry" && ($0.surface == .gravel || $0.surface == .loose) }
            .reduce(0) { $0 + $1.meters }
    }

    static func stitch(_ parts: [ComputedRoute], windows: [[String]]) throws -> ComputedRoute {
        // Joining stages must never erase an incomplete search outcome.
        if let limit = parts.compactMap(\.limit).first { throw RoutingFailure.resourceLimit(limit) }
        guard let first = parts.first, let last = parts.last else {
            return ComputedRoute(start: RoadMatch(edge: 0, coordinate: .init(longitude: 0, latitude: 0),
                                                  distanceMeters: 0, alongMeters: 0, geometryMeters: 0),
                                 end: RoadMatch(edge: 0, coordinate: .init(longitude: 0, latitude: 0),
                                                distanceMeters: 0, alongMeters: 0, geometryMeters: 0),
                                 segments: [], distanceMeters: 0, searchCost: 0, poppedLabels: 0,
                                 arrivalRestrictions: [])
        }
        // Each stage is clipped at its actual endpoint. Two adjacent pieces of
        // the same road can be disjoint continuations, or a real reversal. Keep
        // both: dropping the second piece loses distance and hides backtracking.
        let segments = parts.flatMap(\.segments)
        var combined = ComputedRoute(start: first.start, end: last.end, segments: segments,
                                     distanceMeters: segments.reduce(0) { $0 + $1.meters },
                                     searchCost: parts.reduce(0) { $0 + $1.searchCost },
                                     poppedLabels: parts.reduce(0) { $0 + $1.poppedLabels },
                                     arrivalRestrictions: last.arrivalRestrictions)
        let labels = zip(windows, parts).map { window, part in
            "stage:\(window.joined(separator: "+"))[\(part.searchSummary ?? "-")]"
        }
        combined.searchSummary = labels.joined(separator: ",")
        combined.qualityUrbanBoxes = parts.flatMap(\.qualityUrbanBoxes)
        return combined
    }
}
