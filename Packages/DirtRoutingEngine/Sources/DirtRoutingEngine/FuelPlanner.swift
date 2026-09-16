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
    /// True when this `plan` resumes at a mapped pump (a later planning window,
    /// a resume-from-station, or a start that is already the committed stop).
    /// Rule 8's nearest-first-pump hop then must not run.
    public var resumeAtPump = false
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
    /// Per-hop road-progress ratio (rule 10). -1 when compass is unavailable.
    public let hopProgressShare: [Double]
    /// Per-hop absolute degrees off the refill→waypoint line (rule 10).
    public let hopOffLineDegrees: [Double]
}

/// Fuel chaining per the §5 owner contract: nearest legal first pump, then one
/// style sweep per refill and a fan pick. No advisory A→B foundation when fuel
/// cannot be proved.
public struct FuelPlanner: Sendable {
    /// Same contract as `ItineraryRangeArithmetic.fuelWaypointSnapMeters`.
    /// Stage 1 always produces a non-nil `stationID` after a successful snap.
    public static let fuelStationSnapMeters = 150.0
    /// Later pumps may not sit this close to the pump the leg started from.
    public static let minimumOnwardPumpSeparationMeters = 5_000.0
    /// Pump-to-pump ridden distance below this is only valid as the trip's
    /// real first pump (rule 8).
    public static let minimumOnwardPumpLegMeters = 20_000.0
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
        let startPump = candidates.min {
            request.start.distance(to: $0.coordinate) < request.start.distance(to: $1.coordinate)
        }.flatMap { nearest in
            request.start.distance(to: nearest.coordinate) <= Self.fuelStationSnapMeters ? nearest : nil
        }
        let skipFirstPump = fuel.resumeAtPump
            || (fuel.usableRangeMeters >= Self.minimumOnwardPumpLegMeters
                && startPump != nil
                && (fuel.requiredFirstStationID == nil
                    || fuel.requiredFirstStationID == startPump?.id))
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
        func hopBudget() -> ComputationBudget {
            budget.limited(to: min(max(3, budget.remainingSeconds * 0.35), 20))
        }
        var styleNotes: [String] = []
        var styleOk = 0, styleOverCap = 0, styleStoppedAtBudget = 0, styleThrown = 0
        var styleNil = 0, distanceFallback = 0, leg0DistanceOnly = 0
        var hopProgressShare: [Double] = []
        var hopOffLineDegrees: [Double] = []
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
                         styleSummary: detail.isEmpty ? counts : "\(counts);\(detail)",
                         hopProgressShare: hopProgressShare, hopOffLineDegrees: hopOffLineDegrees)
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
        /// Direct legal approach only (rule 8 first pump, and destination-escape
        /// proof). Never used to pick a pump after the first.
        func hop(_ state: State, to point: Coordinate, endMatches: [RoadMatch], cap: Double,
                 customer: Bool) throws -> ComputedRoute? {
            if state.point.distance(to: point) > cap + 300 { return nil }
            if endMatches.isEmpty { return nil }
            var starts = state.match.map { [$0] } ?? initialMatches
            let departureArrival = state.arrival
            if !state.stops.isEmpty || skipFirstPump {
                let rematched = try matcher.matches(at: state.point, radius: request.matchRadiusMeters,
                                                    start: true, policy: request.access,
                                                    intent: state.point.bearing(to: point) * 180 / .pi,
                                                    budget: budget)
                var combined: [RoadMatch] = []
                for match in starts + rematched {
                    if !combined.contains(where: {
                        $0.edge == match.edge && abs($0.alongMeters - match.alongMeters) < 1
                    }) { combined.append(match) }
                }
                if !combined.isEmpty { starts = combined }
            }
            var access = request.access
            access.startIsCustomer = !state.stops.isEmpty || skipFirstPump || request.access.startIsCustomer
            access.endIsCustomer = customer
            let search = PathSearch(pack: graph)
            guard let primaryEnd = endMatches.first else { return nil }
            for start in starts.prefix(8) {
                try budget.check()
                var (options, policy) = styleOptions(from: state, cap: cap, shortest: true,
                                                     toward: point, roadRemaining: destCompass?.remaining)
                options.arrival = (state.match.map { $0.edge == start.edge } == true) ? departureArrival : nil
                options.additionalEnds = endMatches.filter { $0.edge != primaryEnd.edge || $0.alongMeters != primaryEnd.alongMeters }
                do {
                    if case .reached(let route) = try search.boundedSearch(
                        start: start, end: primaryEnd, policy: policy, access: access,
                        options: options, budget: hopBudget()),
                       route.distanceMeters <= cap + 1 { return route }
                } catch is CancellationError { throw CancellationError() }
                catch { continue }
            }
            return nil
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
        func angleDelta(_ a: Double, _ b: Double) -> Double {
            var d = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi)
            if d > .pi { d = 2 * .pi - d }
            return d
        }
        /// Straight-line bearing from the refill to the next rider waypoint (rule 10).
        func waypointHeading(from state: State) -> Double {
            state.point.bearing(to: request.end)
        }
        func offLineDegrees(from start: Coordinate, to point: Coordinate) -> Double {
            angleDelta(start.bearing(to: point), start.bearing(to: request.end)) * 180 / .pi
        }
        func progressRatio(from startMatch: RoadMatch?, station: FuelStation?, dest: RoadMatch?, ridden: Double) -> Double? {
            let here = roadRemaining(at: startMatch)
            let there: Double
            if let station {
                there = ((try? matches(station)) ?? []).map { roadRemaining(at: $0) }.min() ?? .infinity
            } else {
                there = roadRemaining(at: dest)
            }
            guard here.isFinite, there.isFinite, ridden > 1 else { return nil }
            return (here - there) / ridden
        }
        func defaultProgressShare() -> Double {
            let wander = min(1, max(0, request.profile.wander))
            return 0.5 + 0.3 * (1 - wander)
        }
        func styleScore(_ route: ComputedRoute) -> Double {
            let dirt = knownDirt(route)
            let ratio = dirt / max(1, route.distanceMeters)
            switch request.profile.style {
            case .dirt: return -ratio
            case .balanced: return abs(ratio - 0.5)
            case .cleanest: return ratio
            }
        }
        /// One style search from the refill, capped at the tank (rule 9). Records
        /// every pump reached and whether the destination itself was reached.
        func sweep(_ state: State, stations: [FuelStation], cap: Double) throws -> (dest: ComputedRoute?, pumps: [(FuelStation, ComputedRoute)]) {
            var goals: [(FuelStation, RoadMatch)] = []
            for station in stations {
                if state.point.distance(to: station.coordinate) > cap + 300 { continue }
                for match in try matches(station) { goals.append((station, match)) }
            }
            guard let destEnd = destinationMatches.first else { return (nil, []) }
            var (options, policy) = styleOptions(from: state, cap: cap, shortest: false,
                                                 toward: request.end, roadRemaining: destCompass?.remaining)
            options.collectEveryGoal = true
            options.disableProgressRegression = true
            // Fog of war is the tank. Wander must not hide reachable pumps (rule 6).
            options.corridorMeters = cap.isFinite ? cap + 20_000 : .infinity
            if request.profile.style == .dirt { options.fuelGoalPull = true }
            // Clean still prefers pavement via profile cost. pavedOnly cannot
            // start a sweep from an unpaved pump forecourt (rule 8 first pump).
            if request.profile.style == .cleanest { options.pavedOnly = false }
            options.additionalEnds = goals.map(\.1)
            var access = request.access
            access.startIsCustomer = !state.stops.isEmpty || skipFirstPump || request.access.startIsCustomer
            access.endIsCustomer = true
            var startCandidates = state.match.map { [$0] } ?? initialMatches
            var departureArrival = state.arrival
            if !state.stops.isEmpty || skipFirstPump, let intentMatch = try? matcher.matches(
                at: state.point, radius: request.matchRadiusMeters, start: true,
                policy: access,
                intent: waypointHeading(from: state) * 180 / .pi,
                budget: budget
            ), !intentMatch.isEmpty {
                var combined: [RoadMatch] = []
                for match in intentMatch + startCandidates {
                    if !combined.contains(where: {
                        $0.edge == match.edge && abs($0.alongMeters - match.alongMeters) < 1
                    }) { combined.append(match) }
                }
                startCandidates = combined
            }
            guard !startCandidates.isEmpty else { return (nil, []) }
            var destRoute: ComputedRoute?
            var pumps: [(FuelStation, ComputedRoute)] = []
            var seen = Set<String>()
            var lastSummary = ""
            func absorb(_ collected: [ComputedRoute]) {
                for route in collected where route.distanceMeters <= cap + 1 {
                    let actual = route.segments.last?.geometry.last ?? route.end.coordinate
                    let destDist = actual.distance(to: request.end)
                    let nearestPumpDist = goals.map { $0.0.coordinate.distance(to: actual) }.min() ?? .infinity
                    if destDist <= Self.fuelStationSnapMeters, destDist <= nearestPumpDist {
                        if destRoute == nil || route.searchCost < destRoute!.searchCost { destRoute = route }
                        continue
                    }
                    let station = goals.first { $0.1.edge == route.end.edge && abs($0.1.alongMeters - route.end.alongMeters) < 2 }?.0
                        ?? goals.first { $0.1.edge == route.end.edge }?.0
                        ?? goals.min(by: {
                            $0.0.coordinate.distance(to: actual) < $1.0.coordinate.distance(to: actual)
                        }).flatMap { $0.0.coordinate.distance(to: actual) <= Self.fuelStationSnapMeters ? $0.0 : nil }
                    guard let station, seen.insert(station.id).inserted else { continue }
                    pumps.append((station, route))
                }
            }
            for start in startCandidates {
                let arrivalChoices: [SearchArrival?]
                if state.match?.edge == start.edge, let arrival = departureArrival {
                    arrivalChoices = [arrival, nil]
                } else {
                    arrivalChoices = [nil]
                }
                for arrival in arrivalChoices {
                    try budget.check()
                    let profile = SearchProfile()
                    options.profile = profile
                    options.arrival = arrival
                    do {
                        _ = try PathSearch(pack: graph).boundedSearch(
                            start: start, end: destEnd, policy: policy, access: access,
                            options: options, budget: hopBudget())
                    } catch is CancellationError { throw CancellationError() }
                    catch RoutingFailure.noPath { }
                    catch RoutingFailure.resourceLimit { }
                    catch { note("sweep:thrown err=\(error)") }
                    lastSummary = profile.summary
                    absorb(profile.collectedRoutes)
                    note("sweep:try dest=\(destRoute != nil ? 1 : 0) pumps=\(pumps.count) collected=\(profile.collectedRoutes.count) arrival=\(arrival == nil ? 0 : 1) \(profile.summary)")
                    if destRoute != nil || !pumps.isEmpty { break }
                }
                if destRoute != nil || !pumps.isEmpty { break }
            }
            note("sweep:reached dest=\(destRoute != nil ? 1 : 0) pumps=\(pumps.count) \(lastSummary)")
            return (destRoute, pumps)
        }
        /// Rule 3: a hop that leaves a forecourt, goes round the block, and
        /// returns past the pump it started from is a loop, not a leg.
        func isForecourtLoop(_ route: ComputedRoute, from: Coordinate) -> Bool {
            var left = false
            for point in route.geometry {
                let d = from.distance(to: point)
                if d > 400 { left = true }
                if left && d < Self.fuelStationSnapMeters { return true }
            }
            return false
        }
        /// Rule 8 onward spacing: no later pump within 5 km of the start pump,
        /// and no pump-to-pump ridden distance under ~20 km except the trip's
        /// real first pump. Tiny-range unit graphs keep nearby refills.
        func onwardPumpAllowed(_ station: FuelStation, _ route: ComputedRoute, from state: State) -> Bool {
            let fromRefill = skipFirstPump || !state.stops.isEmpty
            guard fromRefill else { return true }
            if isForecourtLoop(route, from: state.point) { return false }
            guard fuel.usableRangeMeters >= Self.minimumOnwardPumpLegMeters else { return true }
            if state.point.distance(to: station.coordinate) < Self.minimumOnwardPumpSeparationMeters {
                return false
            }
            if route.distanceMeters < Self.minimumOnwardPumpLegMeters { return false }
            return true
        }
        /// Rule 10/11: 120° fan at the next rider waypoint; progress share then
        /// modest fan widening. Never ranked by closeness to the destination.
        func pickPump(from reached: [(FuelStation, ComputedRoute)], state: State, cap: Double) -> (FuelStation, ComputedRoute)? {
            let heading = waypointHeading(from: state)
            func progress(of station: FuelStation, route: ComputedRoute) -> Double? {
                progressRatio(from: state.match, station: station, dest: nil, ridden: route.distanceMeters)
            }
            func offLine(of station: FuelStation) -> Double {
                offLineDegrees(from: state.point, to: station.coordinate)
            }
            func counts(_ station: FuelStation, _ route: ComputedRoute, share: Double, halfRadians: Double) -> Bool {
                guard onwardPumpAllowed(station, route, from: state) else { return false }
                guard route.distanceMeters <= cap + 1 else { return false }
                guard angleDelta(state.point.bearing(to: station.coordinate), heading) <= halfRadians else { return false }
                let ratio = progress(of: station, route: route)
                if let ratio { return ratio >= share }
                return true
            }
            func choose(share: Double, totalFan: Double) -> (FuelStation, ComputedRoute)? {
                let half = (totalFan / 2) * .pi / 180
                let eligible = reached.filter { counts($0.0, $0.1, share: share, halfRadians: half) }
                guard let pick = eligible.min(by: { a, b in
                    let sa = styleScore(a.1), sb = styleScore(b.1)
                    if abs(sa - sb) > 0.001 { return sa < sb }
                    let pa = progress(of: a.0, route: a.1) ?? -1, pb = progress(of: b.0, route: b.1) ?? -1
                    if pa >= 0, pb >= 0, abs(pa - pb) > 0.001 { return pa > pb }
                    return a.1.distanceMeters > b.1.distanceMeters
                }) else { return nil }
                let ratio = progress(of: pick.0, route: pick.1) ?? -1
                let dirt = knownDirt(pick.1)
                let pct = pick.1.distanceMeters > 0 ? Int((dirt / pick.1.distanceMeters * 100).rounded()) : 0
                note("fan:pick station=\(pick.0.id) fan=\(Int(totalFan))° share=\(String(format: "%.2f", share)) progress=\(String(format: "%.2f", ratio)) offLine=\(Int(offLine(of: pick.0).rounded()))° route=\(Int(pick.1.distanceMeters))m dirt=\(pct)%")
                return pick
            }
            let baseShare = defaultProgressShare()
            var steps: [(share: Double, fan: Double)] = [
                (baseShare, 120), (0.35, 120), (0.2, 120), (0.2, 150), (0.2, 180)
            ]
            steps = steps.reduce(into: []) { seen, step in
                if !seen.contains(where: { abs($0.share - step.share) < 0.001 && abs($0.fan - step.fan) < 0.1 }) {
                    seen.append(step)
                }
            }
            for step in steps {
                if let pick = choose(share: step.share, totalFan: step.fan) { return pick }
                note(String(format: "fan:relax fan=%.0f° share=%.2f none", step.fan, step.share))
            }
            return nil
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

        if fuel.probeFirstStation {
            var nearest: ComputedRoute?, selected: FuelStation?
            for station in candidates.sorted(by: { request.start.distance(to: $0.coordinate) < request.start.distance(to: $1.coordinate) }) {
                let cap = min(fuel.firstLegMaxMeters, fuel.usableRangeMeters, nearest?.distanceMeters ?? .infinity)
                if request.start.distance(to: station.coordinate) > cap + 300 { continue }
                let initial = State(point: request.start, match: nil, arrival: request.options.arrival,
                                    stops: [], routes: [], meters: request.options.precedingMeters,
                                    dirt: request.options.precedingDirtMeters)
                if let route = try hop(initial, to: station.coordinate, endMatches: matches(station),
                                       cap: cap, customer: true),
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
        func commitStop(_ station: FuelStation, route: ComputedRoute) {
            hopOffLineDegrees.append(offLineDegrees(from: current.point, to: station.coordinate))
            hopProgressShare.append(progressRatio(from: current.match, station: station, dest: nil,
                                                  ridden: route.distanceMeters) ?? -1)
            current = stateAfter(current, station: station, route: route)
        }
        func proveEscape(from state: State, remaining: Double) throws -> Double? {
            guard fuel.ensureDestinationEscape else { return 0 }
            for station in candidates.sorted(by: {
                request.end.distance(to: $0.coordinate) < request.end.distance(to: $1.coordinate)
            }) {
                if request.end.distance(to: station.coordinate) > remaining + 150 { continue }
                if let road = try hop(state, to: station.coordinate, endMatches: matches(station),
                                      cap: remaining, customer: true) {
                    return road.distanceMeters
                }
            }
            return nil
        }
        do {
        chain: while true {
            try budget.check()
            visited += 1
            guard visited <= budget.maximumLabels else {
                return failure("no fuel stop found within range near \(placeName(current.point))", state: current)
            }
            let fromRefill = skipFirstPump || !current.stops.isEmpty
            let tank = fromRefill
                ? fuel.usableRangeMeters
                : min(fuel.firstLegMaxMeters, fuel.usableRangeMeters)
            let requiredSatisfied = fuel.requiredFirstStationID == nil
                || !current.stops.isEmpty
                || (skipFirstPump && (fuel.requiredFirstStationID == startPump?.id || fuel.resumeAtPump))
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
            let spacingApplies = fromRefill && fuel.usableRangeMeters >= Self.minimumOnwardPumpLegMeters
            let eligible = candidates.filter { station in
                if used.contains(station.id) { return false }
                if current.stops.isEmpty, skipFirstPump, station.id == startPump?.id { return false }
                if spacingApplies,
                   current.point.distance(to: station.coordinate) < Self.minimumOnwardPumpSeparationMeters {
                    return false
                }
                if current.point.distance(to: station.coordinate) > tank + 150 { return false }
                if !fromRefill, let required = fuel.requiredFirstStationID, station.id != required {
                    return false
                }
                return true
            }

            // Leg 0: nearest reachable pump, only from the rider's own start
            // with unknown fuel. A window that resumes at a pump sweeps on.
            if current.stops.isEmpty, skipFirstPump {
                note("leg0:skip resumeAtPump station=\(startPump?.id ?? "-")")
            } else if current.stops.isEmpty {
                if let already = eligible.first(where: { current.point.distance(to: $0.coordinate) < 50 }),
                   let approach = try hop(current, to: already.coordinate, endMatches: matches(already),
                                          cap: tank, customer: true) {
                    leg0DistanceOnly += 1
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
                    leg0DistanceOnly += 1
                    let dirt = knownDirt(nearest.1)
                    let pct = nearest.1.distanceMeters > 0
                        ? Int((dirt / nearest.1.distanceMeters * 100).rounded()) : 0
                    note("leg0:distance station=\(nearest.0.id) route=\(Int(nearest.1.distanceMeters))m dirt=\(pct)%")
                    commitStop(nearest.0, route: nearest.1)
                    continue
                }
                return failure("no fuel stop found within range near \(placeName(current.point))", state: current)
            }

            // Rules 9–12: one style sweep from the refill. Destination is the
            // end only when that sweep reaches it. Otherwise the fan picks a
            // pump. No shortest pick, flood, or frontier snap after leg 0.
            let endCap = min(tank, fuel.destinationUsedLimitMeters ?? .infinity)
            let (destRoute, reached) = try sweep(current, stations: eligible, cap: endCap)
            let destLoop = fromRefill
                && (destRoute?.distanceMeters ?? .infinity) < Self.minimumOnwardPumpLegMeters
                && destRoute.map { isForecourtLoop($0, from: current.point) } == true
            if destLoop { note("dest:loop") }
            if !destLoop, current.stops.count >= fuel.minimumStops, requiredSatisfied,
               let tail = destRoute, tail.distanceMeters <= endCap + 1 {
                let actualEnd = tail.segments.last?.geometry.last ?? tail.end.coordinate
                let here = current.point.distance(to: request.end)
                let atDest = actualEnd.distance(to: request.end) <= Self.fuelStationSnapMeters
                if atDest, tail.distanceMeters < 5, here <= Self.fuelStationSnapMeters {
                    styleOk += 1
                    note("dest:alreadyHere")
                    let escape = try proveEscape(from: current, remaining: tank)
                    if escape == nil {
                        note("dest:escapeUnproved remaining=\(Int(tank))m allowUnknown=\(request.access.allowUnknown)")
                    }
                    return planResult(stops: current.stops, routes: current.routes,
                                      foundation: nil, complete: true,
                                      limit: current.routes.compactMap(\.limit).first,
                                      destinationEscapeMeters: fuel.ensureDestinationEscape ? escape : nil,
                                      firstReachableStationMeters: nil)
                }
                if atDest, tail.distanceMeters >= 5 {
                    let arrived = stateAfter(current, station: nil, route: tail)
                    let remaining = max(0, tank - tail.distanceMeters)
                    let escape = try proveEscape(from: arrived, remaining: remaining)
                    if escape == nil {
                        note("dest:escapeUnproved remaining=\(Int(remaining))m allowUnknown=\(request.access.allowUnknown)")
                    }
                    styleOk += 1
                    let destMatch = destinationMatches.first
                    hopOffLineDegrees.append(offLineDegrees(from: current.point, to: request.end))
                    hopProgressShare.append(progressRatio(from: current.match, station: nil, dest: destMatch,
                                                          ridden: tail.distanceMeters) ?? -1)
                    note("dest:styleOk route=\(Int(tail.distanceMeters))m progress=\(String(format: "%.2f", hopProgressShare.last ?? -1)) offLine=\(Int((hopOffLineDegrees.last ?? 0).rounded()))°")
                    return planResult(stops: current.stops, routes: current.routes + [tail],
                                      foundation: nil, complete: true,
                                      limit: (current.routes + [tail]).compactMap(\.limit).first,
                                      destinationEscapeMeters: fuel.ensureDestinationEscape ? escape : nil,
                                      firstReachableStationMeters: nil)
                }
            }
            if let pick = pickPump(from: reached, state: current, cap: tank) {
                styleOk += 1
                commitStop(pick.0, route: pick.1)
                continue chain
            }
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
