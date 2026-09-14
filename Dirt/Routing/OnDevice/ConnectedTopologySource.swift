import Foundation

/// Shared graph/identity/legal-state access, not a cost or routing policy.
/// Paged implementations must remain inside their creating query scopes.
nonisolated protocol ConnectedTopologySource: ExactSeamTopologySource {
    var arrayPack: GraphV2Pack? { get }
    func publishDiagnostics()
    func graphNode(of state: Int) throws -> Int
    func startState(node: Int) throws -> Int
    func transition(state: Int,edge: Int,to: Int) throws -> Int
    func arcs(_ node: Int,_ visit: (ConnectedTopologyArc) throws -> Void) throws
    func export(state: Int,edge: Int,from: Int) throws -> NativeRoutingContinuation
    func `import`(_ token: NativeRoutingContinuation) throws -> GraphV2Pack.V4TurnStateSpace.ImportedContinuation
}
nonisolated struct ConnectedTopologyArc {
    let ordinal: Int,edge: Int,from: Int,to: Int
    let meters: Double
    let attributes: UInt16
    let directedAccess: UInt8
}

nonisolated struct ArrayConnectedTopology: ConnectedTopologySource {
    let pack: GraphV2Pack
    private let seam: ArrayExactSeamTopology
    private let turns: GraphV2Pack.V4TurnStateSpace
    private let validateExternal: () throws -> Void
    init(pack: GraphV2Pack,validate: @escaping () throws -> Void) throws {
        let seam = ArrayExactSeamTopology(pack: pack)
        try validate();try seam.validate()
        self.pack = pack;self.seam = seam;self.validateExternal = validate
        turns = pack.makeV4TurnStateSpace(startNode: pack.nodeCount,endNode: pack.nodeCount+1)
        try validate()
    }
    func publishDiagnostics() {} // Eager preparation already published at creation.
    var arrayPack: GraphV2Pack? { pack }
    var nodeCount: Int { seam.nodeCount }
    var edgeCount: Int { seam.edgeCount }
    var sourceEpoch: String? { seam.sourceEpoch }
    func validate() throws { try validateExternal();try seam.validate() }
    func resolve(_ wanted: Set<Int64>) throws -> [Int64: Int] { try seam.resolve(wanted) }
    func nodeID(_ node: Int) throws -> Int64 { try seam.nodeID(node) }
    func edge(_ edge: Int) throws -> (from: Int,to: Int,way: Int64) { try seam.edge(edge) }
    func outgoing(_ node: Int,_ visit: (Int,Int) throws -> Void) throws { try seam.outgoing(node,visit) }
    func startState(node: Int) throws -> Int {
        try validate()
        guard (0..<nodeCount).contains(node) else { throw ConnectedPackStageView.Failure.invalidInput }
        return node
    }
    func graphNode(of state: Int) throws -> Int { try validate();return turns.graphNode(of: state) }
    func transition(state: Int,edge: Int,to: Int) throws -> Int { try validate();return turns.transition(state: state,outgoingEdge: edge,toNode: to) }
    func arcs(_ node: Int,_ visit: (ConnectedTopologyArc) throws -> Void) throws {
        try validate()
        guard (0..<nodeCount).contains(node),pack.nodeOffsets.indices.contains(node+1) else { throw ConnectedPackStageView.Failure.invalidInput }
        let begin = Int(pack.nodeOffsets[node]),end = Int(pack.nodeOffsets[node+1])
        guard begin >= 0,end >= begin,end <= pack.edgeTargets.count,end <= pack.edgeUndirectedIndex.count else { throw ConnectedPackStageView.Failure.invalidInput }
        for arc in begin..<end {
            try RoutingWorkContext.check()
            let edge = Int(pack.edgeUndirectedIndex[arc]),target = Int(pack.edgeTargets[arc])
            guard (0..<edgeCount).contains(edge),(0..<nodeCount).contains(target) else { throw ConnectedPackStageView.Failure.invalidInput }
            try visit(.init(ordinal: arc,edge: edge,from: node,to: target,meters: Double(pack.edgeMeters[edge]),
                attributes: pack.edgeAttrs[edge],directedAccess: pack.v4AccessCode(ei: edge,from: node,to: target)))
        }
        try validate()
    }
    func export(state: Int,edge: Int,from: Int) throws -> NativeRoutingContinuation {
        try validate();let token = try turns.exportContinuation(state: state,incomingEdge: edge,arrivedFromNode: from,pack: pack)
        try validate();return token
    }
    func `import`(_ token: NativeRoutingContinuation) throws -> GraphV2Pack.V4TurnStateSpace.ImportedContinuation {
        try validate();let arrival = try turns.importContinuation(token,pack: pack)
        try validate();return arrival
    }
}

