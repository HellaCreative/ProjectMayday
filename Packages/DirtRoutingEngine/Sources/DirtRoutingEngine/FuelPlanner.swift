import Foundation

public struct FuelStation: Codable, Sendable, Hashable {
    public let id: String
    public let coordinate: Coordinate
    public let name: String?
    public let brand: String?
    public let address: String?
    public init(id: String,coordinate: Coordinate,name: String? = nil,brand: String? = nil,address: String? = nil) {
        self.id = id; self.coordinate = coordinate; self.name = name; self.brand = brand; self.address = address
    }
}

public struct FuelRequirements: Sendable {
    public var usableRangeMeters: Double
    public var firstLegMaxMeters: Double
    public var minimumStops = 0
    public var maximumStops: Int?
    public var excludedStationIDs: Set<String> = []
    public var requiredFirstStationID: String?
    public var destinationUsedLimitMeters: Double?
    public var ensureDestinationEscape = false
    public var probeFirstStation = false
    public var allowPartialResult = false
    public var preferredStationIDs: [String] = []
    public init(usableRangeMeters: Double,firstLegMaxMeters: Double) {
        self.usableRangeMeters = usableRangeMeters; self.firstLegMaxMeters = firstLegMaxMeters
    }
}

public struct FuelPlan: Sendable {
    public let stops: [FuelStation]
    public let routes: [ComputedRoute]
    public let foundation: ComputedRoute?
    public let complete: Bool
    public let limit: String?
    public let destinationEscapeMeters: Double?
    public let firstReachableStationMeters: Double?
}

