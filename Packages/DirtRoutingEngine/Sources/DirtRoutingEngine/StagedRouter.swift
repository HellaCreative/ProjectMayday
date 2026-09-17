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
                             regions: [String], budget: ComputationBudget) throws -> ComputedRoute {
        let unique = Array(Set(regions)).sorted()
        let startRegion = try containingRegion(request.start, regions: unique, repository: repository, budget: budget)
        let endRegion = try containingRegion(request.end, regions: unique, repository: repository, budget: budget)
        let neighbors = try neighborMap(unique, repository: repository)
        let chain = try RegionConnectivity(neighbors: neighbors).chain(from: startRegion, to: endRegion)
        let windows = overlappingWindows(chain)
        guard windows.count >= 2 else {
            return try routeWindow(windows.first ?? unique, request: request, repository: repository, budget: budget)
        }
        var parts: [ComputedRoute] = []
        var cursor = request.start
        for (index, window) in windows.enumerated() {
            try budget.check()
            let hopEnd: Coordinate
            if index + 1 < windows.count, let next = windows[index + 1].last, let shared = window.last {
                hopEnd = try handover(from: shared, into: next, from: cursor, toward: request.end, repository: repository)
            } else {
                hopEnd = request.end
            }
            var hop = request.with(start: cursor, end: hopEnd)
            let span = cursor.distance(to: hopEnd)
            hop.options.compassMaxRemaining = max(450_000, span * 2.5)
            if let previous = parts.last {
                hop.options.precedingMeters = parts.reduce(0) { $0 + $1.distanceMeters }
                hop.options.precedingDirtMeters = parts.reduce(0) { $0 + knownDirtMeters($1) }
                hop.options.arrivalEdgeID = previous.segments.last?.edgeID
            }
            let started = ContinuousClock.now
            let part = try routeWindow(window, request: hop, repository: repository, budget: budget)
            hop.options.counter?.recordStage("stage\(index):\(window.joined(separator: ","))", since: started)
            parts.append(part)
            cursor = part.end.coordinate
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
                                 budget: ComputationBudget) throws -> String {
        let ranked = regions.sorted { repository.graphBytes($0) < repository.graphBytes($1) }
        for (index, id) in ranked.enumerated() {
            try budget.check()
            if index == ranked.count - 1 { return id }
            let pack = try repository.open(id, requireSeams: false, budget: budget)
            if sampledBox(pack.graph).contains(point) { return id }
        }
        throw RoutingFailure.noMatch
    }

    static func sampledBox(_ pack: GraphPack) -> GeographicBox {
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        let step = max(1, pack.nodeCount / 4_000)
        for node in stride(from: 0, to: pack.nodeCount, by: step) {
            let point = pack.coordinate(node: node)
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
        let anchors = try repository.loadSeams(shared).neighbors[next]
            ?? repository.loadSeams(next).neighbors[shared]
            ?? []
        let points = anchors.compactMap { row -> Coordinate? in
            guard row.coordinate.count == 2 else { return nil }
            let point = Coordinate(longitude: row.coordinate[0], latitude: row.coordinate[1])
            return point.isValid ? point : nil
        }
        // Prefer seams on the origin→dest corridor, not merely nearest the
        // destination (that pulled ON-S/ON-N onto eastern cut stubs for
        // London→Thunder Bay while the highway corridor sits west).
        func corridorScore(_ point: Coordinate) -> Double {
            let via = origin.distance(to: point) + point.distance(to: dest)
            let direct = max(1, origin.distance(to: dest))
            let detour = via / direct
            let spread = points
                .map { $0.distance(to: point) }
                .sorted()
            let nearestNeighbor = spread.dropFirst().first ?? 0
            // Soft preference for ≥8 km spacing so one stub cluster cannot
            // monopolise the top ranks.
            let spacingBonus = min(1, nearestNeighbor / 8_000)
            return detour - 0.05 * spacingBonus
        }
        guard let best = points.min(by: { corridorScore($0) < corridorScore($1) }) else {
            throw RoutingFailure.noPath
        }
        return best
    }

    static func routeWindow(_ regions: [String], request: RoutingRequest, repository: PackRepository,
                            budget: ComputationBudget) throws -> ComputedRoute {
        let packs = try regions.map { try repository.open($0, requireSeams: regions.count > 1, budget: budget) }
        guard let first = packs.first else { throw RoutingFailure.missingPacks(regions) }
        let graph: any RoadGraph = packs.count == 1 ? first.graph : try RegionalGraph(packs: packs, budget: budget)
        let indexed = try IndexedGraph(graph, budget: budget)
        return try RoutingEngine(pack: indexed).route(request, budget: budget)
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
