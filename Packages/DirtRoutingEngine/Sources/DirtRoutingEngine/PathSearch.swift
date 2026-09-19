import Foundation

public struct SearchArrival: Sendable {
    public let edge: Int
    public let coordinate: Coordinate
    public let restrictions: [RestrictionProgress]
    public init(edge: Int,coordinate: Coordinate,restrictions: [RestrictionProgress]) {
        self.edge = edge; self.coordinate = coordinate; self.restrictions = restrictions
    }
}

public struct SearchOptions: Sendable {
    /// Local graph junctions already ridden by an earlier composed section.
    /// Scoped to the same graph; never carried as indices across regional windows.
    var avoidCircuitNodes: Set<Int> = []
    /// Recreational candidate generation only. Ordinary and Loop searches retain
    /// their legal turn-around behavior; final composition also checks all nodes.
    var preventLocalCircuits = false
    public var arrival: SearchArrival?
    public var precedingMeters = 0.0
    public var precedingDirtMeters = 0.0
    public var objective: SearchObjective = .profile
    public var maximumMeters: Double = .infinity
    public var corridorMeters: Double = .infinity
    public var pavedOnly = false
    public var cityWall = true
    public var avoidEdges: Set<String> = []
    public var priorEdges: Set<String> = []
    /// Loop return: outbound edges are expensive, not forbidden.
    public var repeatEdges: Set<String> = []
    public var repeatFactor: Double = 16
    /// Extra road-progress budget so a loop can spend leftover target distance
    /// wandering. Zero (default) keeps ordinary A→B extra meters identical.
    public var loopSlackMeters: Double = 0
    /// Loop hard extent: nil (default) applies no cap, so ordinary A→B search is
    /// unchanged. When set, no explored road may sit farther from `extentCenter`
    /// than `maxExtentMeters` — the rider's far pin is the outer edge of the
    /// ride, not merely what the search aims at. Lateral wander inside that
    /// radius is unaffected; only the radial "past the pin" case is rejected.
    /// The endpoint's own attached edge is exempt so the pin itself, wherever
    /// it falls along a graph edge, always stays reachable.
    public var extentCenter: Coordinate? = nil
    public var maxExtentMeters: Double = .infinity
    public var penalizedDirtEdges: Set<String> = []
    public var backtrackFactor: Double = 4
    public var seed: UInt64 = 0
    public var varietyEnabled = true
    /// Explore another coherent riding area before falling back to ordinary routing.
    public var composeDirtRide = false
    /// Generated regional cuts continue the incoming direction, just as one
    /// uninterrupted search would. Rider waypoints retain ordinary turn-around behavior.
    var continuationForward: Bool?
    public var arrivalEdgeID: String?
    public var arrivalRestrictions: [RestrictionProgress] = []
    /// Extra legal destinations for a nearest-reachable search. Corridor and
    /// highway-pin tests still use the primary `end` match.
    public var additionalEnds: [RoadMatch] = []
    /// Remaining road meters to B from each graph node. When present, JS
    /// disables the hard progress gate and taxes walking away from B instead.
    public var roadRemaining: [Double]? = nil
    /// When true, skip the geodesic progress-regression gate (fuel feelers and
    /// diagnostic shadows). Personality costs still apply.
    public var disableProgressRegression = false
    /// Reverse-Dijkstra remaining cap. Infinity (default) visits every node, so
    /// short matrix routes stay identical. Long internal stages pass a few
    /// hundred kilometres so unused far-side provinces stay unexpanded.
    public var compassMaxRemaining: Double = .infinity
    /// Fuel hops: blend a dirt-scaled geodesic pull so pavement search still
    /// prefers progress toward the hop end without drowning the dirt-rate cost
    /// (see `heapCost` — pull is 2× dirtWeight × geoKm, not raw geoKm).
    public var fuelGoalPull = false
    /// Fuel sweep: keep expanding after the first goal and reconstruct every
    /// pump (and the destination) the search actually reached inside the cap.
    public var collectEveryGoal = false
    /// Optional per-search reject/time profile. Filled by the search; never read
    /// for routing decisions.
    public var profile: SearchProfile? = nil
    /// Diagnostic totals shared by every search of one request. The search never reads it.
    public var counter: SearchCounter? = nil
    /// Set when the search turns a road away at its corridor or progress limit.
    var boundary: SearchBoundary? = nil
    public init() {}
}

/// Per-search expansion profile for fuel hop diagnostics. Recording only.
public final class SearchProfile: @unchecked Sendable {
    public var pops = 0
    public var labels = 0
    public var elapsedMs = 0.0
    public var regressionRejects = 0
    public var corridorRejects = 0
    public var cityWallRejects = 0
    public var meterRejects = 0
    public var limit: String?
    /// Routes reconstructed for every goal when `collectEveryGoal` is set.
    public var collectedRoutes: [ComputedRoute] = []
    public init() {}
    public var summary: String {
        "pops=\(pops) labels=\(labels) ms=\(Int(elapsedMs.rounded())) " +
            "regReject=\(regressionRejects) corrReject=\(corridorRejects) " +
            "wallReject=\(cityWallRejects) meterReject=\(meterRejects)" +
            (limit.map { " limit=\($0)" } ?? "")
    }
}