/// Local road-proven fuel planning. Each stop must support a legal continuation
/// within the reserve-adjusted tank bound. All searches share a deadline.
public struct FuelPlanner: Sendable {
    private let graph: any RoadGraph
    private let stations: [FuelStation]
    private let compassStore: RoadCompassStore?
    public init(graph: any RoadGraph,stations: [FuelStation],compassStore: RoadCompassStore? = nil) throws {
        guard stations.allSatisfy({ !$0.id.isEmpty && $0.coordinate.isValid }),
              Set(stations.map(\.id)).count == stations.count else { throw RoutingFailure.invalidPack("fuel station identities") }
        self.graph = graph; self.stations = stations; self.compassStore = compassStore
    }
    private struct State {
        let point: Coordinate
        let match: RoadMatch?
        let arrival: SearchArrival?
        let stops: [FuelStation]
        let routes: [ComputedRoute]
        let meters: Double
        let dirt: Double
        let score: Double
    }
    public func plan(_ request: RoutingRequest,requirements fuel: FuelRequirements,
                     budget: ComputationBudget = .init(seconds: 60)) throws -> FuelPlan {
        guard fuel.usableRangeMeters.isFinite, fuel.usableRangeMeters > 0,
              fuel.firstLegMaxMeters.isFinite, fuel.firstLegMaxMeters >= 0, fuel.minimumStops >= 0,
              fuel.destinationUsedLimitMeters.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw RoutingFailure.invalidRequest("fuel range")
        }
        try budget.check()
        let engine = RoutingEngine(pack: graph, compassStore: compassStore), matcher = RoadMatcher(pack: graph)
        let candidates = stations.filter { !fuel.excludedStationIDs.contains($0.id) }
        var stationMatches: [String:[RoadMatch]] = [:]
        func matches(_ station: FuelStation) throws -> [RoadMatch] {
            if let cached = stationMatches[station.id] { return cached }
            var access = request.access; access.endIsCustomer = true
            let result = try matcher.matches(at: station.coordinate,radius: 150,start: false,policy: access,budget: budget)
            stationMatches[station.id] = result
            return result
        }
        let intent = request.start.bearing(to: request.end)*180 / .pi
        let initialMatches = try matcher.matches(at: request.start,radius: request.matchRadiusMeters,start: true,
            policy: request.access,intent: intent,budget: budget)
        let destinationMatches = try matcher.matches(at: request.end,radius: request.matchRadiusMeters,start: false,
            policy: request.access,intent: intent+180,budget: budget)
        guard !initialMatches.isEmpty, !destinationMatches.isEmpty else { throw RoutingFailure.noMatch }
        var destCompass: RoadCompass?
        if let dest = destinationMatches.first {
            do { destCompass = try RoadCompass.toward(end: dest, pack: graph, budget: budget) }
            catch { destCompass = nil }
        }
        func hopBudget(shortest: Bool) -> ComputationBudget {
            let cap = shortest ? min(max(3, budget.remainingSeconds * 0.3), 8)
                               : min(max(3, budget.remainingSeconds * 0.2), 6)
            return budget.limited(to: cap)
        }
        func hop(_ state: State,to point: Coordinate,endMatches: [RoadMatch],cap: Double,customer: Bool,shortest: Bool = false) throws -> ComputedRoute? {
            if state.point.distance(to: point) > cap+300 { return nil }
            var options = request.options
            options.precedingMeters = state.meters
            options.precedingDirtMeters = state.dirt
            options.maximumMeters = cap
            options.cityWall = false
            options.corridorMeters = cap.isFinite ? cap + 20_000 : .infinity
            options.varietyEnabled = false
            options.arrival = state.arrival
            if !shortest { options.roadRemaining = destCompass?.remaining }
            for route in state.routes { options.priorEdges.formUnion(route.segments.map(\.edgeID)) }
            var access = request.access
            access.startIsCustomer = !state.stops.isEmpty || request.access.startIsCustomer
            access.endIsCustomer = customer
            let starts = state.match.map { [$0] } ?? initialMatches
            let search = PathSearch(pack: graph)
            var tried = Set<String>()
            func attempt(_ start: RoadMatch, _ end: RoadMatch, distance: Bool) throws -> ComputedRoute? {
                var opts = options
                opts.objective = distance ? .distance : (request.profile.style == .dirt ? .pavement : .profile)
                if request.profile.style == .cleanest && !distance { opts.pavedOnly = true }
                let route = try search.search(start: start, end: end, policy: request.profile,
                                              access: access, options: opts, budget: hopBudget(shortest: distance))
                return route.distanceMeters <= cap + 1 ? route : nil
            }
            for start in starts {
                for end in endMatches {
                    guard tried.insert("\(start.edge):\(String(describing: start.forward)):\(start.alongMeters)|\(end.edge):\(end.alongMeters)").inserted else { continue }
                    try budget.check()
                    do {
                        if shortest {
                            if let route = try attempt(start, end, distance: true) { return route }
                            continue
                        }
                        do { if let route = try attempt(start, end, distance: false) { return route } } catch { }
                        if request.profile.style == .cleanest {
                            var opts = options
                            opts.objective = .profile
                            opts.pavedOnly = false
                            do {
                                let route = try search.search(start: start, end: end, policy: request.profile,
                                                              access: access, options: opts, budget: hopBudget(shortest: false))
                                if route.distanceMeters <= cap + 1 { return route }
                            } catch { }
                        }
                        if let route = try attempt(start, end, distance: true) { return route }
                    } catch is CancellationError { throw CancellationError() }
                    catch { continue }
                }
            }
            return nil
        }
        let initial = State(point: request.start,match: nil,arrival: request.options.arrival,
                            stops: [],routes: [],meters: request.options.precedingMeters,
                            dirt: request.options.precedingDirtMeters,
                            score: request.start.distance(to: request.end))
        if fuel.probeFirstStation {
            var nearest: ComputedRoute?, selected: FuelStation?
            for station in candidates.sorted(by: { request.start.distance(to: $0.coordinate) < request.start.distance(to: $1.coordinate) }) {
                let cap = min(fuel.firstLegMaxMeters,fuel.usableRangeMeters,nearest?.distanceMeters ?? .infinity)
                if request.start.distance(to: station.coordinate) > cap+300 { continue }
                if let route = try hop(initial,to: station.coordinate,endMatches: matches(station),cap: cap,customer: true,shortest: true),
                   nearest == nil || route.distanceMeters < nearest!.distanceMeters {
                    nearest = route; selected = station
                }
            }
            return .init(stops: selected.map { [$0] } ?? [],routes: nearest.map { [$0] } ?? [],foundation: nil,
                         complete: selected != nil,limit: selected == nil ? "no reachable fuel" : nil,
                         destinationEscapeMeters: nil,firstReachableStationMeters: nearest?.distanceMeters)
        }
        func roadRemaining(at match: RoadMatch?) -> Double {
            guard let table = destCompass?.remaining, let match, match.edge >= 0, match.edge < graph.edgeCount else {
                return .infinity
            }
            let a = graph.endpoint(match.edge, from: true), b = graph.endpoint(match.edge, from: false)
            let along = match.alongMeters, length = match.geometryMeters
            let viaA = a >= 0 && a < table.count ? table[a] + along : .infinity
            let viaB = b >= 0 && b < table.count ? table[b] + max(0, length - along) : .infinity
            return min(viaA, viaB)
        }
        var foundation: ComputedRoute?
        func ensureFoundation() {
            guard foundation == nil else { return }
            let foundationStarted = ContinuousClock.now
            do {
                foundation = try engine.route(request, budget: budget.limited(to: max(1, min(6, budget.remainingSeconds))))
            } catch is CancellationError { }
            catch { }
            request.options.counter?.recordStage("fuel-foundation", since: foundationStarted)
        }
        func destLikelyReachable(from state: State, cap: Double) -> Bool {
            // Crow-flies is not a tank check: Porters Lake → Canso is ~194 km
            // straight and ~356 km on roads. Use the destination compass from the
            // current (or start) match only.
            let left = roadRemaining(at: state.match ?? initialMatches.first)
            return left.isFinite && left <= cap + 50
        }
        /// One tank-bounded distance flood. Later hops only try pumps this flood can reach.
        func tankReachable(from state: State, tank: Double, among: [FuelStation]) throws -> Set<String> {
            var edgeStations: [Int:[(id: String, along: Double)]] = [:]
            for station in among {
                for match in try matches(station) {
                    edgeStations[match.edge, default: []].append((station.id, match.alongMeters))
                }
            }
            guard !edgeStations.isEmpty else { return [] }
            let origins = state.match.map { [$0] } ?? initialMatches
            guard let origin = origins.first else { return [] }
            var access = request.access
            access.startIsCustomer = !state.stops.isEmpty || request.access.startIsCustomer
            access.endIsCustomer = true
            var reached: Set<String> = []
            func consider(edge: Int, fromNode: Int, meters: Double) {
                guard let list = edgeStations[edge] else { return }
                let a = graph.endpoint(edge, from: true)
                let length = graph.distance(edge)
                for item in list {
                    let via = fromNode == a ? item.along : max(0, length - item.along)
                    if meters + via <= tank + 0.5 { reached.insert(item.id) }
                }
            }
            if let list = edgeStations[origin.edge] {
                for item in list where abs(item.along - origin.alongMeters) <= tank + 0.5 {
                    reached.insert(item.id)
                }
            }
            var best = [Int: Double]()
            var heap = BinaryHeap<(Int, Double)> { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
            func offer(_ node: Int, _ meters: Double) {
                guard node >= 0, node < graph.nodeCount, meters <= tank + 0.5 else { return }
                if let previous = best[node], previous <= meters { return }
                best[node] = meters
                heap.push((node, meters))
            }
            let sa = graph.endpoint(origin.edge, from: true), sb = graph.endpoint(origin.edge, from: false)
            offer(sa, origin.alongMeters)
            offer(sb, max(0, origin.geometryMeters - origin.alongMeters))
            var pops = 0
            while let (node, meters) = heap.pop() {
                if pops & 255 == 0 { try budget.check() }
                pops += 1
                guard best[node] == meters else { continue }
                if pops > budget.maximumLabels { break }
                for arc in graph.outgoing(node) {
                    let isEnd = edgeStations[arc.edge] != nil
                    guard access.permits(graph.accessCode(arc.edge, forward: arc.forward),
                                         isStart: arc.edge == origin.edge, isEnd: isEnd) else { continue }
                    consider(edge: arc.edge, fromNode: node, meters: meters)
                    let step = arc.meters.isFinite && arc.meters > 0 ? arc.meters : graph.distance(arc.edge)
                    offer(arc.target, meters + max(0, step))
                }
            }
            return reached
        }
        var visited = 0
        var bestPartial: FuelPlan?
        func recordPartial(_ current: State) {
            guard fuel.allowPartialResult, !current.stops.isEmpty else { return }
            if bestPartial == nil || current.stops.count > (bestPartial?.stops.count ?? 0) {
                bestPartial = .init(stops: current.stops, routes: current.routes, foundation: foundation,
                                    complete: false, limit: "partial window", destinationEscapeMeters: nil,
                                    firstReachableStationMeters: nil)
            }
        }
        func solve(_ current: State) throws -> FuelPlan? {
            try budget.check()
            visited += 1
            guard visited <= budget.maximumLabels else { throw RoutingFailure.resourceLimit("fuel states") }
            let tank = current.stops.isEmpty ? min(fuel.firstLegMaxMeters, fuel.usableRangeMeters) : fuel.usableRangeMeters
            let requiredSatisfied = fuel.requiredFirstStationID == nil || !current.stops.isEmpty
            if current.stops.count >= fuel.minimumStops && requiredSatisfied {
                let endCap = min(tank, fuel.destinationUsedLimitMeters ?? .infinity)
                if destLikelyReachable(from: current, cap: endCap),
                   let tail = try hop(current, to: request.end, endMatches: destinationMatches, cap: endCap,
                                      customer: request.access.endIsCustomer, shortest: true) {
                    var escape: Double? = fuel.ensureDestinationEscape ? nil : 0
                    if fuel.ensureDestinationEscape {
                        let arrived = stateAfter(current, station: nil, route: tail, destination: request.end)
                        let remaining = max(0, tank - tail.distanceMeters)
                        for station in candidates.sorted(by: { request.end.distance(to: $0.coordinate) < request.end.distance(to: $1.coordinate) }) {
                            if request.end.distance(to: station.coordinate) > remaining + 150 { continue }
                            if let road = try hop(arrived, to: station.coordinate, endMatches: matches(station),
                                                  cap: remaining, customer: true, shortest: true) {
                                escape = road.distanceMeters; break
                            }
                        }
                    }
                    if let escape {
                        return .init(stops: current.stops, routes: current.routes + [tail], foundation: foundation,
                                     complete: true, limit: (current.routes + [tail]).compactMap(\.limit).first,
                                     destinationEscapeMeters: fuel.ensureDestinationEscape ? escape : nil,
                                     firstReachableStationMeters: nil)
                    }
                }
                recordPartial(current)
            }
            if let maxStops = fuel.maximumStops, current.stops.count >= maxStops { return nil }
            let used = Set(current.stops.map(\.id))
            let eligible = candidates.filter { station in
                !used.contains(station.id) && current.point.distance(to: station.coordinate) <= tank + 150 &&
                (!current.stops.isEmpty || fuel.requiredFirstStationID == nil || station.id == fuel.requiredFirstStationID)
            }
            if current.stops.isEmpty, fuel.requiredFirstStationID == nil {
                if let already = eligible.first(where: { current.point.distance(to: $0.coordinate) < 50 }),
                   let approach = try hop(current, to: already.coordinate, endMatches: matches(already),
                                          cap: tank, customer: true, shortest: true) {
                    return try solve(stateAfter(current, station: already, route: approach, destination: request.end))
                }
                let nearby = eligible.sorted {
                    current.point.distance(to: $0.coordinate) < current.point.distance(to: $1.coordinate)
                }
                var nearest: (FuelStation, ComputedRoute)?
                let caps = [min(25_000, tank), min(60_000, tank), tank].reduce(into: [Double]()) {
                    if !$0.contains($1) { $0.append($1) }
                }
                stationSearch: for roadCap in caps {
                    let slice = nearby.filter { current.point.distance(to: $0.coordinate) <= roadCap + 300 }
                    guard !slice.isEmpty else { continue }
                    for limit in [24, 64, slice.count] where limit > 0 {
                        nearest = try nearestReachable(current, stations: Array(slice.prefix(limit)),
                                                       cap: min(tank, roadCap), matches: matches, budget: budget, request: request)
                        if nearest != nil { break stationSearch }
                        if limit >= slice.count { break }
                    }
                }
                if let nearest {
                    return try solve(stateAfter(current, station: nearest.0, route: nearest.1, destination: request.end))
                }
                return nil
            }
            let preferred = Set(fuel.preferredStationIDs)
            let here = roadRemaining(at: current.match)
            func towardDest(_ station: FuelStation) -> Double {
                let matches = (try? matches(station)) ?? []
                return matches.map { roadRemaining(at: $0) }.min() ?? .infinity
            }
            func hopLower(_ station: FuelStation) -> Double {
                let there = towardDest(station)
                guard here.isFinite, there.isFinite else { return .infinity }
                return max(0, here - there)
            }
            let reachable = destCompass == nil
                ? (try tankReachable(from: current, tank: tank, among: eligible))
                : []
            let progressing = eligible.filter { station in
                let there = towardDest(station)
                guard there.isFinite, here.isFinite else { return false }
                let inFlood = reachable.isEmpty || reachable.contains(station.id)
                return there < here - 1 && hopLower(station) <= tank && inFlood
            }
            let hopPool = progressing.isEmpty ? eligible : progressing
            let ranked = hopPool.sorted { a, b in
                let ap = preferred.contains(a.id), bp = preferred.contains(b.id)
                if ap != bp { return ap && !bp }
                let aLeft = towardDest(a), bLeft = towardDest(b)
                if abs(aLeft - bLeft) > 1_000 { return aLeft < bLeft }
                return a.id < b.id
            }
            for station in ranked.prefix(8) {
                try budget.check()
                guard let approach = try hop(current, to: station.coordinate, endMatches: matches(station),
                                             cap: tank, customer: true, shortest: true) else { continue }
                if let plan = try solve(stateAfter(current, station: station, route: approach, destination: request.end,
                                                   preferred: preferred.contains(station.id))) {
                    return plan
                }
            }
            return nil
        }
        do {
            if let plan = try solve(initial) { return plan }
        } catch RoutingFailure.resourceLimit(let reason) {
            ensureFoundation()
            if var bestPartial {
                bestPartial = .init(stops: bestPartial.stops, routes: bestPartial.routes, foundation: foundation,
                                    complete: false, limit: bestPartial.limit, destinationEscapeMeters: nil,
                                    firstReachableStationMeters: nil)
                return bestPartial
            }
            return .init(stops: [], routes: [], foundation: foundation, complete: false,
                         limit: "fuel comparison incomplete: \(reason)", destinationEscapeMeters: nil,
                         firstReachableStationMeters: nil)
        }
        ensureFoundation()
        if var bestPartial {
            bestPartial = .init(stops: bestPartial.stops, routes: bestPartial.routes, foundation: foundation,
                                complete: false, limit: bestPartial.limit, destinationEscapeMeters: nil,
                                firstReachableStationMeters: nil)
            return bestPartial
        }
        return .init(stops: [], routes: [], foundation: foundation, complete: false, limit: "no fuel-qualified continuation",
                     destinationEscapeMeters: nil, firstReachableStationMeters: nil)
    }
    private func nearestReachable(_ state: State,stations: [FuelStation],cap: Double,
                                  matches: (FuelStation) throws -> [RoadMatch],
                                  budget: ComputationBudget,request: RoutingRequest) throws -> (FuelStation,ComputedRoute)? {
        var goals: [(FuelStation,RoadMatch)] = []
        for station in stations {
            if state.point.distance(to: station.coordinate) > cap+300 { continue }
            for match in try matches(station) { goals.append((station,match)) }
        }
        guard let first = goals.first else { return nil }
        var options = request.options
        options.arrival = state.arrival
        options.precedingMeters = state.meters
        options.precedingDirtMeters = state.dirt
        options.maximumMeters = min(cap,request.options.maximumMeters-state.meters)
        options.objective = .distance
        options.cityWall = false
        options.corridorMeters = cap.isFinite ? cap + 20_000 : .infinity
        options.varietyEnabled = false
        options.additionalEnds = goals.dropFirst().map(\.1)
        let starts = state.match.map { [$0] } ?? []
        let startMatches = starts.isEmpty ? try RoadMatcher(pack: graph).matches(
            at: state.point,radius: request.matchRadiusMeters,start: true,
            policy: request.access,intent: request.start.bearing(to: request.end)*180 / .pi,budget: budget) : starts
        var access = request.access
        access.startIsCustomer = !state.stops.isEmpty || request.access.startIsCustomer
        access.endIsCustomer = true
        for start in startMatches {
            try budget.check()
            do {
                let sub = budget.limited(to: min(8, max(3, budget.remainingSeconds * 0.3)))
                let route = try PathSearch(pack: graph).search(start: start,end: first.1,policy: request.profile,
                                                              access: access,options: options,budget: sub)
                let station = goals.first { $0.1.edge == route.end.edge && $0.1.alongMeters == route.end.alongMeters }?.0
                    ?? goals.first { $0.1.edge == route.end.edge }?.0 ?? first.0
                return (station,route)
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        return nil
    }
    private func stateAfter(_ previous: State,station: FuelStation?,route: ComputedRoute,destination: Coordinate,
                            preferred: Bool = false) -> State {
        let last = route.segments.last
        let arrival = SearchArrival(edge: graph.restrictionEdge(last?.edge ?? route.end.edge),coordinate: route.end.coordinate,
                                    restrictions: route.arrivalRestrictions)
        let nextMatch = RoadMatch(edge: route.end.edge,coordinate: route.end.coordinate,distanceMeters: route.end.distanceMeters,
                                 alongMeters: route.end.alongMeters,geometryMeters: route.end.geometryMeters)
        let knownDirt = route.segments.filter { $0.structure != "ferry" && ($0.surface == .gravel || $0.surface == .loose) }.reduce(0) { $0+$1.meters }
        let remaining = route.end.coordinate.distance(to: destination)
        return .init(point: route.end.coordinate,match: nextMatch,arrival: arrival,
                     stops: previous.stops+(station.map { [$0] } ?? []),routes: previous.routes+[route],
                     meters: previous.meters+route.distanceMeters,dirt: previous.dirt+knownDirt,
                     score: remaining - (preferred ? 1_000_000 : 0))
    }
}
