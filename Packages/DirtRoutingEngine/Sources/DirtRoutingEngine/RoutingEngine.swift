import Foundation

public struct RoutingRequest: Sendable {
    public let start: Coordinate
    public let end: Coordinate
    public var profile: ProfilePolicy
    public var access: AccessPolicy
    public var options: SearchOptions
    public var matchRadiusMeters: Double
    public var mapZoom: Double?
    public init(start: Coordinate,end: Coordinate,style: RidingStyle,allowUnknown: Bool = false,seed: UInt64 = 0) {
        self.start = start; self.end = end; profile = .init(style: style)
        access = .init(allowUnknown: style == .cleanest ? false : allowUnknown)
        options = .init(); options.seed = seed; matchRadiusMeters = 250
    }
}

/// Orchestrates local matching, profile candidates and selection. Contains no HTTP client,
/// JavaScript runtime, download callback or old native-engine fallback.
public struct RoutingEngine: Sendable {
    let pack: any RoadGraph
    let compassStore: RoadCompassStore?
    public init(pack: any RoadGraph, compassStore: RoadCompassStore? = nil) {
        self.pack = pack
        self.compassStore = compassStore
    }
    struct Candidate {
        let route: ComputedRoute
        let width: Double
        let quality: RouteQuality
    }
    /// Corridor width for diagnostics. The widest pass is unbounded, and converting
    /// infinity to an integer traps.
    static func widthLabel(_ meters: Double) -> String {
        meters.isFinite ? "\(Int(meters))m" : "∞"
    }
    public func route(_ request: RoutingRequest,budget: ComputationBudget = .init(seconds: 45)) throws -> ComputedRoute {
        try budget.check()
        let matcher = RoadMatcher(pack: pack)
        let radius = min(2000,max(80,request.mapZoom.map { 28*156543.03392*cos(request.end.latitude * .pi/180)/pow(2,$0) } ?? request.matchRadiusMeters))
        // JS outer router scores B against the reverse of A→B so arrival travel
        // faces the pin. Using the same bearing for both ends selected the wrong
        // carriageway on the short NS comparison.
        let intent = request.start.bearing(to: request.end)*180 / .pi
        let matchStarted = ContinuousClock.now
        let starts = try matcher.matches(at: request.start,radius: radius,start: true,policy: request.access,intent: intent,budget: budget)
        let ends = try matcher.matches(at: request.end,radius: radius,start: false,policy: request.access,intent: intent+180,budget: budget)
        request.options.counter?.recordStage("match", since: matchStarted)
        guard !starts.isEmpty, !ends.isEmpty else { throw RoutingFailure.noMatch }
        // JS `selectConnectedSnapPair`: score stays on each directed candidate;
        // connectivity is a later filter, not a rescore. Prefer the same weak
        // component so a closer island cannot steal the destination road.
        let components = WeakComponents.ids(in: pack, allowUnknown: request.access.allowUnknown)
        var lastFailure: RoutingFailure = .noPath
        let pairs = starts.flatMap { start in ends.map { (start,$0) } }.enumerated().sorted {
            let a = $0.element.0.score+$0.element.1.score, b = $1.element.0.score+$1.element.1.score
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        let connected = pairs.filter {
            WeakComponents.of(match: $0.0, pack: pack, ids: components)
                == WeakComponents.of(match: $0.1, pack: pack, ids: components)
        }
        var reachability: EndpointReachability?
        var attempted = false
        var triedPairs = Set<String>()
        for (start,end) in (connected.isEmpty ? pairs : connected) {
                try budget.check()
                // Matches that differ only in destination direction now search identically.
                guard triedPairs.insert("\(start.edge):\(String(describing: start.forward)):\(start.alongMeters)|\(end.edge):\(end.alongMeters)").inserted else { continue }
                if attempted {
                    // After a pair has failed, rule out pairs that cannot connect before
                    // searching them: each would only flood every corridor to "no path".
                    let checkStarted = ContinuousClock.now
                    let checker = try reachability ?? EndpointReachability(graph: pack,budget: budget)
                    reachability = checker
                    let possible = try checker.mayConnect(start: start,end: end,budget: budget)
                    request.options.counter?.recordStage("reachability", since: checkStarted)
                    guard possible else { lastFailure = .noPath; continue }
                }
                attempted = true
                do { return try route(request,start: start,end: end,budget: budget) }
                catch let error as RoutingFailure {
                    if error != .noPath { throw error }
                    lastFailure = error
                }
        }
        throw lastFailure
    }
    public func route(_ request: RoutingRequest,start: RoadMatch,end: RoadMatch,budget: ComputationBudget) throws -> ComputedRoute {
        var request = request
        if ProcessInfo.processInfo.environment["DIRT_NO_CITY_WALL"] == "1" {
            request.options.cityWall = false
        }
        let search = PathSearch(pack: pack)
        let compassStarted = ContinuousClock.now
        let compass: RoadCompass?
        do {
            // The compass ignores access, so Allow Unknown shares it; the graph size
            // keeps a store that outlives a region change from reusing another graph's table.
            let key = "\(pack.nodeCount):\(pack.edgeCount):\(end.edge):\(end.alongMeters)"
            if let store = compassStore {
                compass = .init(remaining: try store.remaining(for: key) {
                    try RoadCompass.toward(end: end, pack: pack, budget: budget).remaining
                })
            } else {
                compass = try RoadCompass.toward(end: end, pack: pack, budget: budget)
            }
        }
        catch is CancellationError { throw CancellationError() }
        catch { compass = nil }
        request.options.counter?.recordStage("compass", since: compassStarted)
        func run(_ options: SearchOptions, policy: ProfilePolicy? = nil) throws -> ComputedRoute {
            var options = options
            options.roadRemaining = compass?.remaining
            return try search.search(start: start,end: end,policy: policy ?? request.profile,access: request.access,options: options,budget: budget)
        }
        if request.profile.style == .cleanest {
            return try cleanest(request, run: run, budget: budget)
        }
        if request.profile.style == .balanced {
            return try balanced(request, run: run, budget: budget)
        }
        var candidateLog: [String] = []
        var cap = request.options.maximumMeters
        let base = request.profile.corridorMeters(straightLine: request.start.distance(to: request.end))
        // Dirt scores 120 km then 60 km. Wider bands are connectivity only:
        // stop at the first one that connects. Repeating 180/240/∞ on the owner
        // replay produced the identical 63.3% ride and burned the phone's 60 s.
        let multipliers: [Double] = [2,1,3,4,.infinity]
        var candidates: [Candidate] = []
        var incomplete: RoutingFailure?
        var comparisonFound = false
        var failedWidth = Double.infinity
        var repeatable: (width: Double, route: ComputedRoute, quality: RouteQuality)?
        for multiplier in multipliers {
            let width = base*multiplier
            let comparison = multiplier <= 2
            if failedWidth.isFinite, width < failedWidth { continue }
            if !comparison, !candidates.isEmpty { break }
            var options = request.options
            options.objective = .pavement
            options.maximumMeters = cap
            options.corridorMeters = width
            let boundary = SearchBoundary()
            options.boundary = boundary
            do {
                var route: ComputedRoute
                var quality: RouteQuality
                if let repeatable, width >= repeatable.width {
                    // Every search at a narrower width finished without turning a road away
                    // at its corridor or progress limit, so this wider pass repeats them exactly.
                    route = repeatable.route
                    quality = repeatable.quality
                } else {
                    let failureBefore = incomplete
                    route = try run(options)
                    quality = RouteQuality(route: route,urbanBoxes: UrbanCores.boxes(in: pack))
                    if route.limit == nil && quality.knownDirtPercent < 70 {
                        for _ in 0..<3 {
                            let penalties = RouteQuality.shortDirtExcursions(route.segments)
                            if penalties.isSubset(of: options.penalizedDirtEdges) { break }
                            options.penalizedDirtEdges.formUnion(penalties)
                            do { route = try run(options) }
                            catch RoutingFailure.noPath { break }
                            catch let failure as RoutingFailure { incomplete = failure; break }
                            quality = RouteQuality(route: route,urbanBoxes: UrbanCores.boxes(in: pack))
                            if quality.knownDirtPercent >= 70 { break }
                        }
                    }
                    if !boundary.touched, route.limit == nil, incomplete == failureBefore {
                        repeatable = (width,route,quality)
                    }
                }
                candidates.append(.init(route: route,width: options.corridorMeters,quality: quality))
                if comparison { comparisonFound = true }
                candidateLog.append("\(Self.widthLabel(options.corridorMeters))/\(Int(quality.knownDirtPercent))%/\(Int(route.distanceMeters))m/\(route.poppedLabels)p\(route.limit.map { "/\($0)" } ?? "")")
                if ProcessInfo.processInfo.environment["DIRT_ROUTE_CANDIDATES"] == "1" {
                    FileHandle.standardError.write(Data("candidate width=\(options.corridorMeters) dirt=\(quality.knownDirtPercent) m=\(route.distanceMeters) pops=\(route.poppedLabels) urban=\(quality.urbanMeters) back=\(quality.backwardMeters)\n".utf8))
                }
                if quality.knownDirtPercent >= 70 { break }
                if !comparison { break }
                if !candidates.isEmpty, budget.remainingSeconds < 8 { break }
            } catch RoutingFailure.noPath {
                if width.isFinite { failedWidth = min(failedWidth,width) }
                // No road was turned away at this width's limits, so every wider corridor
                // sees the same roads and ends in "no path" too.
                if !boundary.touched { break }
                continue
            }
            catch let failure as RoutingFailure { incomplete = failure; break }
        }
        if comparisonFound, incomplete == nil, budget.remainingSeconds >= 5,
           let best = candidates.map(\.quality.knownDirtPercent).max(), best < 70, best >= 40 {
            var recovery = request.options
            recovery.objective = .balancedResource; recovery.corridorMeters = base
            if let primary = chooseDirt(candidates) {
                recovery.maximumMeters = min(cap,max(primary.route.distanceMeters+40_000,primary.route.distanceMeters*1.5))
            }
            let recoveryBudget = budget.limited(to: min(5, budget.remainingSeconds * 0.4))
            func runRecovery(_ options: SearchOptions) throws -> ComputedRoute {
                var options = options
                options.roadRemaining = compass?.remaining
                return try search.search(start: start,end: end,policy: request.profile,access: request.access,options: options,budget: recoveryBudget)
            }
            do {
                let recoveryStarted = ContinuousClock.now
                defer { request.options.counter?.recordStage("recovery", since: recoveryStarted) }
                let route = try runRecovery(recovery)
                let quality = RouteQuality(route: route,urbanBoxes: UrbanCores.boxes(in: pack))
                candidates.append(.init(route: route,width: base,quality: quality))
                candidateLog.append("R:\(Self.widthLabel(base))/\(Int(quality.knownDirtPercent))%/\(Int(route.distanceMeters))m/\(route.poppedLabels)p")
                if ProcessInfo.processInfo.environment["DIRT_ROUTE_CANDIDATES"] == "1" {
                    FileHandle.standardError.write(Data("candidate recovery width=\(base) dirt=\(quality.knownDirtPercent) m=\(route.distanceMeters) pops=\(route.poppedLabels) urban=\(quality.urbanMeters) back=\(quality.backwardMeters)\n".utf8))
                }
            } catch RoutingFailure.noPath { }
            catch RoutingFailure.resourceLimit { }
            catch let failure as RoutingFailure { incomplete = failure }
        }
        let summary = candidateLog.isEmpty ? nil : candidateLog.joined(separator: ",")
        let limitNote = incomplete.map { "comparison incomplete: \($0)" }
        if let selected = chooseDirt(candidates) {
            var result = selected.route.reportingLimit(limitNote)
            result.searchSummary = summary
            return result
        }
        if let incomplete { throw incomplete }
        throw RoutingFailure.noPath
    }
    /// Clean: shortest legal route (motorway/trunk only if nothing else connects),
    /// then a back-road profile that cannot exceed 1.12× that length.
    private func cleanest(_ request: RoutingRequest,
                          run: (SearchOptions, ProfilePolicy?) throws -> ComputedRoute,
                          budget: ComputationBudget) throws -> ComputedRoute {
        func shortest(allowHighways: Bool, cityWall: Bool, pavedOnly: Bool) throws -> ComputedRoute {
            var options = request.options
            options.objective = .distance
            options.corridorMeters = .infinity
            options.maximumMeters = .infinity
            options.pavedOnly = pavedOnly
            options.cityWall = cityWall
            options.varietyEnabled = false
            var policy = request.profile
            policy.cleanAllowHighways = allowHighways
            return try run(options, policy)
        }
        var policy = request.profile
        let attempts: [(allowHighways: Bool, cityWall: Bool, pavedOnly: Bool)] = [
            (false, true, true),
            (false, true, false),
            (false, false, false),
            (true, false, false)
        ]
        var direct: ComputedRoute?
        var used = attempts[0]
        for attempt in attempts {
            try budget.check()
            policy.cleanAllowHighways = attempt.allowHighways
            do {
                direct = try shortest(allowHighways: attempt.allowHighways,
                                      cityWall: attempt.cityWall,
                                      pavedOnly: attempt.pavedOnly)
                used = attempt
                break
            } catch RoutingFailure.noPath { }
        }
        guard let direct else { throw RoutingFailure.noPath }
        var profile = request.options
        profile.objective = .profile
        profile.corridorMeters = .infinity
        profile.maximumMeters = direct.distanceMeters * 1.12
        profile.pavedOnly = used.pavedOnly
        profile.cityWall = used.cityWall
        do {
            let route = try run(profile, policy)
            if route.distanceMeters <= profile.maximumMeters { return route }
        } catch RoutingFailure.noPath { }
        return direct
    }
    /// Bounded 50/50 Balanced: shortest path plus at most two profile searches
    /// whose dirt weight is steered toward 45–55%. Stops at B; no resource flood.
    private func balanced(_ request: RoutingRequest,
                          run: (SearchOptions, ProfilePolicy?) throws -> ComputedRoute,
                          budget: ComputationBudget) throws -> ComputedRoute {
        var shortest = request.options
        shortest.objective = .distance
        shortest.corridorMeters = .infinity
        let direct = try run(shortest, nil)
        let boxes = UrbanCores.boxes(in: pack)
        func quality(_ route: ComputedRoute) -> RouteQuality {
            RouteQuality(route: route, urbanBoxes: boxes)
        }
        func note(_ mix: String, _ route: ComputedRoute, _ quality: RouteQuality) -> String {
            "\(mix)/\(Int(quality.knownDirtPercent))%/\(Int(route.distanceMeters))m/\(route.poppedLabels)p"
        }
        var candidates: [Candidate] = [.init(route: direct, width: .infinity, quality: quality(direct))]
        var log = [note("shortest", direct, candidates[0].quality)]
        func profile(_ mix: Double) throws -> Candidate {
            try budget.check()
            var options = request.options
            options.objective = .profile
            options.maximumMeters = .infinity
            options.corridorMeters = .infinity
            var policy = request.profile
            policy.balancedDirtPreference = mix
            let route = try run(options, policy)
            return .init(route: route, width: .infinity, quality: quality(route))
        }
        func inBand(_ quality: RouteQuality) -> Bool {
            (45...55).contains(quality.knownDirtPercent) && quality.urbanMeters <= 100
        }
        if !inBand(candidates[0].quality) {
            let firstMix = candidates[0].quality.knownDirtPercent < 45 ? 1.0 : 0.0
            do {
                let first = try profile(firstMix)
                candidates.append(first)
                log.append(note(firstMix == 1 ? "mix1" : "mix0", first.route, first.quality))
                if !inBand(first.quality) {
                    do {
                        let mid = try profile(0.5)
                        candidates.append(mid)
                        log.append(note("mix0.5", mid.route, mid.quality))
                    } catch RoutingFailure.noPath { }
                }
            } catch RoutingFailure.noPath { }
        }
        let band = candidates.filter { inBand($0.quality) }
        let pool = band.isEmpty ? candidates : band
        let selected = pool.min { a, b in
            let da = abs(a.quality.knownDirtPercent - 50), db = abs(b.quality.knownDirtPercent - 50)
            if abs(da - db) > 2 { return da < db }
            return a.route.distanceMeters < b.route.distanceMeters
        } ?? candidates[0]
        var result = selected.route
        result.searchSummary = log.joined(separator: ",")
        return result
    }
    private func chooseDirt(_ candidates: [Candidate]) -> Candidate? {
        let coherent = candidates.filter { $0.quality.backwardMeters <= max(5000,$0.quality.totalMeters*0.08) }
        let best = candidates.map(\.quality.knownDirtPercent).max() ?? 0
        let bestCoherent = coherent.map(\.quality.knownDirtPercent).max() ?? -.infinity
        let pool = !coherent.isEmpty && best-bestCoherent < 10 ? coherent : candidates
        return pool.min { RouteQuality.prefersDirt($0.quality,over: $1.quality,widthA: $0.width,widthB: $1.width) }
    }
}
