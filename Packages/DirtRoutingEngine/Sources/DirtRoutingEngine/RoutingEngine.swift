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
        for (start,end) in (connected.isEmpty ? pairs : connected) {
                try budget.check()
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
            let key = "\(end.edge):\(end.alongMeters):\(request.access.allowUnknown)"
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
        func run(_ options: SearchOptions) throws -> ComputedRoute {
            var options = options
            options.roadRemaining = compass?.remaining
            return try search.search(start: start,end: end,policy: request.profile,access: request.access,options: options,budget: budget)
        }
        if request.profile.style == .cleanest {
            var clean = request.options
            clean.objective = .profile; clean.corridorMeters = .infinity; clean.pavedOnly = true
            do { return try run(clean) } catch RoutingFailure.noPath { }
            clean.pavedOnly = false
            do { return try run(clean) } catch RoutingFailure.noPath { }
            clean.cityWall = false
            return try run(clean)
        }
        var candidateLog: [String] = []
        var direct: ComputedRoute?
        var cap = request.options.maximumMeters
        if request.profile.style == .balanced {
            var shortest = request.options
            shortest.objective = .distance; shortest.corridorMeters = .infinity
            direct = try run(shortest)
            cap = min(cap,(direct?.distanceMeters ?? .infinity)+40_000)
        }
        let isDirt = request.profile.style == .dirt
        let base = request.profile.corridorMeters(straightLine: request.start.distance(to: request.end))
        // Dirt scores 120 km then 60 km. Wider bands are connectivity only:
        // stop at the first one that connects. Repeating 180/240/∞ on the owner
        // replay produced the identical 63.3% ride and burned the phone's 60 s.
        let multipliers: [Double] = isDirt ? [2,1,3,4,.infinity] : request.start.distance(to: request.end) > 500_000 ? [2,3,4,6,8,.infinity] : [1,2,3,4,6,8,.infinity]
        var candidates: [Candidate] = []
        var incomplete: RoutingFailure?
        var comparisonFound = false
        var failedWidth = Double.infinity
        for multiplier in multipliers {
            let width = base*multiplier
            let comparison = !isDirt || multiplier <= 2
            if failedWidth.isFinite, width < failedWidth { continue }
            if isDirt, !comparison, !candidates.isEmpty { break }
            var options = request.options
            options.objective = isDirt ? .pavement : .balancedResource
            options.maximumMeters = cap
            options.corridorMeters = width
            do {
                var route = try run(options)
                var quality = RouteQuality(route: route,urbanBoxes: UrbanCores.boxes(in: pack))
                if isDirt && route.limit == nil && quality.knownDirtPercent < 70 {
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
                candidates.append(.init(route: route,width: options.corridorMeters,quality: quality))
                if comparison { comparisonFound = true }
                candidateLog.append("\(Self.widthLabel(options.corridorMeters))/\(Int(quality.knownDirtPercent))%/\(Int(route.distanceMeters))m/\(route.poppedLabels)p\(route.limit.map { "/\($0)" } ?? "")")
                if ProcessInfo.processInfo.environment["DIRT_ROUTE_CANDIDATES"] == "1" {
                    FileHandle.standardError.write(Data("candidate width=\(options.corridorMeters) dirt=\(quality.knownDirtPercent) m=\(route.distanceMeters) pops=\(route.poppedLabels) urban=\(quality.urbanMeters) back=\(quality.backwardMeters)\n".utf8))
                }
                if isDirt && quality.knownDirtPercent >= 70 { break }
                if isDirt && !comparison { break }
                if isDirt, !candidates.isEmpty, budget.remainingSeconds < 8 { break }
                if !isDirt && (45...55).contains(quality.knownDirtPercent) && quality.urbanMeters <= 100 { return route }
            } catch RoutingFailure.noPath {
                if width.isFinite { failedWidth = min(failedWidth,width) }
                continue
            }
            catch let failure as RoutingFailure { incomplete = failure; break }
        }
        if isDirt, comparisonFound, incomplete == nil, budget.remainingSeconds >= 5,
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
        if isDirt, let selected = chooseDirt(candidates) {
            var result = selected.route.reportingLimit(limitNote)
            result.searchSummary = summary
            return result
        }
        if let selected = candidates.min(by: {
            if abs($0.quality.urbanMeters-$1.quality.urbanMeters) > 100 { return $0.quality.urbanMeters < $1.quality.urbanMeters }
            let a = abs($0.quality.knownDirtPercent-50), b = abs($1.quality.knownDirtPercent-50)
            return a == b ? $0.route.distanceMeters < $1.route.distanceMeters : a < b
        }) {
            var result = selected.route.reportingLimit(limitNote)
            result.searchSummary = summary
            return result
        }
        if let direct, direct.distanceMeters <= request.options.maximumMeters+0.01 {
            var result = direct.reportingLimit(limitNote ?? "no balanced candidate; shortest legal route")
            result.searchSummary = summary
            return result
        }
        if let incomplete { throw incomplete }
        throw RoutingFailure.noPath
    }
    private func chooseDirt(_ candidates: [Candidate]) -> Candidate? {
        let coherent = candidates.filter { $0.quality.backwardMeters <= max(5000,$0.quality.totalMeters*0.08) }
        let best = candidates.map(\.quality.knownDirtPercent).max() ?? 0
        let bestCoherent = coherent.map(\.quality.knownDirtPercent).max() ?? -.infinity
        let pool = !coherent.isEmpty && best-bestCoherent < 10 ? coherent : candidates
        return pool.min { RouteQuality.prefersDirt($0.quality,over: $1.quality,widthA: $0.width,widthB: $1.width) }
    }
}