/// Whether a search turned any road away because of its corridor or its progress limit,
/// the only rules that depend on corridor width. A search that never did would repeat
/// exactly at any wider corridor.
final class SearchBoundary: @unchecked Sendable {
    var touched = false
}

public struct RouteSegment: Sendable {
    public let edge: Int
    public let edgeID: String
    public let forward: Bool
    public let meters: Double
    public let surface: Surface
    public let surfaceLeaf: String
    public let roadClass: String
    public let structure: String
    public let access: UInt8
    public let geometry: [Coordinate]
}

public struct ComputedRoute: Sendable {
    public var maneuvers: [NavigationCue] = []
    public let start: RoadMatch
    public let end: RoadMatch
    public let segments: [RouteSegment]
    public let distanceMeters: Double
    public let searchCost: Double
    public let poppedLabels: Int
    public var limit: String?
    public var searchSummary: String?
    public let arrivalRestrictions: [RestrictionProgress]
    func reportingLimit(_ reason: String?) -> Self {
        var copy = self
        copy.limit = reason ?? limit
        return copy
    }
    public var geometry: [Coordinate] {
        var points: [Coordinate] = []
        for segment in segments {
            for p in segment.geometry where points.last != p { points.append(p) }
        }
        return points
    }
    /// The same roads in the opposite direction. A confined loop uses this
    /// when the return search cannot finish; the repeated metres stay honest.
    public func reversed() -> ComputedRoute {
        let flipped = segments.reversed().map { segment in
            RouteSegment(edge: segment.edge, edgeID: segment.edgeID, forward: !segment.forward,
                         meters: segment.meters, surface: segment.surface, surfaceLeaf: segment.surfaceLeaf,
                         roadClass: segment.roadClass, structure: segment.structure, access: segment.access,
                         geometry: segment.geometry.reversed())
        }
        return ComputedRoute(start: end, end: start, segments: Array(flipped),
                             distanceMeters: distanceMeters, searchCost: searchCost,
                             poppedLabels: poppedLabels, arrivalRestrictions: [])
    }
}

/// A label the fog-of-war distance cutoff blocked from expanding further.
public struct FrontierSample: Sendable {
    public let coordinate: Coordinate
    public let meters: Double
    public let node: Int
    /// Road-compass remaining to the search destination when available.
    public let remainingToDestination: Double
}

/// Personality search that either reaches the destination inside the distance
/// budget or reports the frontier at the cutoff for fuel/distance chaining.
public enum BoundedSearchResult: Sendable {
    case reached(ComputedRoute)
    case stoppedAtBudget([FrontierSample])
}

public struct PathSearch: Sendable {
    let pack: any RoadGraph
    public init(pack: any RoadGraph) { self.pack = pack }
    struct State: Hashable {
        let node: Int
        let incoming: Int
        let restrictions: [RestrictionProgress]
        let bucket: Int
        var unknownConnectorMeters: Double = 0
        var simple: SimpleKey? { restrictions.isEmpty && unknownConnectorMeters == 0 ? SimpleKey(node: node, incoming: incoming, bucket: bucket) : nil }
    }
    struct SimpleKey: Hashable {
        let node: Int
        let incoming: Int
        let bucket: Int
    }
    struct Arc {
        let target: Int
        let edge: Int
        let forward: Bool
        let meters: Double
        let lower: Double
        let upper: Double
    }
    struct Label {
        let state: State
        let cost: Double
        let meters: Double
        let dirtMeters: Double
        /// Continuous dirt/gravel run ending at this label; resets on pavement.
        let contiguousDirtMeters: Double
        /// True once any contiguous dirt run reached the meaningful floor.
        let achievedMeaningfulDirt: Bool
        /// Paved meters accumulated since start (or since the last meaningful
        /// dirt completion). Drives deferred dirt-entry pressure.
        let pavedWithoutMeaningfulMeters: Double
        let peakProgress: Double
        let parent: Int?
        let arc: Arc?
    }
    struct Entry { let label: Int; let cost: Double }

    public func search(start: RoadMatch, end: RoadMatch, policy: ProfilePolicy,
                       access: AccessPolicy, options: SearchOptions = .init(),
                       budget: ComputationBudget = .init()) throws -> ComputedRoute {
        switch try boundedSearch(start: start, end: end, policy: policy, access: access,
                                 options: options, budget: budget) {
        case .reached(let route): return route
        case .stoppedAtBudget:
            throw RoutingFailure.noPath
        }
    }

