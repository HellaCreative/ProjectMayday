import Foundation

/// Reusable geometry bounds index. Matching visits nearby edges rather than
/// decoding every road again for every rider point and every fuel candidate.
public struct IndexedGraph: RoadGraph {
    private let graph: any RoadGraph
    private struct Cell: Hashable { let x: Int; let y: Int }
    private let cells: [Cell:[Int]]
    private let longEdges: [Int]
    private let weakCache = WeakComponentCache()
    private let arcs: ArcIndex
    let cacheIdentity = UUID().uuidString
    private static let cellDegrees = MatchingGridBounds.cellDegrees
    public init(_ graph: any RoadGraph, maximumEntries: Int = 8_000_000,
                budget: ComputationBudget = .init(seconds: 60)) throws {
        self.graph = graph
        var index: [Cell:[Int]] = [:], long: [Int] = [], entries = 0
        for edge in 0..<graph.edgeCount {
            if edge & 255 == 0 { try budget.check() }
            // Endpoint matching rejects every other access code in all modes.
            // Do not spend geometry-index space on roads that cannot be matched
            // in either direction. The underlying graph and restrictions remain
            // intact; unknown, destination and customer access stay discoverable.
            let matchable: (UInt8) -> Bool = { $0 == 0 || $0 == 1 || $0 == 3 || $0 == 4 }
            guard matchable(graph.accessCode(edge, forward: true))
                || matchable(graph.accessCode(edge, forward: false)) else { continue }
            guard let bounds = try graph.matchingGridBounds(edge) else { continue }
            let (x0,x1,y0,y1) = (bounds.x0,bounds.x1,bounds.y0,bounds.y1)
            let count = (x1-x0+1)*(y1-y0+1)
            // Long roads and antimeridian spans remain exact scan candidates.
            if count > 256 { long.append(edge); continue }
            guard entries <= maximumEntries-count else { throw RoutingFailure.resourceLimit("road index") }
            entries += count
            for y in y0...y1 { for x in x0...x1 { index[.init(x:x,y:y),default: []].append(edge) } }
        }
        cells = index; longEdges = long
        // RegionalGraph already joins independently verified source identities.
        // Nearby coordinates must not invent extra junctions (e.g. overpasses).
        arcs = try ArcIndex(nodeCount: graph.nodeCount, budget: budget) { node in
            graph.outgoing(node).map { arc in
                arc.meters.isFinite ? arc : RoadArc(target: arc.target, edge: arc.edge,
                                                    forward: arc.forward, meters: graph.distance(arc.edge))
            }
        }
        try budget.check()
    }
    public func candidates(near point: Coordinate,radius: Double) -> [Int] {
        guard point.isValid, radius.isFinite, radius > 0 else { return [] }
        let dy = radius/110_000, dx = min(180,dy/max(0.0001,cos((abs(point.latitude)+dy)*Double.pi/180)))
        let y0 = Int(floor(max(-90,point.latitude-dy)/Self.cellDegrees)), y1 = Int(floor(min(90,point.latitude+dy)/Self.cellDegrees))
        let x0 = Int(floor((point.longitude-dx)/Self.cellDegrees)), x1 = Int(floor((point.longitude+dx)/Self.cellDegrees))
        if (y1-y0+1)*(x1-x0+1) > 100_000 { return Array(0..<edgeCount) }
        var edges = Set(longEdges)
        for y in y0...y1 {
            for x in x0...x1 {
                let wrapped = ((x+3600)%7200+7200)%7200-3600
                for edge in cells[.init(x: wrapped,y: y)] ?? [] { edges.insert(edge) }
            }
        }
        return edges.sorted()
    }
    public var nodeCount: Int { graph.nodeCount }
    public var edgeCount: Int { graph.edgeCount }
    public var urbanCores: [GeographicBox] { graph.urbanCores }
    public var restrictionIndex: RestrictionIndex { graph.restrictionIndex }
    public func coordinate(node: Int) -> Coordinate { graph.coordinate(node: node) }
    public func outgoing(_ node: Int) -> [RoadArc] {
        guard node >= 0, node < nodeCount else { return [] }
        return (Int(arcs.outStart[node])..<Int(arcs.outStart[node + 1])).map { i in
            RoadArc(target: Int(arcs.targets[i]), edge: Int(arcs.outEdge[i]),
                    forward: arcs.forwards[i], meters: arcs.meters[i])
        }
    }
    public func endpoint(_ edge: Int,from: Bool) -> Int { graph.endpoint(edge,from: from) }
    public func restrictionEdge(_ edge: Int) -> Int { graph.restrictionEdge(edge) }
    public func edgeID(_ edge: Int) -> String { graph.edgeID(edge) }
    public func distance(_ edge: Int) -> Double { graph.distance(edge) }
    public func attributes(_ edge: Int) -> UInt16 { graph.attributes(edge) }
    public func crossingTime(_ edge: Int) -> Double { graph.crossingTime(edge) }
    public func accessCode(_ edge: Int,forward: Bool) -> UInt8 { graph.accessCode(edge,forward: forward) }
    public func surfaceLeaf(_ edge: Int) -> String { graph.surfaceLeaf(edge) }
    public func roadClass(_ edge: Int) -> String { graph.roadClass(edge) }
    public func structure(_ edge: Int) -> String { graph.structure(edge) }
    public func polyline(_ edge: Int) -> [Coordinate] { graph.polyline(edge) }
    public func matchingGridBounds(_ edge: Int) throws -> MatchingGridBounds? {
        try graph.matchingGridBounds(edge)
    }
    public func osmWayID(_ edge: Int) -> Int64 { graph.osmWayID(edge) }
    public func osmNodeID(_ node: Int) -> Int64 { graph.osmNodeID(node) }
    public func coincidentSiblings(_ node: Int) -> [Int] { graph.coincidentSiblings(node) }
    private let landCache = WeakComponentCache()
    func landComponentIDs(budget: ComputationBudget) throws -> [Int] {
        try budget.check()
        return try landCache.ids(allowUnknown: true) {
            try WeakComponents.landIDs(in: graph, budget: budget)
        }
    }
    func weakComponentIDs(allowUnknown: Bool) -> [Int] {
        weakCache.ids(allowUnknown: allowUnknown) {
            WeakComponents.compute(in: graph, allowUnknown: allowUnknown)
        }
    }
    /// Flat arc lists for reachability checks, built on first use.
    func arcIndex(budget: ComputationBudget) throws -> ArcIndex {
        try budget.check()
        return arcs
    }
}
