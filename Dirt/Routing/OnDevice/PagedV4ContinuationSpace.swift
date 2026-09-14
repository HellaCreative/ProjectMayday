import Foundation

/// Unactivated legal-state bridge. The prepared space owns bounded restriction
/// metadata and exact identity, never scoped queries or a GraphV2Pack.
nonisolated final class PagedV4ContinuationSpace {
    private let identity: PagedV4Core.Identity
    private let sourceEpoch: String
    private let restrictions: [GraphV2Pack.TurnRestriction]
    private let state: GraphV2Pack.V4TurnStateSpace
    var stateCount: Int { state.stateCount }
    func graphNode(of value: Int) -> Int { state.graphNode(of: value) }
    func transition(state value: Int,outgoingEdge: Int,toNode: Int) -> Int {
        state.transition(state: value,outgoingEdge: outgoingEdge,toNode: toNode)
    }
    private init(identity: PagedV4Core.Identity,sourceEpoch: String,
        restrictions: [GraphV2Pack.TurnRestriction],state: GraphV2Pack.V4TurnStateSpace) {
        self.identity = identity;self.sourceEpoch = sourceEpoch
        self.restrictions = restrictions;self.state = state
    }
    static func prepare(core: PagedV4Core,query: PagedV4Core.Query,legal: PagedV4Core.LegalQuery,
        index: OriginalIDIndex,limits: V4TurnPreparationLimits = .init()) throws -> PagedV4ContinuationSpace {
        guard query.belongs(to: core),legal.belongs(to: core),
              index.verifiedIdentity.graphSHA256 == core.identity.sha256,
              index.verifiedIdentity.graphBytes == core.identity.bytes else { throw PagedV4Core.Failure.identityMismatch }
        try index.validateSource(cancelled: { RoutingWorkContext.stopReason != nil })
        let topology = try PagedV4TurnTopology(core: core,query: query,legal: legal,limits: limits)
        // Observed immutable NS/NB/ON provenance lengths:103229/127305/1146734.
        // Decode only the epoch property from unchanged provenance; no invented
        // default. This is bounded metadata parsing, not an all-road allocation.
        let count = try legal.sectionLength(.provenance)
        guard count > 0,count <= 2*1024*1024 else { throw PagedV4Core.Failure.metadataLimit }
        var data = Data();data.reserveCapacity(count)
        for offset in stride(from: 0,to: count,by: 65_536) {
            let lease = try legal.sectionChunk(.provenance,offset: offset,count: min(65_536,count-offset))
            lease.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        struct Epoch: Decodable { let sourceEpoch: String? }
        guard let epoch = try JSONDecoder().decode(Epoch.self,from: data).sourceEpoch,!epoch.isEmpty else {
            throw NativeRoutingContinuationError.unavailableSourceEpoch
        }
        let state = try GraphV2Pack.V4TurnStateSpace.build(topology: topology,
            startNode: core.nodeCount,endNode: core.nodeCount+1,limits: limits)
        try query.validateSource();try legal.validateSource()
        try index.validateSource(cancelled: { RoutingWorkContext.stopReason != nil })
        return .init(identity: core.identity,sourceEpoch: epoch,restrictions: topology.restrictions,state: state)
    }
    private func access(core: PagedV4Core,query: PagedV4Core.Query,index: OriginalIDIndex) throws -> PagedV4ContinuationAccess {
        guard core.identity == identity,query.belongs(to: core),
              index.verifiedIdentity.graphSHA256 == identity.sha256,
              index.verifiedIdentity.graphBytes == identity.bytes else { throw PagedV4Core.Failure.identityMismatch }
        let access = PagedV4ContinuationAccess(core: core,query: query,index: index,
            sourceEpoch: sourceEpoch,restrictions: restrictions)
        try access.validate();return access
    }
    func exportContinuation(state value: Int,incomingEdge: Int,arrivedFromNode: Int,
        core: PagedV4Core,query: PagedV4Core.Query,index: OriginalIDIndex,
        location: NativeRoutingContinuation.Location? = nil) throws -> NativeRoutingContinuation {
        let access = try access(core: core,query: query,index: index)
        let token = try state.exportContinuation(state: value,incomingEdge: incomingEdge,
            arrivedFromNode: arrivedFromNode,access: access,location: location)
        try access.validate();return token
    }
    func importContinuation(_ token: NativeRoutingContinuation,
        core: PagedV4Core,query: PagedV4Core.Query,index: OriginalIDIndex) throws -> GraphV2Pack.V4TurnStateSpace.ImportedContinuation {
        let access = try access(core: core,query: query,index: index)
        // Bound untrusted carried metadata before Set/map allocations. This limit
        // fails explicitly; it never truncates context or clears a restriction.
        guard token.activeRestrictions.count <= 65_536,token.restrictionContext.count <= 65_536,
              token.restrictionContext.reduce(0,{ $0+$1.members.count }) <= 1_048_576 else {
            throw V4TurnPreparationError.resourceLimit
        }
        let arrival = try state.importContinuation(token,access: access)
        try access.validate();return arrival
    }
}

/// Lifetime is one public import/export call, never retained by a turn space.
nonisolated struct PagedV4ContinuationAccess {
    let core: PagedV4Core
    let query: PagedV4Core.Query
    let index: OriginalIDIndex
    let sourceEpoch: String?
    let restrictions: [GraphV2Pack.TurnRestriction]
    var nodeCount: Int { core.nodeCount }
    var edgeCount: Int { core.edgeCount }
    func validate() throws {
        guard query.belongs(to: core),index.verifiedIdentity.graphSHA256 == core.identity.sha256,
              index.verifiedIdentity.graphBytes == core.identity.bytes else { throw PagedV4Core.Failure.identityMismatch }
        try query.validateSource();try index.validateSource(cancelled: { RoutingWorkContext.stopReason != nil })
    }
    func nodeIndex(_ id: Int64) throws -> Int? { try index.node(id,cancelled: { RoutingWorkContext.stopReason != nil }) }
    func nodeID(_ node: Int) throws -> Int64 { try query.node(node).osmID }
    func endpoints(_ edge: Int) throws -> (Int,Int) { let row = try query.edge(edge);return (row.from,row.to) }
    func wayID(_ edge: Int) throws -> Int64 { try query.edge(edge).osmWayID }
    func forEachWay(_ id: Int64,visit: (Int) throws -> Void) throws {
        try index.way(id,cancelled: { RoutingWorkContext.stopReason != nil },visit: visit)
    }
    func hasDirectedArc(from: Int,to: Int,edge: Int) throws -> Bool {
        var found = false
        try query.outgoing(from) { if $0.edge == edge && $0.target == to { found = true } }
        return found
    }
}
