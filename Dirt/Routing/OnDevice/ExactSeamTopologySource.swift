import Foundation

/// Exact seam binding only. This deliberately does NOT grant access, prove turn
/// legality, or compare grade/structure. Legal traversal remains a router proof.
nonisolated protocol ExactSeamTopologySource {
    var nodeCount: Int { get }
    var edgeCount: Int { get }
    var sourceEpoch: String? { get }
    func validate() throws
    func resolve(_ wanted: Set<Int64>) throws -> [Int64: Int]
    func nodeID(_ node: Int) throws -> Int64
    func edge(_ edge: Int) throws -> (from: Int,to: Int,way: Int64)
    func outgoing(_ node: Int,_ visit: (Int,Int) throws -> Void) throws
}
nonisolated enum ExactSeamMatch: Error { case found }

nonisolated struct ArrayExactSeamTopology: ExactSeamTopologySource {
    let pack: GraphV2Pack
    var nodeCount: Int { pack.nodeCount }
    var edgeCount: Int { pack.undirectedEdgeCount }
    var sourceEpoch: String? { pack.sourceEpoch }
    func validate() throws {
        try RoutingWorkContext.check()
        guard pack.version >= 4,pack.legalTopology,pack.osmNodeIds.count == pack.nodeCount else {
            throw ExactGuidanceSeams.Failure.incompatibleSource
        }
    }
    func resolve(_ wanted: Set<Int64>) throws -> [Int64: Int] {
        var nodes: [Int64: Int] = [:]
        for (index,id) in pack.osmNodeIds.enumerated() {
            if index&1023 == 0 { try validate() }
            if wanted.contains(id) {
                guard nodes.updateValue(index,forKey: id) == nil else { throw ExactGuidanceSeams.Failure.invalidRecordedIdentity }
            }
        }
        return nodes
    }
    func nodeID(_ node: Int) throws -> Int64 {
        guard pack.osmNodeIds.indices.contains(node) else { throw ExactGuidanceSeams.Failure.invalidRecordedIdentity }
        return pack.osmNodeIds[node]
    }
    func edge(_ edge: Int) throws -> (from: Int,to: Int,way: Int64) {
        guard let from = pack.edgeFrom,let to = pack.edgeTo,from.indices.contains(edge),to.indices.contains(edge),
              pack.osmWayIds.indices.contains(edge) else { throw ExactGuidanceSeams.Failure.invalidRecordedIdentity }
        return (Int(from[edge]),Int(to[edge]),pack.osmWayIds[edge])
    }
    func outgoing(_ node: Int,_ visit: (Int,Int) throws -> Void) throws {
        guard (0..<nodeCount).contains(node),pack.nodeOffsets.indices.contains(node+1) else { throw ExactGuidanceSeams.Failure.invalidRecordedIdentity }
        let first = Int(pack.nodeOffsets[node]),last = Int(pack.nodeOffsets[node+1])
        guard first >= 0,last >= first,last <= pack.directedArcCount,last <= pack.edgeTargets.count,
              last <= pack.edgeUndirectedIndex.count else { throw ExactGuidanceSeams.Failure.invalidRecordedIdentity }
        for arc in first..<last { try visit(Int(pack.edgeUndirectedIndex[arc]),Int(pack.edgeTargets[arc])) }
    }
}

/// This value must remain inside the passed core/legal query lifetimes. Identity
/// equality ties the source-index proof to these bytes; it is not a spatial join.
nonisolated struct PagedExactSeamTopology: ExactSeamTopologySource {
    private let core: PagedV4Core
    private let query: PagedV4Core.Query
    private let legal: PagedV4Core.LegalQuery
    private let index: OriginalIDIndex
    let sourceEpoch: String?
    var nodeCount: Int { core.nodeCount }
    var edgeCount: Int { core.edgeCount }
    init(core: PagedV4Core,query: PagedV4Core.Query,legal: PagedV4Core.LegalQuery,index: OriginalIDIndex) throws {
        guard query.belongs(to: core),legal.belongs(to: core),
              index.verifiedIdentity.graphSHA256 == core.identity.sha256,
              index.verifiedIdentity.graphBytes == core.identity.bytes else { throw PagedV4Core.Failure.identityMismatch }
        try legal.requireCurrentCapability()
        self.core = core;self.query = query;self.legal = legal;self.index = index
        self.sourceEpoch = try PagedV4SourceMetadata.sourceEpoch(legal)
        try validate()
    }
    func validate() throws {
        try RoutingWorkContext.check()
        guard query.belongs(to: core),legal.belongs(to: core),
              index.verifiedIdentity.graphSHA256 == core.identity.sha256,
              index.verifiedIdentity.graphBytes == core.identity.bytes else { throw PagedV4Core.Failure.identityMismatch }
        try query.validateSource();try legal.validateSource()
        try index.validateSource(cancelled: { RoutingWorkContext.stopReason != nil })
    }
    func resolve(_ wanted: Set<Int64>) throws -> [Int64: Int] {
        var result: [Int64: Int] = [:]
        for id in wanted {
            try validate()
            do {
                if let node = try index.node(id,cancelled: { RoutingWorkContext.stopReason != nil }) {
                    guard try query.node(node).osmID == id else { throw ExactGuidanceSeams.Failure.invalidRecordedIdentity }
                    result[id] = node
                }
            } catch OriginalIDIndex.Failure.ambiguousNode { throw ExactGuidanceSeams.Failure.invalidRecordedIdentity }
        }
        return result
    }
    func nodeID(_ node: Int) throws -> Int64 { try query.node(node).osmID }
    func edge(_ edge: Int) throws -> (from: Int,to: Int,way: Int64) {
        let row = try query.edge(edge);return (row.from,row.to,row.osmWayID)
    }
    func outgoing(_ node: Int,_ visit: (Int,Int) throws -> Void) throws {
        try query.outgoing(node) { try visit($0.edge,$0.target) }
    }
}
