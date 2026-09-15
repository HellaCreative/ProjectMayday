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
    /// Compact hop-outcome log: which attempts used personality vs distance,
    /// and why style failed when it did. Diagnostic only — never drives choice.
    public let styleSummary: String?
}

/// Bounded personality-aware fuel chaining. Each hop is a fog-of-war limited
/// dirt/balanced/clean search toward the span destination; when the tank cuts
/// the frontier, the next stop is a packed station snapped from that frontier
/// (`fuelStationSnapMeters`). No separate logistics DFS and no advisory A→B
/// foundation when fuel cannot be proved.
public struct FuelPlanner: Sendable {
    /// Same contract as `ItineraryRangeArithmetic.fuelWaypointSnapMeters`.
    /// Stage 1 always produces a non-nil `stationID` after a successful snap.
    public static let fuelStationSnapMeters = 150.0
    /// Fog-of-war budget when fuel planning is off (distance-break chaining).
    public static let nominalLegBudgetMeters = 325_000.0

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
        /// Running totals for the current rider-to-rider span (Balanced mix).
        let meters: Double
        let dirt: Double
    }
    public func plan(_ request: RoutingRequest,requirements fuel: FuelRequirements,
                     budget: ComputationBudget = .init(seconds: 60)) throws -> FuelPlan {
        guard fuel.usableRangeMeters.isFinite, fuel.usableRangeMeters > 0,
              fuel.firstLegMaxMeters.isFinite, fuel.firstLegMaxMeters >= 0, fuel.minimumStops >= 0,
              fuel.destinationUsedLimitMeters.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw RoutingFailure.invalidRequest("fuel range")
        }
        try budget.check()
        let matcher = RoadMatcher(pack: graph)
        let candidates = stations.filter { !fuel.excludedStationIDs.contains($0.id) }
        var stationMatches: [String:[RoadMatch]] = [:]
        func matches(_ station: FuelStation) throws -> [RoadMatch] {
            if let cached = stationMatches[station.id] { return cached }
            var access = request.access; access.endIsCustomer = true
            // Packed pumps sit on forecourts; allow the same radius as rider pins.
            let result = try matcher.matches(at: station.coordinate,radius: max(150, request.matchRadiusMeters),
                                             start: false,policy: access,budget: budget)
            stationMatches[station.id] = result
            return result
        }
        let intent = request.start.bearing(to: request.end)*180 / .pi
        let initialMatches = try matcher.matches(at: request.start,radius: request.matchRadiusMeters,start: true,
            policy: request.access,intent: intent,budget: budget)
        let destinationMatches = try matcher.matches(at: request.end,radius: request.matchRadiusMeters,start: false,
            policy: request.access,intent: intent+180,budget: budget)
        guard !initialMatches.isEmpty, !destinationMatches.isEmpty else { throw RoutingFailure.noMatch }
        // Prepare compass once for the trip destination; reuse on every hop.
        var destCompass: RoadCompass?
        if let dest = destinationMatches.first {
            do { destCompass = try RoadCompass.toward(end: dest, pack: graph, budget: budget) }
            catch { destCompass = nil }
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
        func destLikelyReachable(from state: State, cap: Double) -> Bool {
            let left = roadRemaining(at: state.match ?? initialMatches.first)
            return left.isFinite && left <= cap + 50
        }
        func hopBudget() -> ComputationBudget {
            budget.limited(to: min(max(3, budget.remainingSeconds * 0.35), 12))
        }
        var styleNotes: [String] = []
        var styleOk = 0, styleOverCap = 0, styleStoppedAtBudget = 0, styleThrown = 0
        var styleNil = 0, distanceFallback = 0, leg0DistanceOnly = 0
        func note(_ line: String) { styleNotes.append(line) }
        func planResult(stops: [FuelStation], routes: [ComputedRoute], foundation: ComputedRoute?,
                        complete: Bool, limit: String?, destinationEscapeMeters: Double?,
                        firstReachableStationMeters: Double?) -> FuelPlan {
            let counts = "ok=\(styleOk) overCap=\(styleOverCap) stoppedBudget=\(styleStoppedAtBudget) " +
                "thrown=\(styleThrown) nil=\(styleNil) distFallback=\(distanceFallback) leg0dist=\(leg0DistanceOnly)"
            let detail = styleNotes.joined(separator: "|")
            return .init(stops: stops, routes: routes, foundation: foundation, complete: complete,
                         limit: limit, destinationEscapeMeters: destinationEscapeMeters,
                         firstReachableStationMeters: firstReachableStationMeters,
                         styleSummary: detail.isEmpty ? counts : "\(counts);\(detail)")
        }
        func balancedPreference(spanDirt: Double, spanMeters: Double) -> Double {
            guard spanMeters > 1 else { return 0.5 }
            let ratio = spanDirt / spanMeters
            return min(1, max(0, 0.5 + (0.5 - ratio) * 2))
        }
        func styleOptions(from state: State, cap: Double, shortest: Bool, toward: Coordinate,
                          roadRemaining: [Double]? = nil) -> (SearchOptions, ProfilePolicy) {
            var options = request.options
            options.precedingMeters = state.meters
            options.precedingDirtMeters = state.dirt
            options.maximumMeters = cap
            // Inherit rider avoid-cities; do not force the wall off on fuel hops.
            options.cityWall = request.options.cityWall
            options.varietyEnabled = false
            options.arrival = state.arrival
            // Default: trip-destination compass. Callers may override for
            // hop-local station compass without changing multi-goal pickers.
            options.roadRemaining = roadRemaining ?? destCompass?.remaining
            options.backtrackFactor = max(4, request.options.backtrackFactor)
            // Carry every prior hop's edges so hop N+1 cannot reverse back out
            // the road hop N just used to arrive at the pump.
            for route in state.routes { options.priorEdges.formUnion(route.segments.map(\.edgeID)) }
            var policy = request.profile
            if shortest {
                options.objective = .distance
                // Reachability must not inherit the wander corridor — short hops
                // near a pump need tank-width room, same as nearestReachable.
                options.corridorMeters = cap.isFinite ? cap + 20_000 : .infinity
            } else {
                // Fog-of-war is maximumMeters (tank). Corridor stays the wander band
                // so progress-regression actually blocks out-and-back nibbles.
                options.corridorMeters = request.profile.corridorMeters(
                    straightLine: state.point.distance(to: toward))
                switch request.profile.style {
                case .dirt:
                    options.objective = .pavement
                case .balanced:
                    options.objective = .profile
                    policy.balancedDirtPreference = balancedPreference(spanDirt: state.dirt, spanMeters: state.meters)
                case .cleanest:
                    options.objective = .profile
                    options.pavedOnly = true
                }
            }
            return (options, policy)
        }
        func hop(_ state: State, to point: Coordinate, endMatches: [RoadMatch], cap: Double,
                 customer: Bool, shortest: Bool = false, label: String = "hop") throws -> ComputedRoute? {
            if state.point.distance(to: point) > cap + 300 { return nil }
            if endMatches.isEmpty { return nil }
            var starts = state.match.map { [$0] } ?? initialMatches
            // Rematch clears arrival: PathSearch requires arrival.edge to match the
            // start edge, and intent rematch often picks a different forecourt road.
            var departureArrival = state.arrival
            if !state.stops.isEmpty {
                let rematched = try matcher.matches(at: state.point, radius: request.matchRadiusMeters,
                                                    start: true, policy: request.access,
                                                    intent: state.point.bearing(to: point) * 180 / .pi,
                                                    budget: budget)
                if !rematched.isEmpty {
                    starts = rematched
                    departureArrival = nil
                }
            }
            var access = request.access
            access.startIsCustomer = !state.stops.isEmpty || request.access.startIsCustomer
            access.endIsCustomer = customer
            let search = PathSearch(pack: graph)
            guard let primaryEnd = endMatches.first else { return nil }
            let geo = state.point.distance(to: point)
            let toDestination = point.distance(to: request.end) < 50
            func compassForHop(shortest: Bool, end: RoadMatch) throws -> [Double]? {
                if shortest || toDestination { return destCompass?.remaining }
                // Station hops must not use the trip-destination compass: away-tax
                // and the remaining heuristic would fight the pump being routed to.
                return try RoadCompass.toward(end: end, pack: graph, budget: hopBudget()).remaining
            }
            func run(start: RoadMatch, end: RoadMatch, shortest: Bool) throws -> (BoundedSearchResult, SearchProfile) {
                let profile = SearchProfile()
                var (options, policy) = styleOptions(from: state, cap: cap, shortest: shortest,
                                                     toward: point,
                                                     roadRemaining: try compassForHop(shortest: shortest, end: end))
                options.arrival = departureArrival
                options.additionalEnds = endMatches.filter { $0.edge != end.edge || $0.alongMeters != end.alongMeters }
                options.profile = profile
                if !shortest, request.profile.style == .dirt {
                    // Pavement's dirt-rate heuristic alone floods the tank before
                    // reaching a paved pump; pull toward the hop end.
                    options.fuelGoalPull = true
                }
                let result = try search.boundedSearch(start: start, end: end, policy: policy,
                                                      access: access, options: options, budget: hopBudget())
                return (result, profile)
            }
            try budget.check()
            let startCandidates = Array(starts.prefix(4))
            if shortest {
                for start in startCandidates {
                    if case .reached(let route) = try run(start: start, end: primaryEnd, shortest: true).0,
                       route.distanceMeters <= cap + 1 { return route }
                }
                return nil
            }
            do {
                var sawStopped = false, sawOverCap: Double? = nil, lastError: Error? = nil
                var lastProfile: SearchProfile? = nil
                for start in startCandidates {
                    do {
                        let (result, profile) = try run(start: start, end: primaryEnd, shortest: false)
                        lastProfile = profile
                        switch result {
                        case .reached(let route) where route.distanceMeters <= cap + 1:
                            styleOk += 1
                            let dirt = knownDirt(route)
                            let pct = route.distanceMeters > 0 ? Int((dirt / route.distanceMeters * 100).rounded()) : 0
                            note("\(label):styleOk geo=\(Int(geo))m route=\(Int(route.distanceMeters))m dirt=\(pct)% cap=\(Int(cap))m \(profile.summary)")
                            return route
                        case .reached(let route):
                            sawOverCap = max(sawOverCap ?? 0, route.distanceMeters)
                        case .stoppedAtBudget:
                            sawStopped = true
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        lastError = error
                    }
                }
                if let over = sawOverCap {
                    styleOverCap += 1
                    note("\(label):styleOverCap geo=\(Int(geo))m route=\(Int(over))m cap=\(Int(cap))m \(lastProfile?.summary ?? "")")
                } else if sawStopped {
                    styleStoppedAtBudget += 1
                    let reason = lastProfile?.limit
                        ?? ((lastProfile?.meterRejects ?? 0) > 0 ? "meterCap" : "exhausted")
                    note("\(label):styleStoppedAtBudget reason=\(reason) geo=\(Int(geo))m cap=\(Int(cap))m \(lastProfile?.summary ?? "")")
                } else {
                    styleThrown += 1
                    note("\(label):styleThrown geo=\(Int(geo))m cap=\(Int(cap))m err=\(lastError.map { "\($0)" } ?? "noPath") \(lastProfile?.summary ?? "")")
                }
            } catch is CancellationError {
                throw CancellationError()
            }
            if request.profile.style == .cleanest {
                for start in startCandidates {
                    var (options, policy) = styleOptions(from: state, cap: cap, shortest: false,
                                                         toward: point,
                                                         roadRemaining: try? compassForHop(shortest: false, end: primaryEnd))
                    options.arrival = departureArrival
                    options.pavedOnly = false
                    options.additionalEnds = Array(endMatches.dropFirst())
                    do {
                        if case .reached(let route) = try search.boundedSearch(
                            start: start, end: primaryEnd, policy: policy, access: access,
                            options: options, budget: hopBudget()),
                           route.distanceMeters <= cap + 1 { return route }
                    } catch is CancellationError { throw CancellationError() } catch { }
                }
            }
            do {
                var lastError: Error? = nil
                for start in startCandidates {
                    do {
                        if case .reached(let route) = try run(start: start, end: primaryEnd, shortest: true).0,
                           route.distanceMeters <= cap + 1 {
                            distanceFallback += 1
                            note("\(label):distanceFallback geo=\(Int(geo))m route=\(Int(route.distanceMeters))m")
                            return route
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        lastError = error
                    }
                }
                note("\(label):distanceFail geo=\(Int(geo))m err=\(lastError.map { "\($0)" } ?? "noPath")")
                return nil
            } catch is CancellationError {
                throw CancellationError()
            }
        }
        func knownDirt(_ route: ComputedRoute) -> Double {
            route.segments.filter { $0.structure != "ferry" && ($0.surface == .gravel || $0.surface == .loose) }
                .reduce(0) { $0 + $1.meters }
        }
        func stateAfter(_ previous: State, station: FuelStation?, route: ComputedRoute) -> State {
            let last = route.segments.last
            let arrival = SearchArrival(edge: graph.restrictionEdge(last?.edge ?? route.end.edge),
                                        coordinate: route.end.coordinate,
                                        restrictions: route.arrivalRestrictions)
            let nextMatch = RoadMatch(edge: route.end.edge, coordinate: route.end.coordinate,
                                      distanceMeters: route.end.distanceMeters,
                                      alongMeters: route.end.alongMeters,
                                      geometryMeters: route.end.geometryMeters)
            return .init(point: route.end.coordinate, match: nextMatch, arrival: arrival,
                         stops: previous.stops + (station.map { [$0] } ?? []),
                         routes: previous.routes + [route],
                         meters: previous.meters + route.distanceMeters,
                         dirt: previous.dirt + knownDirt(route))
        }
        func failure(_ message: String, state: State) -> FuelPlan {
            // Always keep proven hops. The caller decides via allowPartialResult
            // whether an incomplete chain is acceptable product behavior; the
            // engine never invents an advisory A→B foundation.
            return planResult(stops: state.stops, routes: state.routes, foundation: nil,
                              complete: false, limit: message, destinationEscapeMeters: nil,
                              firstReachableStationMeters: nil)
        }
        func placeName(_ coordinate: Coordinate) -> String {
            String(format: "%.3f,%.3f", coordinate.latitude, coordinate.longitude)
        }
        /// Frontier samples → packed stations within `fuelStationSnapMeters`.
        /// Yields at most one station per progressing sample (preferred, else
        /// deterministic id). Caller proves each with a single hop; first success
        /// wins — this is a frontier walk, not a ranked pump set.
        func stationsAlongFrontier(_ frontier: [FrontierSample], excluding: Set<String>,
                                   hereRemaining: Double) -> [FuelStation] {
            let preferred = Set(fuel.preferredStationIDs)
            let snap = Self.fuelStationSnapMeters
            var seen = Set<String>()
            var ordered: [FuelStation] = []
            for sample in frontier {
                let progressing = !sample.remainingToDestination.isFinite
                    || !hereRemaining.isFinite
                    || sample.remainingToDestination < hereRemaining - 1
                guard progressing else { continue }
                let nearby = candidates.filter { station in
                    !excluding.contains(station.id)
                        && sample.coordinate.distance(to: station.coordinate) <= snap
                }
                if nearby.isEmpty { continue }
                let pick = nearby.first(where: { preferred.contains($0.id) })
                    ?? nearby.sorted { $0.id < $1.id }.first
                guard let pick, seen.insert(pick.id).inserted else { continue }
                ordered.append(pick)
            }
            return ordered
        }
        /// Progressing stations by road-compass remaining (preferred first).
        func progressingStations(excluding: Set<String>, hereRemaining: Double,
                                 tank: Double, from here: Coordinate) -> [FuelStation] {
            let preferred = Set(fuel.preferredStationIDs)
            return candidates.filter { station in
                guard !excluding.contains(station.id) else { return false }
                let geoProgress = here.distance(to: request.end)
                    > station.coordinate.distance(to: request.end) + 500
                if hereRemaining.isFinite {
                    let stationMatches = (try? matches(station)) ?? []
                    let there = stationMatches.map { roadRemaining(at: $0) }.min() ?? .infinity
                    guard there.isFinite else { return geoProgress }
                    return there < hereRemaining - 500 && (hereRemaining - there) <= tank
                }
                return geoProgress
            }.sorted { a, b in
                let ap = preferred.contains(a.id), bp = preferred.contains(b.id)
                if ap != bp { return ap && !bp }
                let aLeft = (try? matches(a))?.map { roadRemaining(at: $0) }.min() ?? .infinity
                let bLeft = (try? matches(b))?.map { roadRemaining(at: $0) }.min() ?? .infinity
                if aLeft.isFinite, bLeft.isFinite, abs(aLeft - bLeft) > 1 { return aLeft < bLeft }
                let aGeo = a.coordinate.distance(to: request.end)
                let bGeo = b.coordinate.distance(to: request.end)
                if abs(aGeo - bGeo) > 1 { return aGeo < bGeo }
                return a.id < b.id
            }
        }
        func nearestReachable(_ state: State, stations: [FuelStation], cap: Double) throws -> (FuelStation, ComputedRoute)? {
            var goals: [(FuelStation, RoadMatch)] = []
            for station in stations {
                if state.point.distance(to: station.coordinate) > cap + 300 { continue }
                for match in try matches(station) { goals.append((station, match)) }
            }
            guard let first = goals.first else { return nil }
            var options = request.options
            options.arrival = state.arrival
            options.precedingMeters = state.meters
            options.precedingDirtMeters = state.dirt
            options.maximumMeters = cap
            options.objective = .distance
            options.cityWall = request.options.cityWall
            options.corridorMeters = cap.isFinite ? cap + 20_000 : .infinity
            options.varietyEnabled = false
            options.additionalEnds = goals.dropFirst().map(\.1)
            options.roadRemaining = destCompass?.remaining
            options.backtrackFactor = max(4, request.options.backtrackFactor)
            for route in state.routes { options.priorEdges.formUnion(route.segments.map(\.edgeID)) }
            let starts = state.match.map { [$0] } ?? initialMatches
            var access = request.access
            access.startIsCustomer = !state.stops.isEmpty || request.access.startIsCustomer
            access.endIsCustomer = true
            // Prefer a departure match that faces away from the arrival road.
            var startCandidates = starts
            var departureArrival = state.arrival
            if !state.stops.isEmpty, let intentMatch = try? matcher.matches(
                at: state.point, radius: request.matchRadiusMeters, start: true,
                policy: access,
                intent: state.point.bearing(to: first.0.coordinate) * 180 / .pi,
                budget: budget
            ), !intentMatch.isEmpty {
                startCandidates = intentMatch
                departureArrival = nil
            }
            options.arrival = departureArrival
            for start in startCandidates {
                try budget.check()
                do {
                    let route = try PathSearch(pack: graph).search(start: start, end: first.1,
                                                                   policy: request.profile, access: access,
                                                                   options: options, budget: hopBudget())
                    let station = goals.first { $0.1.edge == route.end.edge && $0.1.alongMeters == route.end.alongMeters }?.0
                        ?? goals.first { $0.1.edge == route.end.edge }?.0 ?? first.0
                    if route.distanceMeters <= cap + 1 { return (station, route) }
                } catch is CancellationError { throw CancellationError() }
                catch { continue }
            }
            return nil
        }
        /// Multi-goal personality search among reachable onward stations — SOT §5:
        /// prefer the pump whose approach best expresses the selected style.
        func styledReachable(_ state: State, stations: [FuelStation], cap: Double) throws -> (FuelStation, ComputedRoute)? {
            var goals: [(FuelStation, RoadMatch)] = []
            for station in stations {
                if state.point.distance(to: station.coordinate) > cap + 300 { continue }
                for match in try matches(station) { goals.append((station, match)) }
            }
            guard let first = goals.first else {
                note("styleMulti:noGoals cap=\(Int(cap))m stations=\(stations.count)")
                return nil
            }
            var (options, policy) = styleOptions(from: state, cap: cap, shortest: false,
                                                 toward: request.end, roadRemaining: destCompass?.remaining)
            options.additionalEnds = goals.dropFirst().map(\.1)
            // Progress gate is relative to the primary end match; with many pump
            // goals that gate rejects approaches to every other station.
            options.disableProgressRegression = true
            if request.profile.style == .dirt { options.fuelGoalPull = true }
            var access = request.access
            access.startIsCustomer = !state.stops.isEmpty || request.access.startIsCustomer
            access.endIsCustomer = true
            var startCandidates = state.match.map { [$0] } ?? initialMatches
            var departureArrival = state.arrival
            if !state.stops.isEmpty, let intentMatch = try? matcher.matches(
                at: state.point, radius: request.matchRadiusMeters, start: true,
                policy: access,
                intent: state.point.bearing(to: first.0.coordinate) * 180 / .pi,
                budget: budget
            ), !intentMatch.isEmpty {
                startCandidates = intentMatch
                departureArrival = nil
            }
            options.arrival = departureArrival
            var sawStopped = false, sawOverCap: Double? = nil, lastError: Error? = nil
            var lastProfile: SearchProfile? = nil
            for start in startCandidates {
                try budget.check()
                let profile = SearchProfile()
                options.profile = profile
                do {
                    switch try PathSearch(pack: graph).boundedSearch(
                        start: start, end: first.1, policy: policy, access: access,
                        options: options, budget: hopBudget()) {
                    case .reached(let route) where route.distanceMeters <= cap + 1:
                        let station = goals.first { $0.1.edge == route.end.edge && $0.1.alongMeters == route.end.alongMeters }?.0
                            ?? goals.first { $0.1.edge == route.end.edge }?.0 ?? first.0
                        let dirt = knownDirt(route)
                        let pct = route.distanceMeters > 0 ? Int((dirt / route.distanceMeters * 100).rounded()) : 0
                        note("styleMulti:ok station=\(station.id) goals=\(goals.count) route=\(Int(route.distanceMeters))m dirt=\(pct)% \(profile.summary)")
                        return (station, route)
                    case .reached(let route):
                        sawOverCap = max(sawOverCap ?? 0, route.distanceMeters)
                        lastProfile = profile
                    case .stoppedAtBudget:
                        sawStopped = true
                        lastProfile = profile
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    lastError = error
                    lastProfile = profile
                }
            }
            if let over = sawOverCap {
                note("styleMulti:overCap goals=\(goals.count) route=\(Int(over))m cap=\(Int(cap))m \(lastProfile?.summary ?? "")")
            } else if sawStopped {
                let reason = lastProfile?.limit
                    ?? ((lastProfile?.meterRejects ?? 0) > 0 ? "meterCap" : "exhausted")
                note("styleMulti:stoppedAtBudget reason=\(reason) goals=\(goals.count) cap=\(Int(cap))m \(lastProfile?.summary ?? "")")
            } else if let lastError {
                note("styleMulti:thrown goals=\(goals.count) cap=\(Int(cap))m err=\(lastError) \(lastProfile?.summary ?? "")")
            } else {
                note("styleMulti:nil goals=\(goals.count) cap=\(Int(cap))m \(lastProfile?.summary ?? "")")
            }
            return nil
        }

        if fuel.probeFirstStation {
            var nearest: ComputedRoute?, selected: FuelStation?
            for station in candidates.sorted(by: { request.start.distance(to: $0.coordinate) < request.start.distance(to: $1.coordinate) }) {
                let cap = min(fuel.firstLegMaxMeters, fuel.usableRangeMeters, nearest?.distanceMeters ?? .infinity)
                if request.start.distance(to: station.coordinate) > cap + 300 { continue }
                let initial = State(point: request.start, match: nil, arrival: request.options.arrival,
                                    stops: [], routes: [], meters: request.options.precedingMeters,
                                    dirt: request.options.precedingDirtMeters)
                if let route = try hop(initial, to: station.coordinate, endMatches: matches(station),
                                       cap: cap, customer: true, shortest: true),
                   nearest == nil || route.distanceMeters < nearest!.distanceMeters {
                    nearest = route; selected = station
                }
            }
            return planResult(stops: selected.map { [$0] } ?? [], routes: nearest.map { [$0] } ?? [],
                              foundation: nil, complete: selected != nil,
                              limit: selected == nil ? "no reachable fuel" : nil,
                              destinationEscapeMeters: nil,
                              firstReachableStationMeters: nearest?.distanceMeters)
        }

        var current = State(point: request.start, match: nil, arrival: request.options.arrival,
                            stops: [], routes: [], meters: request.options.precedingMeters,
                            dirt: request.options.precedingDirtMeters)
        var visited = 0
        /// After a compass-optimistic dest hop fails, do not retry it until the
        /// next committed stop changes the departure state.
        var destHopFailedFromCurrent = false
        func commitStop(_ station: FuelStation, route: ComputedRoute) {
            current = stateAfter(current, station: station, route: route)
            destHopFailedFromCurrent = false
        }
        do {
        chain: while true {
            try budget.check()
            visited += 1
            guard visited <= budget.maximumLabels else {
                return failure("no fuel stop found within range near \(placeName(current.point))", state: current)
            }
            let tank = current.stops.isEmpty
                ? min(fuel.firstLegMaxMeters, fuel.usableRangeMeters)
                : fuel.usableRangeMeters
            // Plan targets with slack so a Dirt hop can meander inside the real
            // tank. Style searches still use `tank`; only target selection /
            // reachability feelers use `planTank`.
            let planStyleSlack = 1.4
            let planTank = tank / planStyleSlack
            let requiredSatisfied = fuel.requiredFirstStationID == nil || !current.stops.isEmpty
            if !destHopFailedFromCurrent,
               current.stops.count >= fuel.minimumStops && requiredSatisfied {
                let endCap = min(tank, fuel.destinationUsedLimitMeters ?? .infinity)
                if destLikelyReachable(from: current, cap: min(endCap, planTank)),
                   let tail = try hop(current, to: request.end, endMatches: destinationMatches, cap: endCap,
                                      customer: request.access.endIsCustomer, label: "dest") {
                    var escape: Double? = fuel.ensureDestinationEscape ? nil : 0
                    if fuel.ensureDestinationEscape {
                        let arrived = stateAfter(current, station: nil, route: tail)
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
                        return planResult(stops: current.stops, routes: current.routes + [tail],
                                          foundation: nil, complete: true,
                                          limit: (current.routes + [tail]).compactMap(\.limit).first,
                                          destinationEscapeMeters: fuel.ensureDestinationEscape ? escape : nil,
                                          firstReachableStationMeters: nil)
                    }
                    if fuel.ensureDestinationEscape {
                        return failure("no fuel stop found within range near \(placeName(request.end))", state: current)
                    }
                } else if destLikelyReachable(from: current, cap: min(planTank, fuel.destinationUsedLimitMeters ?? .infinity)) {
                    destHopFailedFromCurrent = true
                }
            }
            if let maxStops = fuel.maximumStops, current.stops.count >= maxStops {
                // Window is full: return proven hops so the caller can continue
                // from the last pump. Do not hard-fail — windowStops=1 is a
                // feeler size, not "refuse to chain further".
                if fuel.allowPartialResult, !current.stops.isEmpty {
                    return planResult(stops: current.stops, routes: current.routes, foundation: nil,
                                      complete: false, limit: nil, destinationEscapeMeters: nil,
                                      firstReachableStationMeters: nil)
                }
                return failure("no fuel stop found within range near \(placeName(current.point))", state: current)
            }

            let used = Set(current.stops.map(\.id))
            let eligible = candidates.filter { station in
                !used.contains(station.id)
                    && current.point.distance(to: station.coordinate) <= tank + 150
                    && (!current.stops.isEmpty || fuel.requiredFirstStationID == nil
                        || station.id == fuel.requiredFirstStationID)
            }

            // Leg 0: nearest reachable pump within the first-leg fog of war.
            if current.stops.isEmpty {
                if let already = eligible.first(where: { current.point.distance(to: $0.coordinate) < 50 }),
                   let approach = try hop(current, to: already.coordinate, endMatches: matches(already),
                                          cap: tank, customer: true, shortest: true) {
                    commitStop(already, route: approach)
                    continue
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
                                                       cap: min(tank, roadCap))
                        if nearest != nil { break stationSearch }
                        if limit >= slice.count { break }
                    }
                }
                if let nearest {
                    // Closest reachable pump (SOT §5), then a real style attempt —
                    // leg 0 is a ride leg, not a paved taxi to the first pump.
                    if let styled = try hop(current, to: nearest.0.coordinate,
                                            endMatches: matches(nearest.0), cap: tank,
                                            customer: true, label: "leg0:\(nearest.0.id)"),
                       styled.distanceMeters <= tank + 1 {
                        commitStop(nearest.0, route: styled)
                    } else {
                        leg0DistanceOnly += 1
                        let dirt = knownDirt(nearest.1)
                        let pct = nearest.1.distanceMeters > 0
                            ? Int((dirt / nearest.1.distanceMeters * 100).rounded()) : 0
                        note("leg0:distanceOnly station=\(nearest.0.id) route=\(Int(nearest.1.distanceMeters))m dirt=\(pct)%")
                        commitStop(nearest.0, route: nearest.1)
                    }
                    continue
                }
                return failure("no fuel stop found within range near \(placeName(current.point))", state: current)
            }

            // Later hops: multi-goal personality among onward stations (SOT §5 —
            // prefer the approach that expresses riding style). Distance pick is
            // the fallback when no styled station is reachable inside the tank.
            let hereRemaining = roadRemaining(at: current.match)
            let onward = eligible.filter { station in
                let geo = current.point.distance(to: request.end)
                    > station.coordinate.distance(to: request.end) + 500
                // Geo must fit the planning slack — prefix(48) of stations nearest
                // the destination are often all beyond planTank on long trips.
                guard geo, current.point.distance(to: station.coordinate) <= planTank + 300 else { return false }
                if hereRemaining.isFinite {
                    let there = ((try? matches(station)) ?? []).map { roadRemaining(at: $0) }.min() ?? .infinity
                    // Keep compass-progressing stations; also keep geo-only when
                    // compass has no reading for the candidate (joined-pack holes).
                    if there.isFinite {
                        return there < hereRemaining - 500 && (hereRemaining - there) <= planTank + 1_000
                    }
                }
                return true
            }.sorted { a, b in
                let aGeo = a.coordinate.distance(to: request.end)
                let bGeo = b.coordinate.distance(to: request.end)
                if abs(aGeo - bGeo) > 1 { return aGeo < bGeo }
                return a.id < b.id
            }
            let onwardSlice = Array(onward.prefix(48))
            if !onwardSlice.isEmpty,
               let styled = try styledReachable(current, stations: onwardSlice, cap: tank) {
                let dirt = knownDirt(styled.1)
                let pct = styled.1.distanceMeters > 0
                    ? Int((dirt / styled.1.distanceMeters * 100).rounded()) : 0
                styleOk += 1
                note("onward:\(styled.0.id):styleMultiOk route=\(Int(styled.1.distanceMeters))m dirt=\(pct)%")
                commitStop(styled.0, route: styled.1)
                continue chain
            }
            if !onwardSlice.isEmpty,
               let nearest = try nearestReachable(current, stations: onwardSlice, cap: planTank) {
                if let styled = try hop(current, to: nearest.0.coordinate, endMatches: matches(nearest.0),
                                        cap: tank, customer: true, label: "onward:\(nearest.0.id)"),
                   styled.distanceMeters <= tank + 1 {
                    commitStop(nearest.0, route: styled)
                } else {
                    distanceFallback += 1
                    let dirt = knownDirt(nearest.1)
                    let pct = nearest.1.distanceMeters > 0
                        ? Int((dirt / nearest.1.distanceMeters * 100).rounded()) : 0
                    note("onward:\(nearest.0.id):commitDistancePick route=\(Int(nearest.1.distanceMeters))m dirt=\(pct)%")
                    commitStop(nearest.0, route: nearest.1)
                }
                continue chain
            }

            note("onward:noPick eligible=\(eligible.count) onward=\(onward.count) hereRemaining=\(Int(hereRemaining))m planTank=\(Int(planTank))m")
            let starts = current.match.map { [$0] } ?? initialMatches
            guard let start = starts.first else {
                return failure("no fuel stop found within range near \(placeName(current.point))", state: current)
            }
            var access = request.access
            access.startIsCustomer = true
            access.endIsCustomer = request.access.endIsCustomer
            let (options, policy) = styleOptions(from: current, cap: tank, shortest: false, toward: request.end)
            let floodBudget = budget.limited(to: min(max(2, budget.remainingSeconds * 0.2), 6))
            do {
                let result = try PathSearch(pack: graph).boundedSearch(
                    start: start, end: destinationMatches[0], policy: policy, access: access,
                    options: options, budget: floodBudget)
                switch result {
                case .reached(let route) where route.distanceMeters <= tank + 1
                    && current.stops.count >= fuel.minimumStops && requiredSatisfied:
                    var escape: Double? = fuel.ensureDestinationEscape ? nil : 0
                    if fuel.ensureDestinationEscape {
                        let arrived = stateAfter(current, station: nil, route: route)
                        let remaining = max(0, tank - route.distanceMeters)
                        for station in candidates.sorted(by: { request.end.distance(to: $0.coordinate) < request.end.distance(to: $1.coordinate) }) {
                            if request.end.distance(to: station.coordinate) > remaining + 150 { continue }
                            if let road = try hop(arrived, to: station.coordinate, endMatches: matches(station),
                                                  cap: remaining, customer: true, shortest: true) {
                                escape = road.distanceMeters; break
                            }
                        }
                    }
                    if let escape {
                        return planResult(stops: current.stops, routes: current.routes + [route],
                                          foundation: nil, complete: true, limit: route.limit,
                                          destinationEscapeMeters: fuel.ensureDestinationEscape ? escape : nil,
                                          firstReachableStationMeters: nil)
                    }
                    return failure("no fuel stop found within range near \(placeName(request.end))", state: current)
                case .reached:
                    break
                case .stoppedAtBudget(let frontier):
                    for station in stationsAlongFrontier(frontier, excluding: used,
                                                         hereRemaining: hereRemaining).prefix(3) {
                        if let approach = try hop(current, to: station.coordinate, endMatches: matches(station),
                                                  cap: tank, customer: true, label: "frontier:\(station.id)") {
                            commitStop(station, route: approach)
                            continue chain
                        }
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { }

            return failure("no fuel stop found within range near \(placeName(current.point))", state: current)
        }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RoutingFailure {
            // Time/label limits mid-chain are incomplete fuel proof, not an
            // opaque engine crash. Surface as an explicit gap with any proven
            // hops retained — never throw through to a silent unknown advisory.
            if case .resourceLimit = error {
                return failure("no fuel stop found within range near \(placeName(current.point))", state: current)
            }
            throw error
        }
    }
}
