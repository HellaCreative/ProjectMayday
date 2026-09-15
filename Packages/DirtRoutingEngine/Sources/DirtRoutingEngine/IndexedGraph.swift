import Foundation

/// Reusable geometry bounds index. Matching visits nearby edges rather than
/// decoding every road again for every rider point and every fuel candidate.
public struct IndexedGraph: RoadGraph {
    private let graph: any RoadGraph
    private struct Cell: Hashable { let x: Int; let y: Int }
    private let cells: [Cell:[Int]]
    private let longEdges: [Int]
    private let siblings: [Int:[Int]]
    private let weakStrict: [Int]
    private let weakAllow: [Int]
    private let outgoingArcs: [[RoadArc]]
    let predecessors: [[(Int, Double)]]
    private let arcIndexCache = ArcIndexCache()
    private static let cellDegrees = 0.05
    private static let coincidentMeters = 2.0
    public init(_ graph: any RoadGraph, maximumEntries: Int = 8_000_000,
                budget: ComputationBudget = .init(seconds: 60)) throws {
        self.graph = graph
        var index: [Cell:[Int]] = [:], long: [Int] = [], entries = 0
        for edge in 0..<graph.edgeCount {
            if edge & 255 == 0 { try budget.check() }
            let shape = graph.polyline(edge)
            guard let first = shape.first else { continue }
            var west = first.longitude, east = west, south = first.latitude, north = south
            for p in shape {
                guard p.isValid else { throw RoutingFailure.invalidPack("invalid indexed geometry") }
                west = min(west,p.longitude); east = max(east,p.longitude)
                south = min(south,p.latitude); north = max(north,p.latitude)
            }
            let x0 = Int(floor(west/Self.cellDegrees)), x1 = Int(floor(east/Self.cellDegrees))
            let y0 = Int(floor(south/Self.cellDegrees)), y1 = Int(floor(north/Self.cellDegrees))
            let count = (x1-x0+1)*(y1-y0+1)
            // Long roads and antimeridian spans remain exact scan candidates.
            if count > 256 { long.append(edge); continue }
            guard entries <= maximumEntries-count else { throw RoutingFailure.resourceLimit("road index") }
            entries += count
            for y in y0...y1 { for x in x0...x1 { index[.init(x:x,y:y),default: []].append(edge) } }
        }
        cells = index; longEdges = long
        var firstByBucket: [Int:Int] = [:], lists: [Int:[Int]] = [:]
        let qLat = Self.coincidentMeters / 111_000
        for node in 0..<graph.nodeCount {
            if node & 4095 == 0 { try budget.check() }
            let point = graph.coordinate(node: node)
            guard point.isValid else { continue }
            let qLon = Self.coincidentMeters / (111_000 * max(0.2, cos(point.latitude * .pi / 180)))
            let key = Int((point.longitude / qLon).rounded()) &* 20_000_001 &+ Int((point.latitude / qLat).rounded())
            if let first = firstByBucket[key] {
                var existing = [first] + (lists[first] ?? [])
                for sibling in existing { lists[sibling, default: []].append(node) }
                lists[node] = existing
            } else {
                firstByBucket[key] = node
            }
        }
        siblings = lists
        var outgoingArcs = Array(repeating: [RoadArc](), count: graph.nodeCount)
        var predecessors = Array(repeating: [(Int, Double)](), count: graph.nodeCount)
        for node in 0..<graph.nodeCount {
            if node & 4095 == 0 { try budget.check() }
            let arcs = graph.outgoing(node).map { arc in
                arc.meters.isFinite ? arc : RoadArc(target: arc.target,edge: arc.edge,forward: arc.forward,
                                                    meters: graph.distance(arc.edge))
            }
            outgoingArcs[node] = arcs
            for arc in arcs {
                guard arc.target >= 0, arc.target < graph.nodeCount, arc.meters.isFinite, arc.meters >= 0 else { continue }
                predecessors[arc.target].append((node, arc.meters))
            }
        }
        self.outgoingArcs = outgoingArcs
        self.predecessors = predecessors
        weakStrict = WeakComponents.compute(in: graph, allowUnknown: false)
        weakAllow = WeakComponents.compute(in: graph, allowUnknown: true)
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
        guard node >= 0, node < outgoingArcs.count else { return [] }
        return outgoingArcs[node]
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
    public func osmWayID(_ edge: Int) -> Int64 { graph.osmWayID(edge) }
    public func osmNodeID(_ node: Int) -> Int64 { graph.osmNodeID(node) }
    public func coincidentSiblings(_ node: Int) -> [Int] { siblings[node] ?? [] }
    func weakComponentIDs(allowUnknown: Bool) -> [Int] { allowUnknown ? weakAllow : weakStrict }
    /// Flat arc lists for reachability checks, built on first use.
    func arcIndex(budget: ComputationBudget) throws -> ArcIndex {
        try arcIndexCache.value { try ArcIndex(nodeCount: nodeCount, budget: budget) { outgoing($0) } }
    }
}
