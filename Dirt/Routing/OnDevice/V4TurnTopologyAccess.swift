import Foundation

/// Scoped topology reads only. Returned turn spaces own no descriptor/query
/// closures or regional graph. Endpoint topology must already be verified.
nonisolated protocol V4TurnTopologyAccess {
    var nodeCount: Int { get }
    var restrictions: [GraphV2Pack.TurnRestriction] { get }
    var retainedRestrictionPayloadBytes: Int { get }
    func endpoints(_ edge: Int) throws -> (Int,Int)
    func outgoing(_ node: Int,_ visit: (Int,Int) throws -> Void) throws
    func validate() throws
}
nonisolated enum V4TurnPreparationError: Error, Equatable {
    case unsupportedMetadata, unverifiedTopology, resourceLimit, invalidTopology
}
nonisolated struct V4TurnPreparationLimits {
    var maximumRestrictions = 16_384
    var maximumViaMembers = 131_072
    var maximumStates = 32_768
    var maximumTransitions = 131_072
    /// Explicit reservation accounting, not a claim about allocator/RSS peaks.
    /// Row counts also bound dictionary/reference overhead independently.
    var maximumReservedBytes = 16 * 1024 * 1024
}
nonisolated final class V4TurnPreparationBudget {
    let limits: V4TurnPreparationLimits
    private(set) var reservedBytes: Int = 0
    private(set) var states = 0, transitions = 0
    init(limits: V4TurnPreparationLimits) throws {
        guard limits.maximumRestrictions >= 0, limits.maximumRestrictions <= 65_536,
              limits.maximumViaMembers >= 0, limits.maximumViaMembers <= 1_048_576,
              limits.maximumStates > 0, limits.maximumStates <= 262_144,
              limits.maximumTransitions > 0, limits.maximumTransitions <= 1_048_576,
              limits.maximumReservedBytes > 0 else { throw V4TurnPreparationError.resourceLimit }
        self.limits = limits
    }
    func reserve(_ bytes: Int) throws {
        try RoutingWorkContext.check()
        guard bytes >= 0, bytes <= limits.maximumReservedBytes-reservedBytes else { throw V4TurnPreparationError.resourceLimit }
        reservedBytes += bytes
    }
    func state(progress: Int) throws {
        guard states < limits.maximumStates, progress <= limits.maximumViaMembers else { throw V4TurnPreparationError.resourceLimit }
        // Record/key/queue/dictionary slots and duplicated active-array capacity.
        try reserve(512 + progress * 64); states += 1
    }
    func transition() throws {
        guard transitions < limits.maximumTransitions else { throw V4TurnPreparationError.resourceLimit }
        try reserve(256); transitions += 1
    }
}
nonisolated struct ArrayV4TurnTopology: V4TurnTopologyAccess {
    let pack: GraphV2Pack
    let restrictions: [GraphV2Pack.TurnRestriction]
    let retainedRestrictionPayloadBytes: Int
    var nodeCount: Int { pack.nodeCount }
    init(pack: GraphV2Pack,limits: V4TurnPreparationLimits) throws {
        _ = try V4TurnPreparationBudget(limits: limits)
        guard pack.version >= 4, pack.legalTopology, pack.hasVerifiedCSREndpoints else { throw V4TurnPreparationError.unverifiedTopology }
        self.pack = pack
        restrictions = pack.restrictions // COW borrow; no copy of the region.
        retainedRestrictionPayloadBytes = try Self.restrictionBytes(restrictions,limits: limits)
    }
    static func restrictionBytes(_ rows: [GraphV2Pack.TurnRestriction],limits: V4TurnPreparationLimits) throws -> Int {
        guard rows.count <= limits.maximumRestrictions else { throw V4TurnPreparationError.resourceLimit }
        var bytes = rows.capacity * MemoryLayout<GraphV2Pack.TurnRestriction>.stride, members = 0
        for row in rows {
            members += row.viaEdges.count
            guard members <= limits.maximumViaMembers else { throw V4TurnPreparationError.resourceLimit }
            bytes += row.viaEdges.capacity * MemoryLayout<Int>.stride
        }
        guard bytes <= limits.maximumReservedBytes else { throw V4TurnPreparationError.resourceLimit }
        return bytes
    }
    func validate() throws { try RoutingWorkContext.check() }
    func endpoints(_ edge: Int) throws -> (Int,Int) {
        guard let from = pack.edgeFrom, let to = pack.edgeTo,
              from.indices.contains(edge),to.indices.contains(edge) else { throw V4TurnPreparationError.invalidTopology }
        return (Int(from[edge]),Int(to[edge]))
    }
    func outgoing(_ node: Int,_ visit: (Int,Int) throws -> Void) throws {
        try validate()
        guard (0..<nodeCount).contains(node) else { throw V4TurnPreparationError.invalidTopology }
        for arc in Int(pack.nodeOffsets[node])..<Int(pack.nodeOffsets[node+1]) {
            try RoutingWorkContext.check()
            try visit(Int(pack.edgeUndirectedIndex[arc]),Int(pack.edgeTargets[arc]))
        }
    }
}
nonisolated struct PagedV4TurnTopology: V4TurnTopologyAccess {
    let nodeCount: Int
    let restrictions: [GraphV2Pack.TurnRestriction]
    let retainedRestrictionPayloadBytes: Int
    private let query: PagedV4Core.Query
    init(core: PagedV4Core,query: PagedV4Core.Query,legal: PagedV4Core.LegalQuery,
         limits: V4TurnPreparationLimits) throws {
        _ = try V4TurnPreparationBudget(limits: limits)
        guard query.belongs(to: core), legal.belongs(to: core) else { throw V4TurnPreparationError.unverifiedTopology }
        try legal.requireCurrentCapability()
        // Do not silently erase future conditional interpretation during extraction.
        let length = try legal.sectionLength(.conditionals)
        guard length <= 65_536 else { throw V4TurnPreparationError.unsupportedMetadata }
        let lease = try legal.sectionChunk(.conditionals,offset: 0,count: length)
        let data = lease.withUnsafeBytes { Data($0) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["policy"] as? String == "fail_closed",
              let rules = object["rules"] as? [Any], rules.isEmpty else { throw V4TurnPreparationError.unsupportedMetadata }
        var rows: [GraphV2Pack.TurnRestriction] = [], members = 0, viaBytes = 0
        try legal.forEachRestriction { _,row in
            guard rows.count < limits.maximumRestrictions,
                  row.via.count <= limits.maximumViaMembers-members else { throw V4TurnPreparationError.resourceLimit }
            guard row.flags & ~UInt8(2) == 0, row.exceptMask == 0, row.conditionalIndex == -1,
                  row.kind <= 9, row.vehicleMask & ~UInt16(7) == 0,
                  row.only == (4...7).contains(Int(row.kind)),
                  row.via.allSatisfy({ $0.edge >= 0 }) else { throw V4TurnPreparationError.unsupportedMetadata }
            members += row.via.count
            // Retain exact ordered edge sequence; raw way IDs remain available in
            // LegalQuery for continuation/signature integration, not discarded data.
            rows.append(.init(osmRelationId: row.osmRelationID,kind: row.kind,
                fromEdge: Int(row.fromEdge),toEdge: Int(row.toEdge),viaNode: Int(row.viaNode),
                only: row.only,vehicleMask: row.vehicleMask,viaEdges: row.via.map { Int($0.edge) }))
            viaBytes += rows[rows.count-1].viaEdges.capacity * MemoryLayout<Int>.stride
            guard rows.capacity * MemoryLayout<GraphV2Pack.TurnRestriction>.stride + viaBytes <= limits.maximumReservedBytes else {
                throw V4TurnPreparationError.resourceLimit
            }
        }
        self.nodeCount = core.nodeCount; self.query = query; self.restrictions = rows
        retainedRestrictionPayloadBytes = try ArrayV4TurnTopology.restrictionBytes(rows,limits: limits)
    }
    func validate() throws { try RoutingWorkContext.check(); try query.validateSource() }
    func endpoints(_ edge: Int) throws -> (Int,Int) { let row = try query.edge(edge); return (row.from,row.to) }
    func outgoing(_ node: Int,_ visit: (Int,Int) throws -> Void) throws {
        try query.outgoing(node) { try visit($0.edge,$0.target) }
    }
}
