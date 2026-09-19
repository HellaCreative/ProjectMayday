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
    /// A water-like candidate remains a legal fallback; it is never discarded.
    struct HandoverCandidate {
        let coordinate: Coordinate
        let waterLike: Bool
    }

    /// Dirt only: divide remaining wall-clock across remaining candidates so one
    /// dead pin cannot burn the whole parent budget (Providence 012024Z).
    static func dirtCandidateSliceSeconds(remainingSeconds: Double, candidatesLeft: Int) -> Double {
        let share = max(0, remainingSeconds) / Double(max(1, candidatesLeft))
        return min(20, max(3, share))
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
                             compassStore: RoadCompassStore? = nil) throws -> ComputedRoute {
        let unique = Array(Set(regions)).sorted()
        let startRegion = try containingRegion(request.start, regions: unique, repository: repository,
                                               budget: budget, prepared: prepared)
        let endRegion = try containingRegion(request.end, regions: unique, repository: repository,
                                             budget: budget, prepared: prepared)
        let neighbors = try neighborMap(unique, repository: repository)
        let chain = try RegionConnectivity(neighbors: neighbors).chain(from: startRegion, to: endRegion)
        let windows = overlappingWindows(chain)
        guard windows.count >= 2 else {
            return try routeWindow(windows.first ?? unique, request: request, repository: repository,
                                   budget: budget, prepared: prepared, compassStore: compassStore)
        }
        var parts: [ComputedRoute] = []
        var cursor = request.start
        // Two-pack: try each handover pin as a full stage0+stage1 pair so a
        // pin that is live in the origin half but a stub in the dest half
        // cannot commit the corridor.
        if windows.count == 2, let originPack = windows[0].last, let destPack = windows[1].last {
            // Same staged-aim contract as multi-pack. Two-pack has no onward seam
            // belt, so chainLocalAim returns the rider destination.
            let toward = try chainLocalAim(windows: windows, stageIndex: 0, next: destPack,
                                           finalDestination: request.end, repository: repository)
            let pins = try handoverCandidates(from: originPack, into: destPack, from: cursor,
                                              toward: toward, repository: repository)
            guard !pins.isEmpty else { throw RoutingFailure.noPath }
            let prepareStarted = ContinuousClock.now
            let graphs = try prepared.indexedWindows(windows, repository: repository, budget: budget)
            request.options.counter?.recordStage("prepareWindows", since: prepareStarted)
            let firstGraph = graphs[0]
            let secondGraph = graphs[1]
            var lastError: Error = RoutingFailure.noPath
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
                    hop0.options.compassMaxRemaining = max(450_000, cursor.distance(to: hopEnd) * 2.5)
                    let started0 = ContinuousClock.now
                    let part0 = try RoutingEngine(pack: firstGraph, compassStore: compassStore)
                        .route(hop0, budget: attemptBudget)
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
                    hop1.options.arrivalEdgeID = part0.segments.last?.edgeID
                    hop1.options.counter = request.options.counter
                    let started1 = ContinuousClock.now
                    let part1 = try RoutingEngine(pack: secondGraph, compassStore: compassStore)
                        .route(hop1, budget: attemptBudget)
                    hop1.options.counter?.recordStage("stage1:\(windows[1].joined(separator: ","))", since: started1)
                    return stitch([part0, part1], windows: windows)
                } catch RoutingFailure.noPath {
                    lastError = RoutingFailure.noPath
                    continue
                } catch RoutingFailure.noMatch {
                    lastError = RoutingFailure.noMatch
                    continue
                } catch let RoutingFailure.resourceLimit(kind) where kind == "labels" || kind == "time" {
                    // Providence Dirt (012024Z) burned 60s on a dead nb→me pin;
                    // try the next diversified handover instead of aborting.
                    lastError = RoutingFailure.resourceLimit(kind)
                    continue
                }
            }
            throw lastError
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
        for (index, window) in windows.enumerated() {
            try budget.check()
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
                    repository: repository
                )
                candidates = try handoverCandidates(
                    from: shared,
                    into: next,
                    from: cursor,
                    toward: toward,
                    repository: repository
                )
            } else {
                candidates = [request.end]
            }
            guard !candidates.isEmpty else { throw RoutingFailure.noPath }
            // Open the stage graph once; stub seams must not re-decode a 100MB pack.
            let indexed = try openWindow(window, repository: repository, budget: budget, prepared: prepared)
            // Prefetch the window after next while this stage searches.
            var prefetch: DispatchWorkItem?
            if index + 2 < windows.count {
                prefetch = prepared.prefetch(windows[index + 2], repository: repository, budget: budget)
            }
            defer { prefetch?.wait() }
            var lastError: Error = RoutingFailure.noPath
            var advanced = false
            var reach: EndpointReachability?
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
                }
                let candidatesLeft = max(1, candidates.count - attempt)
                let sliceSeconds = request.profile.style == .dirt && index + 1 < windows.count && candidatesLeft > 1
                    ? dirtCandidateSliceSeconds(remainingSeconds: budget.remainingSeconds,
                                                candidatesLeft: candidatesLeft)
                    : budget.remainingSeconds
                let attemptBudget = budgetForHandoverCandidate(
                    budget, style: request.profile.style, attempt: attempt, candidateCount: candidates.count)
                var hop = request.with(start: cursor, end: hopEnd)
                let span = cursor.distance(to: hopEnd)
                hop.options.compassMaxRemaining = max(450_000, span * 2.5)
                if let previous = parts.last {
                    hop.options.precedingMeters = parts.reduce(0) { $0 + $1.distanceMeters }
                    hop.options.precedingDirtMeters = parts.reduce(0) { $0 + knownDirtMeters($1) }
                    hop.options.arrivalEdgeID = previous.segments.last?.edgeID
                }
                let started = ContinuousClock.now
                do {
                    let part = try RoutingEngine(pack: indexed, compassStore: compassStore)
                        .route(hop, budget: attemptBudget)
                    hop.options.counter?.recordStage(
                        "stage\(index):\(window.joined(separator: ","))", since: started)
                    if attempt > 0 {
                        hop.options.counter?.recordStage("handoverRetry:\(attempt)", since: started)
                    }
                    if request.profile.style == .dirt, index + 1 < windows.count {
                        hop.options.counter?.recordStage(
                            "handoverSlice:\(attempt):\(Int(sliceSeconds.rounded()))s", since: started)
                    }
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
                    lastError = RoutingFailure.resourceLimit(kind)
                    continue
                }
            }
            if !advanced { throw lastError }
        }
        return stitch(parts, windows: windows)
    }

    static func neighborMap(_ regions: [String], repository: PackRepository) throws -> [String:Set<String>] {
        let wanted = Set(regions)
        var map: [String:Set<String>] = [:]
        for id in regions {
            let present = Set(try repository.loadSeams(id).neighbors.keys).intersection(wanted)
            map[id, default: []].formUnion(present)
            for neighbor in present { map[neighbor, default: []].insert(id) }
        }
        return map
    }

    static func containingRegion(_ point: Coordinate, regions: [String], repository: PackRepository,
                                 budget: ComputationBudget,
                                 prepared: PreparedGraphStore = PreparedGraphStore()) throws -> String {
        let ranked = regions.sorted { repository.graphBytes($0) < repository.graphBytes($1) }
        for (index, id) in ranked.enumerated() {
            try budget.check()
            if index == ranked.count - 1 { return id }
            // Warm IndexedGraph beats a cold open when a prior hop already prepared it.
            if let warm = prepared.peek([id]), sampledBox(warm).contains(point) {
                return id
            }
            let pack = try repository.open(id, requireSeams: false, budget: budget)
            if sampledBox(pack.graph).contains(point) { return id }
        }
        throw RoutingFailure.noMatch
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
                                   toward dest: Coordinate, repository: PackRepository) throws -> [Coordinate] {
        let anchors = try repository.loadSeams(shared).neighbors[next]
            ?? repository.loadSeams(next).neighbors[shared]
            ?? []
        // Group by seam node so a land-backed crossing demotes ferry proofs at
        // the same pin rather than competing as duplicate coordinates.
        var groups: [String: HandoverCandidate] = [:]
        for row in anchors {
            guard row.coordinate.count == 2 else { continue }
            let point = Coordinate(longitude: row.coordinate[0], latitude: row.coordinate[1])
            guard point.isValid else { continue }
            let key = row.osmNodeId.isEmpty
                ? String(format: "%.5f,%.5f", point.longitude, point.latitude)
                : row.osmNodeId
            let water = isWaterLike(row.edge)
            if let existing = groups[key] {
                groups[key] = .init(coordinate: existing.coordinate,
                                    waterLike: existing.waterLike && water)
            } else {
                groups[key] = .init(coordinate: point, waterLike: water)
            }
        }
        return pickHandoverCandidates(from: Array(groups.values), origin: origin, toward: dest,
                                      limit: handoverCandidateLimit)
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
    static func chainLocalAim(
        windows: [[String]],
        stageIndex: Int,
        next: String,
        finalDestination: Coordinate,
        repository: PackRepository
    ) throws -> Coordinate {
        guard stageIndex + 2 < windows.count, let following = windows[stageIndex + 2].last else {
            return finalDestination
        }
        let anchors = try repository.loadSeams(next).neighbors[following]
            ?? repository.loadSeams(following).neighbors[next]
            ?? []
        let points = anchors.compactMap { row -> Coordinate? in
            guard row.coordinate.count == 2 else { return nil }
            let point = Coordinate(longitude: row.coordinate[0], latitude: row.coordinate[1])
            return point.isValid ? point : nil
        }
        return centroid(of: points) ?? finalDestination
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
    /// several diversified pins. Land-backed groups rank before water-like.
    static func pickHandoverCandidates(from points: [Coordinate], origin: Coordinate,
                                       toward dest: Coordinate, limit: Int) -> [Coordinate] {
        pickHandoverCandidates(from: points.map {
            .init(coordinate: $0, waterLike: false)
        }, origin: origin, toward: dest, limit: limit)
    }

    static func pickHandoverCandidates(from points: [HandoverCandidate], origin: Coordinate,
                                       toward dest: Coordinate, limit: Int) -> [Coordinate] {
        guard !points.isEmpty, limit > 0 else { return [] }
        let direct = max(1, origin.distance(to: dest))
        let ranked = points.map { point -> (score: Double, point: Coordinate, waterLike: Bool) in
            let via = origin.distance(to: point.coordinate) + point.coordinate.distance(to: dest)
            return (via / direct, point.coordinate, point.waterLike)
        }.sorted {
            if $0.waterLike != $1.waterLike { return !$0.waterLike }
            return $0.score < $1.score
        }

        // Keep the best pin per ~0.4° longitude cell so western stubs cannot
        // crowd out the connected Hwy 69 / French River band.
        var byCell: [Int:(score: Double, point: Coordinate, waterLike: Bool)] = [:]
        for row in ranked {
            let cell = Int((row.point.longitude * 2.5).rounded(.towardZero))
            if byCell[cell] == nil { byCell[cell] = row }
        }
        let diversified = byCell.values.sorted {
            if $0.waterLike != $1.waterLike { return !$0.waterLike }
            return $0.score < $1.score
        }.map(\.point)
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
        if ordered.isEmpty, let first = ranked.first?.point { ordered = [first] }
        return Array(ordered.prefix(limit))
    }

    static func pickHandover(from points: [Coordinate], origin: Coordinate, toward dest: Coordinate) -> Coordinate? {
        pickHandoverCandidates(from: points, origin: origin, toward: dest, limit: 1).first
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
        guard let start = starts.first, let end = ends.first else { return false }
        let components = WeakComponents.ids(in: graph, allowUnknown: request.access.allowUnknown)
        if WeakComponents.of(match: start, pack: graph, ids: components)
            != WeakComponents.of(match: end, pack: graph, ids: components) {
            return false
        }
        let checker = try reach ?? EndpointReachability(graph: graph, budget: budget)
        reach = checker
        return try checker.mayConnect(start: start, end: end, budget: budget)
    }

    static func knownDirtMeters(_ route: ComputedRoute) -> Double {
        route.segments.filter { $0.structure != "ferry" && ($0.surface == .gravel || $0.surface == .loose) }
            .reduce(0) { $0 + $1.meters }
    }

    static func stitch(_ parts: [ComputedRoute], windows: [[String]]) -> ComputedRoute {
        guard let first = parts.first, let last = parts.last else {
            return ComputedRoute(start: RoadMatch(edge: 0, coordinate: .init(longitude: 0, latitude: 0),
                                                  distanceMeters: 0, alongMeters: 0, geometryMeters: 0),
                                 end: RoadMatch(edge: 0, coordinate: .init(longitude: 0, latitude: 0),
                                                distanceMeters: 0, alongMeters: 0, geometryMeters: 0),
                                 segments: [], distanceMeters: 0, searchCost: 0, poppedLabels: 0,
                                 arrivalRestrictions: [])
        }
        var segments: [RouteSegment] = []
        for (index, part) in parts.enumerated() {
            if index > 0, let previous = segments.last, let next = part.segments.first,
               previous.edgeID == next.edgeID, previous.edgeID.isEmpty == false {
                segments.append(contentsOf: part.segments.dropFirst())
            } else {
                segments.append(contentsOf: part.segments)
            }
        }
        var combined = ComputedRoute(start: first.start, end: last.end, segments: segments,
                                     distanceMeters: segments.reduce(0) { $0 + $1.meters },
                                     searchCost: parts.reduce(0) { $0 + $1.searchCost },
                                     poppedLabels: parts.reduce(0) { $0 + $1.poppedLabels },
                                     arrivalRestrictions: last.arrivalRestrictions)
        let labels = zip(windows, parts).map { window, part in
            "stage:\(window.joined(separator: "+"))[\(part.searchSummary ?? "-")]"
        }
        combined.searchSummary = labels.joined(separator: ",")
        return combined
    }
}
