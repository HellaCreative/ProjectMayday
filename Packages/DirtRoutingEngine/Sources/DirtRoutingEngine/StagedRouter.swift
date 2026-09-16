import Foundation

/// Internal stages for a rider-to-rider leg that spans three or more packs.
/// Each window prepares and compasses only two neighbouring packs, then the
/// segments are stitched into one itinerary with no extra waypoints.
public enum StagedRouter {
    public static let longGeodesicMeters = 400_000.0

    public static func shouldStage(regionCount: Int, start: Coordinate, end: Coordinate) -> Bool {
        regionCount >= 3 && start.distance(to: end) > longGeodesicMeters
    }

    public static func overlappingWindows(_ chain: [String]) -> [[String]] {
        guard chain.count >= 2 else { return chain.isEmpty ? [] : [chain] }
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
            let isFinal = index + 1 >= windows.count
            let candidates: [Coordinate]
            if !isFinal, let next = windows[index + 1].last, let shared = window.last {
                // Yes-access B→C seams first (short hops like NS→Gaspé). Far seams
                // such as QC→ON often sit on stubs that only connect once C loads;
                // after those fail, an on-road interior pin inside the shared pack
                // keeps the current two-pack window legal.
                var pins = Array(try handoverCandidates(from: shared, into: next, toward: request.end,
                                                        repository: repository).prefix(2))
                if let interior = try? roadInteriorTarget(in: shared, from: cursor, toward: request.end,
                                                          repository: repository, budget: budget) {
                    pins.append(interior)
                }
                candidates = pins
            } else {
                candidates = [request.end]
            }
            let started = ContinuousClock.now
            let part = try routeHop(window: window, from: cursor, ends: candidates, request: request,
                                    preceding: parts, repository: repository, budget: budget,
                                    intermediate: !isFinal)
            request.options.counter?.recordStage("stage\(index):\(window.joined(separator: ","))", since: started)
            parts.append(part)
            cursor = part.end.coordinate
        }
        return stitch(parts, windows: windows)
    }

    /// One staged window. The pack join/index is built once; candidate handovers
    /// reuse it. Intermediate hops fall back to a Clean connectivity search when
    /// the rider style cannot legally reach a border or interior pin.
    static func routeHop(window: [String], from cursor: Coordinate, ends: [Coordinate],
                         request: RoutingRequest, preceding: [ComputedRoute],
                         repository: PackRepository, budget: ComputationBudget,
                         intermediate: Bool) throws -> ComputedRoute {
        let packs = try window.map { try repository.open($0, requireSeams: window.count > 1, budget: budget) }
        guard let first = packs.first else { throw RoutingFailure.missingPacks(window) }
        let graph: any RoadGraph = packs.count == 1 ? first.graph : try RegionalGraph(packs: packs, budget: budget)
        let indexed = try IndexedGraph(graph, budget: budget)
        let engine = RoutingEngine(pack: indexed)
        var lastFailure: RoutingFailure = .noPath
        let targets = ends.isEmpty ? [request.end] : Array(ends.prefix(4))
        for hopEnd in targets {
            try budget.check()
            let hop = decorated(request, from: cursor, to: hopEnd, preceding: preceding)
            do {
                return try engine.route(hop, budget: budget)
            } catch let error as RoutingFailure where error == .noPath || error == .noMatch {
                lastFailure = error
            }
        }
        if intermediate, request.profile.style != .cleanest {
            for hopEnd in targets {
                try budget.check()
                var bridge = decorated(request, from: cursor, to: hopEnd, preceding: preceding)
                bridge.profile = ProfilePolicy(style: .cleanest)
                bridge.access = AccessPolicy(allowUnknown: request.access.allowUnknown)
                do {
                    return try engine.route(bridge, budget: budget)
                } catch let error as RoutingFailure where error == .noPath || error == .noMatch {
                    lastFailure = error
                }
            }
        }
        throw lastFailure
    }

    static func decorated(_ request: RoutingRequest, from cursor: Coordinate, to hopEnd: Coordinate,
                          preceding: [ComputedRoute]) -> RoutingRequest {
        var hop = request.with(start: cursor, end: hopEnd)
        let span = cursor.distance(to: hopEnd)
        hop.options.compassMaxRemaining = max(450_000, span * 2.5)
        if let previous = preceding.last {
            hop.options.precedingMeters = preceding.reduce(0) { $0 + $1.distanceMeters }
            hop.options.precedingDirtMeters = preceding.reduce(0) { $0 + knownDirtMeters($1) }
            hop.options.arrivalEdgeID = previous.segments.last?.edgeID
        }
        return hop
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

    static func handover(from shared: String, into next: String, toward dest: Coordinate,
                         repository: PackRepository) throws -> Coordinate {
        guard let best = try handoverCandidates(from: shared, into: next, toward: dest,
                                                repository: repository).first else {
            throw RoutingFailure.noPath
        }
        return best
    }

    /// Border pins for the next hop, nearest the destination first.
    /// Prefer seams whose pack edge is known-yes access (code 0): nearest-to-dest
    /// alone can land on unknown-only tracks that Clean cannot match and Dirt cannot
    /// legally leave, which produced `noPath` on NS→ON while Gaspé still worked.
    static func handoverCandidates(from shared: String, into next: String, toward dest: Coordinate,
                                   repository: PackRepository) throws -> [Coordinate] {
        let anchors = try repository.loadSeams(shared).neighbors[next]
            ?? repository.loadSeams(next).neighbors[shared]
            ?? []
        var seen = Set<String>()
        var yes: [(Coordinate, Double)] = []
        var other: [(Coordinate, Double)] = []
        for row in anchors {
            guard row.coordinate.count == 2 else { continue }
            let point = Coordinate(longitude: row.coordinate[0], latitude: row.coordinate[1])
            guard point.isValid else { continue }
            let key = String(format: "%.5f,%.5f", point.latitude, point.longitude)
            guard seen.insert(key).inserted else { continue }
            let distance = point.distance(to: dest)
            let knownYes = row.edge.accessForward == 0 || row.edge.accessReverse == 0
            if knownYes { yes.append((point, distance)) } else { other.append((point, distance)) }
        }
        yes.sort { $0.1 < $1.1 }
        other.sort { $0.1 < $1.1 }
        let ordered = yes.map(\.0) + other.map(\.0)
        if ordered.isEmpty { throw RoutingFailure.noPath }
        return ordered
    }

    /// On-road pin inside `region`, toward `dest` from `cursor`.
    /// Samples real graph nodes so the matcher has something to snap to (raw
    /// geodesic fractions often land in water or empty forest).
    static func roadInteriorTarget(in region: String, from cursor: Coordinate, toward dest: Coordinate,
                                   repository: PackRepository, budget: ComputationBudget) throws -> Coordinate {
        let installed = try repository.open(region, requireSeams: false, budget: budget)
        let pack = installed.graph
        let box = sampledBox(pack)
        let step = max(1, pack.nodeCount / 6_000)
        var best: (Coordinate, Double)?
        for node in stride(from: 0, to: pack.nodeCount, by: step) {
            try budget.check()
            let point = pack.coordinate(node: node)
            guard point.isValid, box.contains(point) else { continue }
            let progressed = cursor.distance(to: point)
            let remaining = point.distance(to: dest)
            guard progressed > 80_000, remaining > 40_000 else { continue }
            let off = abs(point.crossTrack(from: cursor, to: dest))
            guard off < 120_000 else { continue }
            let score = remaining + off * 1.5
            if best == nil || score < best!.1 { best = (point, score) }
        }
        guard let best else { throw RoutingFailure.noPath }
        return best.0
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
