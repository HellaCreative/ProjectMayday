import Foundation

/// Unactivated legal-state bridge. The prepared space owns bounded restriction
/// metadata and exact identity, never scoped queries or a GraphV2Pack.
nonisolated final class PagedV4ContinuationSpace {
    private let identity: PagedV4Core.Identity
    private let sourceEpoch: String
    private let restrictions: [GraphV2Pack.TurnRestriction]
    private var state: GraphV2Pack.V4TurnStateSpace
    private let budget: V4TurnPreparationBudget
    private let stateLock = NSRecursiveLock()
    var stateCount: Int { stateLock.lock(); defer { stateLock.unlock() }; return state.stateCount }
    func graphNode(of value: Int) -> Int { stateLock.lock(); defer { stateLock.unlock() }; return state.graphNode(of: value) }
    func startState(node: Int,core: PagedV4Core,query: PagedV4Core.Query) throws -> Int {
        guard core.identity == identity,query.belongs(to: core) else { throw PagedV4Core.Failure.identityMismatch }
        try query.validateSource(); _ = try query.node(node); try query.validateSource()
        return node
    }
    func transition(state value: Int,outgoingEdge: Int,toNode: Int,
        core: PagedV4Core,query: PagedV4Core.Query) throws -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        guard core.identity == identity,query.belongs(to: core) else { throw PagedV4Core.Failure.identityMismatch }
        try query.validateSource()
        let node = state.graphNode(of: value)
        guard (0..<core.nodeCount).contains(node) else { throw V4TurnPreparationError.invalidTopology }
        var present = false
        try query.outgoing(node) { if $0.edge == outgoingEdge && $0.target == toNode { present = true } }
        guard present else { throw V4TurnPreparationError.invalidTopology }
        let result = try state.demandTransition(state: value,outgoingEdge: outgoingEdge,toNode: toNode,budget: budget)
        try query.validateSource()
        return result
    }
    /// Call once when this search scope completes or fails; no per-arc metric locks.
    func publishDiagnostics() { stateLock.lock(); defer { stateLock.unlock() }; budget.publishDiagnostics() }
    private init(identity: PagedV4Core.Identity,sourceEpoch: String,
        restrictions: [GraphV2Pack.TurnRestriction],state: GraphV2Pack.V4TurnStateSpace,budget: V4TurnPreparationBudget) {
        self.identity = identity;self.sourceEpoch = sourceEpoch
        self.restrictions = restrictions;self.state = state;self.budget = budget
    }
    static func prepare(core: PagedV4Core,query: PagedV4Core.Query,legal: PagedV4Core.LegalQuery,
        index: OriginalIDIndex,limits: V4TurnPreparationLimits = .init()) throws -> PagedV4ContinuationSpace {
        guard query.belongs(to: core),legal.belongs(to: core),
              index.verifiedIdentity.graphSHA256 == core.identity.sha256,
              index.verifiedIdentity.graphBytes == core.identity.bytes else { throw PagedV4Core.Failure.identityMismatch }
        try index.validateSource(cancelled: { RoutingWorkContext.stopReason != nil })
        let topology = try PagedV4TurnTopology(core: core,query: query,legal: legal,limits: limits)
        let epoch = try PagedV4SourceMetadata.sourceEpoch(legal)
        let state = try GraphV2Pack.V4TurnStateSpace.build(topology: topology,
            startNode: core.nodeCount,endNode: core.nodeCount+1,limits: limits,demandDriven: true)
        try query.validateSource();try legal.validateSource()
        try index.validateSource(cancelled: { RoutingWorkContext.stopReason != nil })
        let budget = try V4TurnPreparationBudget(limits: limits)
        try budget.reserve(state.preparationReservedBytes)
        return .init(identity: core.identity,sourceEpoch: epoch,restrictions: topology.restrictions,state: state,budget: budget)
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
        stateLock.lock(); defer { stateLock.unlock() }
        let access = try access(core: core,query: query,index: index)
        let token = try state.exportContinuation(state: value,incomingEdge: incomingEdge,
            arrivedFromNode: arrivedFromNode,access: access,location: location)
        try access.validate();return token
    }
    func importContinuation(_ token: NativeRoutingContinuation,
        core: PagedV4Core,query: PagedV4Core.Query,index: OriginalIDIndex) throws -> GraphV2Pack.V4TurnStateSpace.ImportedContinuation {
        stateLock.lock(); defer { stateLock.unlock() }
        let access = try access(core: core,query: query,index: index)
        // Bound untrusted carried metadata before Set/map allocations. This limit
        // fails explicitly; it never truncates context or clears a restriction.
        guard token.activeRestrictions.count <= 65_536,token.restrictionContext.count <= 65_536,
              token.restrictionContext.reduce(0,{ $0+$1.members.count }) <= 1_048_576 else {
            throw V4TurnPreparationError.resourceLimit
        }
        let arrival = try state.importContinuation(token,access: access,demandBudget: budget)
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