nonisolated struct PagedConnectedTopology: ConnectedTopologySource {
    private let core: PagedV4Core
    private let query: PagedV4Core.Query
    private let index: OriginalIDIndex
    private let seam: PagedExactSeamTopology
    private let turns: PagedV4ContinuationSpace
    init(core: PagedV4Core,query: PagedV4Core.Query,legal: PagedV4Core.LegalQuery,index: OriginalIDIndex) throws {
        let seam = try PagedExactSeamTopology(core: core,query: query,legal: legal,index: index)
        self.core = core;self.query = query;self.index = index;self.seam = seam
        turns = try PagedV4ContinuationSpace.prepare(core: core,query: query,legal: legal,index: index)
        try seam.validate()
    }
    func publishDiagnostics() { turns.publishDiagnostics() }
    var arrayPack: GraphV2Pack? { nil }
    var nodeCount: Int { core.nodeCount }
    var edgeCount: Int { core.edgeCount }
    var sourceEpoch: String? { seam.sourceEpoch }
    func validate() throws { try seam.validate() }
    func resolve(_ wanted: Set<Int64>) throws -> [Int64: Int] { try seam.resolve(wanted) }
    func nodeID(_ node: Int) throws -> Int64 { try seam.nodeID(node) }
    func edge(_ edge: Int) throws -> (from: Int,to: Int,way: Int64) { try seam.edge(edge) }
    func outgoing(_ node: Int,_ visit: (Int,Int) throws -> Void) throws { try seam.outgoing(node,visit) }
    func startState(node: Int) throws -> Int {
        try validate();return try turns.startState(node: node,core: core,query: query)
    }
    func graphNode(of state: Int) throws -> Int { try validate();return turns.graphNode(of: state) }
    func transition(state: Int,edge: Int,to: Int) throws -> Int {
        try validate()
        return try turns.transition(state: state,outgoingEdge: edge,toNode: to,core: core,query: query)
    }
    func arcs(_ node: Int,_ visit: (ConnectedTopologyArc) throws -> Void) throws {
        try validate()
        try query.outgoing(node) { arc in
            let row = try query.edge(arc.edge)
            let access: UInt8
            if row.from == arc.source && row.to == arc.target { access = row.forwardAccess }
            else if row.to == arc.source && row.from == arc.target { access = row.reverseAccess }
            else { throw PagedV4Core.Failure.invalidTopology }
            try visit(.init(ordinal: arc.index,edge: arc.edge,from: arc.source,to: arc.target,
                meters: Double(row.meters),attributes: row.attributes,directedAccess: access))
        }
        try validate()
    }
    func export(state: Int,edge: Int,from: Int) throws -> NativeRoutingContinuation {
        try validate()
        return try turns.exportContinuation(state: state,incomingEdge: edge,arrivedFromNode: from,core: core,query: query,index: index)
    }
    func `import`(_ token: NativeRoutingContinuation) throws -> GraphV2Pack.V4TurnStateSpace.ImportedContinuation {
        try validate();return try turns.importContinuation(token,core: core,query: query,index: index)
    }
}
