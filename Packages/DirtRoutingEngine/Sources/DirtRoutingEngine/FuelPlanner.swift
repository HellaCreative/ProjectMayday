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
        func hopBudget(shortest: Bool) -> ComputationBudget {
            let cap = shortest ? 3.0 : min(max(3, budget.remainingSeconds * 0.25), 8)
            return budget.limited(to: cap)
        }
        func hop(_ state: State,to point: Coordinate,endMatches: [RoadMatch],cap: Double,customer: Bool,shortest: Bool = false) throws -> ComputedRoute? {
            if state.point.distance(to: point) > cap+300 { return nil }
            var next = RoutingRequest(start: state.point,end: point,style: request.profile.style,
                                      allowUnknown: request.access.allowUnknown,seed: request.options.seed)
            next.profile = request.profile; next.options = request.options
            next.options.arrival = state.arrival
            next.options.precedingMeters = state.meters; next.options.precedingDirtMeters = state.dirt
            next.options.maximumMeters = min(cap,request.options.maximumMeters-state.meters)
            next.access = request.access; next.access.startIsCustomer = !state.stops.isEmpty || request.access.startIsCustomer
            next.access.endIsCustomer = customer
            for route in state.routes { next.options.priorEdges.formUnion(route.segments.map(\.edgeID)) }
            let starts = state.match.map { [$0] } ?? initialMatches
            let sub = hopBudget(shortest: shortest)
            for start in starts {
                for end in endMatches {
                    try budget.check()
                    do {
                        if shortest {
                            next.options.objective = .distance; next.options.cityWall = false
                            next.options.corridorMeters = cap.isFinite ? cap + 20_000 : .infinity
                            return try PathSearch(pack: graph).search(start: start,end: end,policy: next.profile,
                                access: next.access,options: next.options,budget: sub)
                        }
                        return try engine.route(next,start: start,end: end,budget: sub)
                    } catch RoutingFailure.noPath { continue }
                    catch RoutingFailure.resourceLimit { continue }
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
        var foundation: ComputedRoute?
        // Live combined fuel-chain does not spend the 20 s window on an A→B
        // preview. Tiny-label tests still keep that foundation.
        let skipPreview = budget.maximumLabels > 10_000 && budget.remainingSeconds <= 22
        if !skipPreview {
            do {
                foundation = try engine.route(request,budget: budget.limited(to: max(1,min(6,budget.remainingSeconds*0.15))))
            } catch is CancellationError { throw CancellationError() }
            catch RoutingFailure.noPath { }
            catch RoutingFailure.resourceLimit { }
        }
        func destLikelyReachable(from state: State, cap: Double) -> Bool {
            let straight = state.point.distance(to: request.end)
            guard straight <= cap + 300 else { return false }
            if let foundation, foundation.distanceMeters > 0 {
                let startStraight = max(1, request.start.distance(to: request.end))
                return straight * (foundation.distanceMeters / startStraight) <= cap + 1_000
            }
            return straight * 1.4 <= cap + 1_000
        }
        var heap = BinaryHeap<State> {
            $0.stops.count == $1.stops.count ? $0.score < $1.score : $0.stops.count < $1.stops.count
        }
        heap.push(initial)
        var visited = 0
        var bestPartial: FuelPlan?
        do {
        while let current = heap.pop() {
            try budget.check()
            visited += 1
            guard visited <= budget.maximumLabels else { throw RoutingFailure.resourceLimit("fuel states") }
            let tank = current.stops.isEmpty ? min(fuel.firstLegMaxMeters,fuel.usableRangeMeters) : fuel.usableRangeMeters
            let requiredSatisfied = fuel.requiredFirstStationID == nil || !current.stops.isEmpty
            if current.stops.count >= fuel.minimumStops && requiredSatisfied {
                let endCap = min(tank,fuel.destinationUsedLimitMeters ?? .infinity)
                if destLikelyReachable(from: current, cap: endCap),
                   let tail = try hop(current,to: request.end,endMatches: destinationMatches,cap: endCap,
                                      customer: request.access.endIsCustomer,shortest: true) {
                    var escape: Double? = fuel.ensureDestinationEscape ? nil : 0
                    if fuel.ensureDestinationEscape {
                        let arrived = stateAfter(current,station: nil,route: tail,destination: request.end)
                        let remaining = max(0,tank-tail.distanceMeters)
                        for station in candidates.sorted(by: { request.end.distance(to: $0.coordinate) < request.end.distance(to: $1.coordinate) }) {
                            if request.end.distance(to: station.coordinate) > remaining+150 { continue }
                            if let road = try hop(arrived,to: station.coordinate,endMatches: matches(station),cap: remaining,customer: true,shortest: true) {
                                escape = road.distanceMeters; break
                            }
                        }
                    }
                    if let escape {
                        return .init(stops: current.stops,routes: current.routes+[tail],foundation: foundation,
                                     complete: true,limit: (current.routes+[tail]).compactMap(\.limit).first,
                                     destinationEscapeMeters: fuel.ensureDestinationEscape ? escape : nil,firstReachableStationMeters: nil)
                    }
                }
                if fuel.allowPartialResult, !current.stops.isEmpty,
                   bestPartial == nil || current.stops.count > (bestPartial?.stops.count ?? 0) {
                    bestPartial = .init(stops: current.stops,routes: current.routes,foundation: foundation,
                                        complete: false,limit: "partial window",destinationEscapeMeters: nil,firstReachableStationMeters: nil)
                }
            }
            if let max = fuel.maximumStops, current.stops.count >= max { continue }
            let used = Set(current.stops.map(\.id))
            let remaining = current.point.distance(to: request.end)
            let eligible = candidates.filter { station in
                !used.contains(station.id) && current.point.distance(to: station.coordinate) <= tank+150 &&
                (!current.stops.isEmpty || fuel.requiredFirstStationID == nil || station.id == fuel.requiredFirstStationID)
            }
            if current.stops.isEmpty, fuel.requiredFirstStationID == nil {
                if let already = eligible.first(where: { current.point.distance(to: $0.coordinate) < 50 }),
                   let approach = try hop(current,to: already.coordinate,endMatches: matches(already),cap: tank,customer: true,shortest: true) {
                    heap.push(stateAfter(current,station: already,route: approach,destination: request.end))
                    continue
                }
                let nearby = eligible.sorted {
                    current.point.distance(to: $0.coordinate) < current.point.distance(to: $1.coordinate)
                }
                var nearest: (FuelStation,ComputedRoute)?
                let caps = [min(25_000,tank), min(60_000,tank), tank].reduce(into: [Double]()) {
                    if !$0.contains($1) { $0.append($1) }
                }
                stationSearch: for roadCap in caps {
                    let slice = nearby.filter { current.point.distance(to: $0.coordinate) <= roadCap+300 }
                    guard !slice.isEmpty else { continue }
                    for limit in [24, 64, slice.count] where limit > 0 {
                        nearest = try nearestReachable(current,stations: Array(slice.prefix(limit)),
                                                       cap: min(tank,roadCap),matches: matches,budget: budget,request: request)
                        if nearest != nil { break stationSearch }
                        if limit >= slice.count { break }
                    }
                }
                if let nearest { heap.push(stateAfter(current,station: nearest.0,route: nearest.1,destination: request.end)) }
                continue
            }
            let preferred = Set(fuel.preferredStationIDs)
            func onward(_ station: FuelStation) -> Double {
                remaining - station.coordinate.distance(to: request.end)
            }
            let ranked = eligible.sorted { a,b in
                let ap = preferred.contains(a.id), bp = preferred.contains(b.id)
                if ap != bp { return ap && !bp }
                let aProg = onward(a), bProg = onward(b)
                let aForward = aProg > 1_000, bForward = bProg > 1_000
                if aForward != bForward { return aForward && !bForward }
                if abs(aProg - bProg) > 2_000 { return aProg > bProg }
                let aDetour = abs(a.coordinate.crossTrack(from: current.point, to: request.end))
                let bDetour = abs(b.coordinate.crossTrack(from: current.point, to: request.end))
                if abs(aDetour - bDetour) > 5_000 { return aDetour < bDetour }
                return a.id < b.id
            }
            let progressing = ranked.filter { onward($0) > 1_000 }
            let toTry = progressing.isEmpty ? ranked : progressing
            var pushed = 0
            for station in toTry {
                try budget.check()
                guard let approach = try hop(current,to: station.coordinate,endMatches: matches(station),cap: tank,customer: true,shortest: true) else { continue }
                heap.push(stateAfter(current,station: station,route: approach,destination: request.end,
                                     preferred: preferred.contains(station.id)))
                pushed += 1
                if pushed >= 8 { break }
            }
        }
        } catch RoutingFailure.resourceLimit(let reason) {
            if let bestPartial { return bestPartial }
            return .init(stops: [],routes: [],foundation: foundation,complete: false,
                         limit: "fuel comparison incomplete: \(reason)",destinationEscapeMeters: nil,firstReachableStationMeters: nil)
        }
        if let bestPartial { return bestPartial }
        return .init(stops: [],routes: [],foundation: foundation,complete: false,limit: "no fuel-qualified continuation",
                     destinationEscapeMeters: nil,firstReachableStationMeters: nil)
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
            } catch RoutingFailure.noPath { continue }
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