    public func boundedSearch(start: RoadMatch, end: RoadMatch, policy: ProfilePolicy,
                              access: AccessPolicy, options: SearchOptions = .init(),
                              budget: ComputationBudget = .init()) throws -> BoundedSearchResult {
        try budget.check()
        let searchStarted = ContinuousClock.now
        guard start.edge >= 0, end.edge >= 0, start.edge < pack.edgeCount, end.edge < pack.edgeCount,
              start.coordinate.isValid, end.coordinate.isValid,
              options.maximumMeters >= 0, options.corridorMeters >= 0 else {
            throw RoutingFailure.invalidRequest("search endpoints or bounds")
        }
        let startNode = pack.nodeCount, endNode = startNode+1
        let sa = pack.endpoint(start.edge,from: true), sb = pack.endpoint(start.edge,from: false)
        let ea = pack.endpoint(end.edge,from: true), eb = pack.endpoint(end.edge,from: false)
        let startAlong = start.alongMeters
        let startLength = start.geometryMeters
        var virtual: [Int:[Arc]] = [:]
        // A destination match's direction only ranks which road the pin snaps to. Arrival
        // may use either legal direction of that road, as in JS find-path-v4.
        func add(_ source: Int, _ target: Int, _ edge: Int, _ forward: Bool, _ lower: Double, _ upper: Double) {
            if source == startNode, let required = start.forward, required != forward { return }
            let code = pack.accessCode(edge,forward: forward)
            guard [0,1,3,4].contains(code) else { return }
            virtual[source,default: []].append(.init(target: target,edge: edge,forward: forward,
                                                    meters: max(0,upper-lower),lower: lower,upper: upper))
        }
        add(startNode,sa,start.edge,false,0,startAlong)
        add(startNode,sb,start.edge,true,startAlong,startLength)
        func attachEnd(_ match: RoadMatch) {
            let a = pack.endpoint(match.edge,from: true), b = pack.endpoint(match.edge,from: false)
            add(a,endNode,match.edge,true,0,match.alongMeters)
            add(b,endNode,match.edge,false,match.alongMeters,match.geometryMeters)
            if start.edge == match.edge {
                add(startNode,endNode,start.edge,startAlong <= match.alongMeters,
                    min(startAlong,match.alongMeters),max(startAlong,match.alongMeters))
            }
        }
        attachEnd(end)
        for extra in options.additionalEnds { attachEnd(extra) }
        func point(_ n: Int) -> Coordinate { n == startNode ? start.coordinate : n == endNode ? end.coordinate : pack.coordinate(node: n) }
        let customerStart = try customerEdges(match: start,seeds: virtual[startNode] ?? [],reverse: false,
                                              enabled: access.startIsCustomer,budget: budget)
        let endSeeds = (virtual[ea] ?? []).filter { $0.target == endNode }.map {
            Arc(target: ea,edge: $0.edge,forward: $0.forward,meters: $0.meters,lower: $0.lower,upper: $0.upper)
        } + (virtual[eb] ?? []).filter { $0.target == endNode }.map {
            Arc(target: eb,edge: $0.edge,forward: $0.forward,meters: $0.meters,lower: $0.lower,upper: $0.upper)
        }
        let extraEndEdges = Set(options.additionalEnds.map(\.edge))
        let customerEnd = try customerEdges(match: end,seeds: endSeeds,reverse: true,
                                            enabled: access.endIsCustomer,budget: budget)
        if let arrival = options.arrival {
            guard arrival.edge == pack.restrictionEdge(start.edge), arrival.coordinate.distance(to: start.coordinate) < 0.1 else {
                throw RoutingFailure.invalidRequest("arrival state must stay at its matched road position")
            }
        }
        let resolvedArrival = options.arrival?.edge
            ?? options.arrivalEdgeID.flatMap { pack.edge(matching: [$0]).map(pack.restrictionEdge) }
            ?? -1
        let carriedRestrictions = options.arrival?.restrictions ?? options.arrivalRestrictions
        let initial = State(node: startNode,incoming: resolvedArrival,
                            restrictions: carriedRestrictions,bucket: 0)
        var labels = [Label(state: initial,cost: 0,meters: 0,dirtMeters: 0,contiguousDirtMeters: 0,
                            achievedMeaningfulDirt: false,pavedWithoutMeaningfulMeters: 0,
                            peakProgress: 0,parent: nil,arc: nil)]
        var bestSimple: [SimpleKey:Int] = [:]
        var bestFull: [State:Int] = [:]
        if let key = initial.simple { bestSimple[key] = 0 } else { bestFull[initial] = 0 }
        func bestIndex(_ state: State) -> Int? {
            if let key = state.simple { return bestSimple[key] }
            return bestFull[state]
        }
        func storeBest(_ state: State, _ index: Int) {
            if let key = state.simple { bestSimple[key] = index } else { bestFull[state] = index }
        }
        let compass = options.roadRemaining
        func remaining(of node: Int) -> Double {
            if node == endNode { return 0 }
            guard let compass else { return .infinity }
            if node == startNode {
                let viaA = remaining(of: sa) + startAlong
                let viaB = remaining(of: sb) + max(0, startLength - startAlong)
                return min(viaA, viaB)
            }
            guard node >= 0, node < compass.count else { return .infinity }
            return compass[node]
        }
        func heapCost(_ pathCost: Double, _ node: Int) -> Double {
            let geoKm = point(node).distance(to: end.coordinate) / 1000
            if options.objective == .distance {
                return pathCost + geoKm
            }
            let left = remaining(of: node)
            // Pavement dirt-rate (~0.02/km). Fuel goal pull must stay on this
            // scale — an unscaled geoKm term (~50× larger on long hops) stops
            // the flood by cancelling dirt-seeking and yields near-pavement
            // styleOk routes. 2× dirt-rate is enough progress bias to reach
            // the pump without pricing out a dirt detour.
            let dirtWeight = 0.02
            let fuelPull = options.fuelGoalPull ? geoKm * dirtWeight * 2 : 0
            if left.isFinite {
                if options.objective == .pavement {
                    let road = left / 1000 * dirtWeight
                    return pathCost + road + fuelPull
                }
                if policy.style == .cleanest, options.objective == .profile {
                    // Collector 0.82 × variety floor 0.96.
                    return pathCost + left / 1000 * 0.69
                }
            } else if options.fuelGoalPull, options.objective == .pavement {
                return pathCost + fuelPull
            }
            return pathCost
        }
        var heap = BinaryHeap<Entry> { $0.cost == $1.cost ? $0.label < $1.label : $0.cost < $1.cost }
        heap.push(.init(label: 0,cost: heapCost(0, startNode)))
        var goals: [Int] = [], pops = 0, limit: String?
        var frontierHits: [(label: Int, meters: Double, node: Int)] = []
        defer {
            options.counter?.recordSearch(pops: pops, labels: labels.count, since: searchStarted)
            if let profile = options.profile {
                profile.pops = pops
                profile.labels = labels.count
                let parts = searchStarted.duration(to: ContinuousClock.now).components
                profile.elapsedMs = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
                profile.limit = limit
            }
        }
        let startHighway = start.distanceMeters < 18 && ["motorway","trunk","arterial"].contains(ProfilePolicy.tier(pack.roadClass(start.edge)))
        let endHighway = end.distanceMeters < 18 && ["motorway","trunk","arterial"].contains(ProfilePolicy.tier(pack.roadClass(end.edge)))
        let resource = options.objective == .balancedResource
        let cores = UrbanCores.boxes(in: pack)
        let avoid = options.avoidEdges
        let prior = options.priorEdges
        let repeated = options.repeatEdges
        let penalized = options.penalizedDirtEdges
        let needIdentity = !avoid.isEmpty || !prior.isEmpty || !repeated.isEmpty || !penalized.isEmpty
        // Identity membership is constant for this request. Resolve it only for
        // roads actually visited, once per road rather than once per label.
        var memberships: [Int: UInt8] = [:]
        func membership(_ edge: Int) -> UInt8 {
            guard needIdentity else { return 0 }
            if let cached = memberships[edge] { return cached }
            let local = pack.edgeID(edge), stable = pack.identity(of: edge)
            func contains(_ set: Set<String>) -> Bool { set.contains(local) || set.contains(stable) }
            let value: UInt8 = (contains(avoid) ? 1 : 0) | (contains(prior) ? 2 : 0)
                | (contains(repeated) ? 4 : 0) | (contains(penalized) ? 8 : 0)
            memberships[edge] = value
            return value
        }
        let startRemaining = remaining(of: startNode)
        let useRoadProgress = compass != nil && startRemaining.isFinite && !startRemaining.isInfinite
            && options.objective != .distance && !options.disableProgressRegression
            && policy.style != .cleanest
        let regression = (options.objective == .distance || options.disableProgressRegression)
            ? Double.infinity
            : ProfilePolicy.progressRegressionMeters(
                style: policy.style, corridorMeters: options.corridorMeters,
                hasRoadCompass: compass != nil, wander: policy.wander)
        let backwardAllowance = policy.roadBackwardAllowanceMeters(startRemaining: startRemaining)
            + max(0, options.loopSlackMeters) * 0.3
        let extraBudget = policy.roadExtraMeters(startRemaining: startRemaining) + max(0, options.loopSlackMeters)
        search: while let entry = heap.pop() {
            if pops & 255 == 0 {
                do { try budget.check() }
                catch is CancellationError { throw CancellationError() }
                catch { limit = "time"; break }
            }
            let current = labels[entry.label]
            guard bestIndex(current.state) == entry.label else { continue }
            pops += 1
            if current.state.node == endNode {
                // A connector must exit onto a positive-length permitted road.
                guard current.state.unknownConnectorMeters == 0 else { continue }
                goals.append(entry.label)
                if resource {
                    if policy.style == .balanced && abs((options.precedingDirtMeters+current.dirtMeters)/max(1,options.precedingMeters+current.meters)-0.5) <= 0.005 { break }
                    continue
                }
                // Distance multi-goal (first pump) stops at the first, shortest
                // arrival. A style sweep keeps every goal so the fan can choose.
                if options.collectEveryGoal || (options.objective != .distance && !options.additionalEnds.isEmpty) {
                    continue
                }
                break
            }
            var arcs = virtual[current.state.node] ?? []
            if current.state.node < pack.nodeCount {
                for a in pack.outgoing(current.state.node) {
                    let meters = a.meters.isFinite ? a.meters : pack.distance(a.edge)
                    arcs.append(.init(target: a.target,edge: a.edge,forward: a.forward,
                                      meters: meters,lower: 0,upper: meters))
                }
                for sibling in pack.coincidentSiblings(current.state.node) where sibling != current.state.node && sibling < pack.nodeCount {
                    let state = State(node: sibling,incoming: current.state.incoming,
                                      restrictions: current.state.restrictions,bucket: current.state.bucket,
                                      unknownConnectorMeters: current.state.unknownConnectorMeters)
                    if let previous = bestIndex(state), labels[previous].cost <= current.cost { continue }
                    if labels.count >= budget.maximumLabels { limit = "labels"; break search }
                    let index = labels.count
                    labels.append(.init(state: state,cost: current.cost,meters: current.meters,
                                        dirtMeters: current.dirtMeters,
                                        contiguousDirtMeters: current.contiguousDirtMeters,
                                        achievedMeaningfulDirt: current.achievedMeaningfulDirt,
                                        pavedWithoutMeaningfulMeters: current.pavedWithoutMeaningfulMeters,
                                        peakProgress: current.peakProgress,
                                        parent: entry.label,arc: nil))
                    storeBest(state, index)
                    heap.push(.init(label: index,cost: heapCost(current.cost, sibling)))
                }
            }
            for arc in arcs {
                let e = arc.edge
                if !options.avoidCircuitNodes.isEmpty, arc.target != endNode, options.avoidCircuitNodes.contains(arc.target) { continue }
                let physicalEdge = pack.restrictionEdge(e)
                if let previous = current.arc, previous.edge == e, current.state.node < pack.nodeCount { continue }
                if !avoid.isEmpty && membership(e) & 1 != 0 {
                    let leavingPin = current.state.node == startNode
                    let arrivingPin = arc.target == endNode
                    if !leavingPin && !arrivingPin { continue }
                }
                let isStart = e == start.edge || customerStart.contains(e)
                let isEnd = e == end.edge || extraEndEdges.contains(e) || customerEnd.contains(e)
                let accessCode = pack.accessCode(e,forward: arc.forward)
                var unknownConnectorMeters = current.state.unknownConnectorMeters
                if !access.allowUnknown && policy.style != .cleanest && accessCode == 1 {
                    if unknownConnectorMeters == 0 {
                        // Look through zero-length virtual/coincident junctions. A
                        // pin, customer approach, or another uncertain section is
                        // not proof of a permitted entry to this connector.
                        var cursor: Int? = entry.label
                        var permittedEntry = false
                        while let i = cursor {
                            if let previous = labels[i].arc, previous.meters > 0.01 {
                                permittedEntry = pack.accessCode(previous.edge, forward: previous.forward) == 0
                                break
                            }
                            cursor = labels[i].parent
                        }
                        guard permittedEntry else { continue }
                    }
                    unknownConnectorMeters += arc.meters
                    guard unknownConnectorMeters <= 100 else { continue }
                } else {
                    guard access.permits(accessCode,isStart: isStart,isEnd: isEnd) else { continue }
                    if unknownConnectorMeters > 0, arc.meters > 0.01 {
                        guard accessCode == 0 else { continue }
                        unknownConnectorMeters = 0
                    }
                }
                if policy.style == .cleanest && !policy.cleanEligible(pack: pack,edge: e,
                    endpoint: isStart || isEnd,pavedOnly: options.pavedOnly) { continue }
                let nextRestrictions: [RestrictionProgress]
                if current.state.node == startNode { nextRestrictions = current.state.restrictions }
                else if physicalEdge == current.state.incoming && arc.meters <= 0.01 { nextRestrictions = current.state.restrictions }
                else {
                    guard let state = pack.restrictionIndex.advance(current.state.restrictions,from: current.state.incoming,
                                                                   to: physicalEdge,at: current.state.node) else { continue }
                    nextRestrictions = state
                }
                do {
                    var ancestor: Int? = entry.label, depth = 0, overlaps = false
                    while let a = ancestor, depth < 128 {
                        if options.preventLocalCircuits, arc.meters > 0.01,
                           labels[a].state.node == arc.target { overlaps = true; break }
                        if let previous = labels[a].arc, labels[a].state.incoming == physicalEdge,
                           min(previous.upper,arc.upper)-max(previous.lower,arc.lower) > 0.5 {
                            overlaps = true; break
                        }
                        ancestor = labels[a].parent; depth += 1
                    }
                    if overlaps { continue }
                }
                let meters = current.meters+arc.meters
                if meters > options.maximumMeters+0.01 {
                    if options.maximumMeters.isFinite {
                        frontierHits.append((entry.label, current.meters, current.state.node))
                        options.profile?.meterRejects += 1
                    }
                    continue
                }
                let fromPoint = point(current.state.node), toPoint = point(arc.target)
                if let center = options.extentCenter, options.maxExtentMeters.isFinite,
                   !isStart, !isEnd, toPoint.distance(to: center) > options.maxExtentMeters {
                    options.boundary?.touched = true
                    options.profile?.corridorRejects += 1
                    continue
                }
                let left = remaining(of: arc.target)
                let progress: Double
                if useRoadProgress && left.isFinite {
                    progress = startRemaining - left
                } else {
                    progress = RouteQuality.progress(toPoint, start.coordinate, end.coordinate)
                }
                if useRoadProgress && left.isFinite {
                    if current.peakProgress - progress > backwardAllowance {
                        options.boundary?.touched = true
                        options.profile?.regressionRejects += 1
                        continue
                    }
                    let extra = meters - max(0, progress)
                    if extra > extraBudget {
                        options.boundary?.touched = true
                        options.profile?.corridorRejects += 1
                        continue
                    }
                } else {
                    if options.corridorMeters.isFinite && abs(toPoint.crossTrack(from: start.coordinate,to: end.coordinate)) > options.corridorMeters {
                        options.boundary?.touched = true
                        options.profile?.corridorRejects += 1
                        continue
                    }
                    if current.peakProgress - progress > regression {
                        options.boundary?.touched = true
                        options.profile?.regressionRejects += 1
                        continue
                    }
                }
                let peak = max(current.peakProgress, progress)
                let urban = cores.contains {
                    !$0.contains(start.coordinate) && !$0.contains(end.coordinate) && $0.intersects(fromPoint,toPoint)
                }
                if urban && options.cityWall {
                    options.profile?.cityWallRejects += 1
                    continue
                }
                let family = ProfilePolicy.family(pack.surfaceLeaf(e))
                let isDirt = family == .gravel || family == .loose
                let dirt = current.dirtMeters + (isDirt && pack.structure(e) != "ferry" ? arc.meters : 0)
                let contiguousDirt: Double
                var clawback = 0.0
                let minDirt = policy.minimumMeaningfulDirtMeters.isFinite
                    ? max(0, policy.minimumMeaningfulDirtMeters) : 1_000
                let hopSpan = options.maximumMeters.isFinite
                    ? options.maximumMeters
                    : start.coordinate.distance(to: end.coordinate)
                var achievedMeaningful = current.achievedMeaningfulDirt
                var pavedWithoutMeaningful = current.pavedWithoutMeaningfulMeters
                if pack.structure(e) == "ferry" {
                    // Ferry breaks continuity; short dirt already taxed per arc.
                    if current.contiguousDirtMeters > 0 && current.contiguousDirtMeters < minDirt {
                        clawback += policy.shortDirtLeaveAbortCost(
                            contiguousDirtMeters: current.contiguousDirtMeters,
                            objective: options.objective)
                    }
                    contiguousDirt = 0
                } else if isDirt {
                    contiguousDirt = current.contiguousDirtMeters + arc.meters
                    // Tax short dirt immediately so cheap nibbles cannot dominate
                    // paved alternatives before a leave-clawback would fire.
                    if current.contiguousDirtMeters < minDirt {
                        let taxable = min(arc.meters, max(0, minDirt - current.contiguousDirtMeters))
                        clawback = policy.shortDirtClawback(contiguousDirtMeters: taxable,
                                                           objective: options.objective)
                    }
                    // Entering a new dirt run (paved→dirt) costs a transition so
                    // many separate >1 km grabs lose to one connected corridor.
                    // Scale by hop span so long fuel/A→B legs are not starved
                    // of dirt by a flat per-enter constant (floored at half).
                    if current.contiguousDirtMeters <= 0 {
                        clawback += policy.dirtEnterTransitionCost(
                            objective: options.objective, hopMeters: hopSpan)
                    }
                    if contiguousDirt >= minDirt {
                        achievedMeaningful = true
                        pavedWithoutMeaningful = 0
                    }
                } else {
                    if current.contiguousDirtMeters > 0 {
                        clawback += policy.shortDirtLeaveAbortCost(
                            contiguousDirtMeters: current.contiguousDirtMeters,
                            objective: options.objective)
                    }
                    contiguousDirt = 0
                    if !achievedMeaningful {
                        let before = pavedWithoutMeaningful
                        pavedWithoutMeaningful += arc.meters
                        clawback += policy.deferredDirtEntryCost(
                            pavedWithoutMeaningfulMeters: pavedWithoutMeaningful,
                            objective: options.objective)
                            - policy.deferredDirtEntryCost(
                                pavedWithoutMeaningfulMeters: before,
                                objective: options.objective)
                    }
                }
                let bucket = resource ? min(19,max(0,Int((options.precedingDirtMeters+dirt)/max(1,options.precedingMeters+meters)*20))) : 0
                let previousTier = current.state.incoming >= 0 && current.state.incoming < pack.edgeCount
                    ? ProfilePolicy.tier(pack.roadClass(current.state.incoming)) : nil
                let roadMembership = membership(e)
                let penalizedDirt = roadMembership & 8 != 0
                var step = resource ? arc.meters : policy.step(pack: pack,edge: e,meters: arc.meters,objective: options.objective,
                    from: fromPoint,to: toPoint,start: start.coordinate,end: end.coordinate,startOnHighway: startHighway,
                    endOnHighway: endHighway,penalizedDirt: penalizedDirt,previousTier: previousTier,
                    applyGeodesicPull: compass == nil,
                    riddenMetersBeforeArc: current.meters,
                    achievedMeaningfulDirt: current.achievedMeaningfulDirt)
                step += clawback
                if !resource {
                    // Geodesic early-leg away, even when road compass is active —
                    // paved U-dips can keep remaining-to-B flat while walking off
                    // the pin with no dirt payoff.
                    step += policy.earlyOpeningAwayCost(
                        from: fromPoint, to: toPoint, end: end.coordinate,
                        riddenMetersBeforeArc: current.meters,
                        achievedMeaningfulDirt: current.achievedMeaningfulDirt,
                        onDirt: isDirt,
                        objective: options.objective)
                }
                if compass != nil, options.objective != .distance, options.objective != .balancedResource {
                    step += policy.approachAway(fromRemaining: remaining(of: current.state.node),
                                                toRemaining: remaining(of: arc.target),
                                                startRemaining: startRemaining, objective: options.objective)
                    step += policy.crossTrackExtra(to: toPoint, start: start.coordinate, end: end.coordinate, meters: arc.meters)
                }
                if options.varietyEnabled && options.objective != .distance {
                    step *= RouteVariety.multiplier(seed: options.seed, edge: e)
                }
                if urban { step *= policy.style == .cleanest ? (policy.avoidMajorHighways ? 10 : 2) : 120 }
                if roadMembership & 2 != 0 { step *= max(1,options.backtrackFactor) }
                if roadMembership & 4 != 0 { step *= max(1,options.repeatFactor) }
                let cost = current.cost+step
                guard cost.isFinite, step >= 0 else { throw RoutingFailure.invalidPack("nonfinite search cost") }
                // Under a finite tank/fog cap, a cheap short label must not dominate
                // a longer dirt label at the same node — otherwise personality
                // never reaches the pump inside maximumMeters (Yarmouth fuel).
                // Uncapped searches keep a single bucket and stay byte-identical.
                let bandCount = 8
                let banded = !resource && options.maximumMeters.isFinite && options.maximumMeters > 0
                let band = banded
                    ? min(bandCount, max(0, Int(meters / (options.maximumMeters / Double(bandCount)))))
                    : bucket
                let state = State(node: arc.target,incoming: physicalEdge,restrictions: nextRestrictions,bucket: band,
                                  unknownConnectorMeters: unknownConnectorMeters)
                if banded {
                    var dominated = false
                    for b in 0...band {
                        let probe = State(node: arc.target,incoming: physicalEdge,
                                          restrictions: nextRestrictions,bucket: b,unknownConnectorMeters: unknownConnectorMeters)
                        if let previous = bestIndex(probe), labels[previous].cost <= cost {
                            dominated = true; break
                        }
                    }
                    if dominated { continue }
                } else if let previous = bestIndex(state), labels[previous].cost <= cost {
                    continue
                }
                if labels.count >= budget.maximumLabels { limit = "labels"; break search }
                let index = labels.count
                labels.append(.init(state: state,cost: cost,meters: meters,dirtMeters: dirt,
                                    contiguousDirtMeters: contiguousDirt,
                                    achievedMeaningfulDirt: achievedMeaningful,
                                    pavedWithoutMeaningfulMeters: pavedWithoutMeaningful,
                                    peakProgress: peak,parent: entry.label,arc: arc))
                storeBest(state, index)
                heap.push(.init(label: index,cost: heapCost(cost, arc.target)))
                if options.maximumMeters.isFinite, meters >= options.maximumMeters * 0.85 {
                    frontierHits.append((index, meters, arc.target))
                }
            }
        }
        func reconstruct(_ chosen: Int) -> ComputedRoute? {
            guard labels[chosen].state.unknownConnectorMeters == 0 else { return nil }
            var path: [Arc] = [], cursor: Int? = chosen
            while let i = cursor { if let arc = labels[i].arc { path.append(arc) }; cursor = labels[i].parent }
            path.reverse()
            let meaningful = path.filter { $0.meters > 0.01 }
            var i = 0
            while i < meaningful.count {
                guard pack.accessCode(meaningful[i].edge,forward: meaningful[i].forward) == 4 else { i += 1; continue }
                let first = i
                var distance = 0.0
                while i < meaningful.count && pack.accessCode(meaningful[i].edge,forward: meaningful[i].forward) == 4 {
                    distance += meaningful[i].meters; i += 1
                }
                guard distance <= 200.01, (first == 0 && access.startIsCustomer) || (i == meaningful.count && access.endIsCustomer) else {
                    return nil
                }
            }
            let segments = meaningful.map { arc in
                RouteSegment(edge: arc.edge,edgeID: pack.edgeID(arc.edge),forward: arc.forward,meters: arc.meters,
                             surface: ProfilePolicy.family(pack.surfaceLeaf(arc.edge)),surfaceLeaf: pack.surfaceLeaf(arc.edge),
                             roadClass: pack.roadClass(arc.edge),structure: pack.structure(arc.edge),
                             access: pack.accessCode(arc.edge,forward: arc.forward),geometry: clippedGeometry(arc))
            }
            let lastArc = meaningful.last
            let lastEdge = lastArc?.edge ?? end.edge
            let ends = [end] + options.additionalEnds
            var arrived = ends.first { $0.edge == lastEdge }
            if arrived == nil, let lastArc {
                let coord = clippedGeometry(lastArc).last ?? end.coordinate
                if let nearest = ends.min(by: {
                    $0.coordinate.distance(to: coord) < $1.coordinate.distance(to: coord)
                }), nearest.coordinate.distance(to: coord) <= 150 {
                    arrived = nearest
                }
            }
            if arrived == nil {
                if options.collectEveryGoal { return nil }
                arrived = end
            }
            guard let arrived else { return nil }
            var result = ComputedRoute(start: start,end: arrived,segments: segments,distanceMeters: labels[chosen].meters,
                                 searchCost: labels[chosen].cost,poppedLabels: pops,limit: limit,
                                 arrivalRestrictions: labels[chosen].state.restrictions)
            result.maneuvers = NavigationCues.make(route: result,graph: pack,access: access,arrival: options.arrival)
            return result
        }
        if options.collectEveryGoal {
            var collected: [ComputedRoute] = []
            var bestByEnd: [Int:ComputedRoute] = [:]
            for goal in goals {
                guard let route = reconstruct(goal), route.distanceMeters <= options.maximumMeters + 1 else { continue }
                if let previous = bestByEnd[route.end.edge], previous.searchCost <= route.searchCost { continue }
                bestByEnd[route.end.edge] = route
            }
            collected = Array(bestByEnd.values)
            options.profile?.collectedRoutes = collected
            if let dest = collected.first(where: {
                $0.end.edge == end.edge && abs($0.end.alongMeters - end.alongMeters) < 1
            }) {
                return .reached(dest)
            }
            if let any = collected.min(by: { $0.searchCost < $1.searchCost }) {
                return .reached(any)
            }
        }
        guard let chosen = goals.min(by: { a,b in
            func adjusted(_ index: Int) -> Double { labels[index].cost }
            if resource {
                let ra = (options.precedingDirtMeters+labels[a].dirtMeters)/max(1,options.precedingMeters+labels[a].meters)
                let rb = (options.precedingDirtMeters+labels[b].dirtMeters)/max(1,options.precedingMeters+labels[b].meters)
                let ma = policy.style == .dirt ? -ra : abs(ra-0.5)
                let mb = policy.style == .dirt ? -rb : abs(rb-0.5)
                if ma != mb { return ma < mb }
            } else if policy.style == .dirt, options.objective == .pavement,
                      abs(adjusted(a)-adjusted(b)) <= 0.5 {
                return labels[a].dirtMeters > labels[b].dirtMeters
            }
            return adjusted(a) < adjusted(b)
        }), let result = reconstruct(chosen) else {
            if options.maximumMeters.isFinite, !frontierHits.isEmpty {
                let nearCutoff = options.maximumMeters * 0.8
                var seen = Set<Int>()
                var samples: [FrontierSample] = []
                let ranked = frontierHits.sorted {
                    let ra = remaining(of: $0.node), rb = remaining(of: $1.node)
                    if ra.isFinite && rb.isFinite && abs(ra - rb) > 1 { return ra < rb }
                    return $0.meters > $1.meters
                }
                for hit in ranked where hit.meters >= nearCutoff {
                    guard seen.insert(hit.node).inserted else { continue }
                    samples.append(.init(coordinate: point(hit.node), meters: hit.meters, node: hit.node,
                                         remainingToDestination: remaining(of: hit.node)))
                    if samples.count >= 32 { break }
                }
                if samples.isEmpty {
                    for hit in ranked {
                        guard seen.insert(hit.node).inserted else { continue }
                        samples.append(.init(coordinate: point(hit.node), meters: hit.meters, node: hit.node,
                                             remainingToDestination: remaining(of: hit.node)))
                        if samples.count >= 16 { break }
                    }
                }
                if !samples.isEmpty { return .stoppedAtBudget(samples) }
            }
            if let limit { throw RoutingFailure.resourceLimit(limit) }
            throw RoutingFailure.noPath
        }
        return .reached(result)
    }

