import Foundation

public struct RoadArc: Sendable {
    public let target: Int
    public let edge: Int
    public let forward: Bool
    public let meters: Double
    public init(target: Int, edge: Int, forward: Bool, meters: Double = .nan) {
        self.target = target; self.edge = edge; self.forward = forward; self.meters = meters
    }
}

/// Search operates on legal graph identities, independently of regional storage.
public protocol RoadGraph: Sendable {
    var nodeCount: Int { get }
    var edgeCount: Int { get }
    var urbanCores: [GeographicBox] { get }
    var restrictionIndex: RestrictionIndex { get }
    func coordinate(node: Int) -> Coordinate
    func candidates(near point: Coordinate, radius: Double) -> [Int]
    func outgoing(_ node: Int) -> [RoadArc]
    func endpoint(_ edge: Int, from: Bool) -> Int
    func restrictionEdge(_ edge: Int) -> Int
    func edgeID(_ edge: Int) -> String
    func distance(_ edge: Int) -> Double
    func attributes(_ edge: Int) -> UInt16
    func crossingTime(_ edge: Int) -> Double
    func accessCode(_ edge: Int, forward: Bool) -> UInt8
    func surfaceLeaf(_ edge: Int) -> String
    func roadClass(_ edge: Int) -> String
    func structure(_ edge: Int) -> String
    func polyline(_ edge: Int) -> [Coordinate]
    func osmWayID(_ edge: Int) -> Int64
    func osmNodeID(_ node: Int) -> Int64
    func coincidentSiblings(_ node: Int) -> [Int]
}

extension GraphPack: RoadGraph {
    public var urbanCores: [GeographicBox] { metadata.urbanCores ?? [] }
    public func endpoint(_ edge: Int, from: Bool) -> Int { Int(from ? edgeFrom[edge] : edgeTo[edge]) }
    public func attributes(_ edge: Int) -> UInt16 { attrs[edge] }
    public func crossingTime(_ edge: Int) -> Double { Double(crossingSeconds[edge]) }
    public func restrictionEdge(_ edge: Int) -> Int { edge }
    public func outgoing(_ node: Int) -> [RoadArc] {
        (Int(nodeOffsets[node])..<Int(nodeOffsets[node+1])).map { a in
            let edge = Int(arcEdges[a])
            return RoadArc(target: Int(targets[a]), edge: edge, forward: edgeFrom[edge] == node,
                           meters: Double(meters[edge]))
        }
    }
}

extension RoadGraph {
    public func candidates(near point: Coordinate, radius: Double) -> [Int] { Array(0..<edgeCount) }
    public func osmWayID(_ edge: Int) -> Int64 { Int64(edge) }
    public func osmNodeID(_ node: Int) -> Int64 { Int64(node) }
    /// Duplicate OSM nodes within 2 m are a zero-cost transfer, matching
    /// `hop-search.js` `CLEAN_COINCIDENT_NODE_M`. Indexed graphs precompute this.
    public func coincidentSiblings(_ node: Int) -> [Int] { [] }
    public func identity(of edge: Int) -> String {
        "\(osmWayID(edge)):\(osmNodeID(endpoint(edge,from: true))):\(osmNodeID(endpoint(edge,from: false)))"
    }
    public func matches(_ edge: Int, identities: Set<String>) -> Bool {
        guard !identities.isEmpty else { return false }
        return identities.contains(edgeID(edge)) || identities.contains(identity(of: edge))
    }
    public func edge(matching identities: Set<String>) -> Int? {
        guard !identities.isEmpty else { return nil }
        for edge in 0..<edgeCount where matches(edge, identities: identities) { return edge }
        return nil
    }
}