    private func clippedGeometry(_ arc: Arc) -> [Coordinate] {
        let line = pack.polyline(arc.edge)
        guard line.count > 1 else { return line }
        if arc.lower == 0 && arc.upper == pack.distance(arc.edge) { return arc.forward ? line : line.reversed() }
        var walked = 0.0, result: [Coordinate] = []
        for i in 1..<line.count {
            let a = line[i-1], b = line[i], m = a.distance(to: b)
            defer { walked += m }
            guard m > 0, walked+m >= arc.lower, walked <= arc.upper else { continue }
            for t in [max(0,(arc.lower-walked)/m),min(1,(arc.upper-walked)/m)] where t >= 0 && t <= 1 {
                let point = Coordinate(longitude: a.longitude+(b.longitude-a.longitude)*t,latitude: a.latitude+(b.latitude-a.latitude)*t)
                if result.last != point { result.append(point) }
            }
        }
        return arc.forward ? result : result.reversed()
    }

    private func customerEdges(match: RoadMatch,seeds: [Arc],reverse: Bool,enabled: Bool,budget: ComputationBudget) throws -> Set<Int> {
        guard enabled, [pack.accessCode(match.edge,forward: true),pack.accessCode(match.edge,forward: false)].contains(4) else { return [] }
        var adjacency: [Int:[(node:Int,edge:Int,meters:Double)]] = [:]
        for e in 0..<pack.edgeCount {
            if e & 1023 == 0 { try budget.check() }
            for forward in [true,false] where pack.accessCode(e,forward: forward) == 4 {
                let a = pack.endpoint(e,from: forward), b = pack.endpoint(e,from: !forward)
                adjacency[reverse ? b : a,default: []].append((reverse ? a : b,e,pack.distance(e)))
            }
        }
        var distances: [Int:Double] = [:], edges: Set<Int> = []
        var heap = BinaryHeap<(node:Int,meters:Double)> { $0.meters < $1.meters }
        for seed in seeds where seed.meters <= 200 && seed.target < pack.nodeCount {
            if seed.meters < distances[seed.target,default: .infinity] {
                distances[seed.target] = seed.meters; heap.push((seed.target,seed.meters)); edges.insert(match.edge)
            }
        }
        while let current = heap.pop() {
            try budget.check()
            if current.meters != distances[current.node] { continue }
            for arc in adjacency[current.node] ?? [] {
                let m = current.meters+arc.meters
                if m > 200 { continue }
                edges.insert(arc.edge)
                if m < distances[arc.node,default: .infinity] { distances[arc.node] = m; heap.push((arc.node,m)) }
            }
        }
        return edges
    }
}
