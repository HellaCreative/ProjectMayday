import CryptoKit
import Foundation

/// Staged graph-access adapter, not a second search engine. The consumer retains
/// its one-stage labels/cost/range/mix. Passed packs remain locally indexed; no
/// road arrays are joined. Request-scoped ownership does not bound resident packs.
nonisolated final class ConnectedPackStageView {
    struct Cursor: Hashable {
        let pack: Int
        let turnState: Int
        let incomingEdge: Int
        let arrivedFrom: Int
    }
    struct Road: Hashable { let pack: Int; let edge: Int }
    struct CanonicalRoad: Hashable {
        let sourceEpoch: String
        let wayID: Int64
        let firstNodeID: Int64
        let lastNodeID: Int64
    }
    struct Traversal {
        let destination: Cursor
        let road: Road
        let arc: Int
        let from: Int
        let to: Int
        let meters: Double
        let attributes: UInt16
        let directedAccess: UInt8
    }
    struct Source {
        let region: String
        fileprivate let makeTopology: () throws -> any ConnectedTopologySource
        /// Verified graph SHA-256; caller must bind validate to the opened source.
        let graphSHA256: String
        let validate: () throws -> Void
        init(region: String,pack: GraphV2Pack,graphSHA256: String,validate: @escaping () throws -> Void) {
            self.region = region;self.graphSHA256 = graphSHA256;self.validate = validate
            makeTopology = { try ArrayConnectedTopology(pack: pack,validate: validate) }
        }
        init(region: String,core: PagedV4Core,query: PagedV4Core.Query,legal: PagedV4Core.LegalQuery,index: OriginalIDIndex) {
            self.region = region;self.graphSHA256 = core.identity.sha256
            self.validate = {
                guard query.belongs(to: core),legal.belongs(to: core) else { throw PagedV4Core.Failure.queryClosed }
                try query.validateSource();try legal.validateSource();try index.validateSource(cancelled: { RoutingWorkContext.stopReason != nil })
            }
            makeTopology = { try PagedConnectedTopology(core: core,query: query,legal: legal,index: index) }
        }
    }
    struct Boundary {
        let first: Int
        let second: Int
        let forward: [GraphV2Pack.CrossPackSeamAnchor]
        let reverse: [GraphV2Pack.CrossPackSeamAnchor]
    }
    enum Failure: Error, Equatable { case pagedArrayAccessUnsupported, invalidInput, unloadedRegion(String), sourceChanged, resourceLimit, missingArrival, incompatibleArrival }
    private struct Portal: Hashable { let pack: Int; let node: Int }
    private struct Memo {
        let digest: SHA256.Digest
        let destinationPack: Int
        let cursor: Cursor
    }
    private let sources: [Source]
    private let topology: [any ConnectedTopologySource]
    private let portals: [Portal: [Portal]]
    // Fixed entry count and fixed-size keys/values: no retained token arrays.
    private var memo: [Memo?] = Array(repeating: nil, count: 128)
    private var replacement = 0
    private(set) var transferCacheHits = 0
    private(set) var transferCacheMisses = 0

    init(sources: [Source], boundaries: [Boundary], requiredRegions: Set<String>) throws {
        guard !sources.isEmpty, sources.count <= 32, boundaries.count <= 1024,
              Set(sources.map(\.region)).count == sources.count,
              sources.allSatisfy({ $0.graphSHA256.count == 64 })
        else { throw Failure.invalidInput }
        for region in requiredRegions where !sources.contains(where: { $0.region == region }) {
            throw Failure.unloadedRegion(region)
        }
        self.sources = sources
        for source in sources { try RoutingWorkContext.check(); try source.validate() }
        self.topology = try sources.map { try $0.makeTopology() }
        var links: [Portal: [Portal]] = [:]
        var linkCount = 0
        for boundary in boundaries {
            try RoutingWorkContext.check()
            guard sources.indices.contains(boundary.first), sources.indices.contains(boundary.second),
                  boundary.first != boundary.second else { throw Failure.invalidInput }
            let pairs = try ExactGuidanceSeams.connections(local: topology[boundary.first],
                remote: topology[boundary.second], anchors: boundary.forward, reverse: boundary.reverse)
            for pair in pairs {
                let a = Portal(pack: boundary.first, node: pair.localNode)
                let b = Portal(pack: boundary.second, node: pair.remoteNode)
                if !(links[a] ?? []).contains(b) {
                    guard linkCount <= 8190 else { throw Failure.resourceLimit }
                    links[a, default: []].append(b); links[b, default: []].append(a); linkCount += 2
                }
            }
        }
        portals = links.mapValues { $0.sorted { $0.pack == $1.pack ? $0.node < $1.node : $0.pack < $1.pack } }
        for source in sources { try source.validate() }
    }

    var sourceCount: Int { sources.count }
    func startCursor(pack: Int,node: Int) throws -> Cursor {
        guard topology.indices.contains(pack) else { throw Failure.invalidInput }
        let source = topology[pack]
        try source.validate()
        let state = try source.startState(node: node)
        try source.validate()
        return .init(pack: pack,turnState: state,incomingEdge: -1,arrivedFrom: -1)
    }
    func sourceIdentityHash(pack: Int) throws -> String {
        guard topology.indices.contains(pack) else { throw Failure.invalidInput }
        try topology[pack].validate();return sources[pack].graphSHA256
    }

    func hasPortal(_ cursor: Cursor) throws -> Bool {
        guard topology.indices.contains(cursor.pack) else { throw Failure.invalidInput }
        try topology[cursor.pack].validate()
        let node = try self.node(cursor)
        return !(portals[.init(pack: cursor.pack, node: node)] ?? []).isEmpty
    }

    /// Diagnostic teardown does not read source files or mask the route failure.
    func publishDiagnostics() { for source in topology { source.publishDiagnostics() } }

    func validateSources() throws {
        for source in topology { try RoutingWorkContext.check(); try source.validate() }
    }

    func sourcePack(_ index: Int) throws -> GraphV2Pack {
        try RoutingWorkContext.check()
        guard sources.indices.contains(index) else { throw Failure.invalidInput }
        try sources[index].validate()
        guard let pack = topology[index].arrayPack else { throw Failure.pagedArrayAccessUnsupported }
        return pack
    }
    func node(_ cursor: Cursor) throws -> Int {
        guard topology.indices.contains(cursor.pack) else { throw Failure.invalidInput }
        try topology[cursor.pack].validate()
        return try topology[cursor.pack].graphNode(of: cursor.turnState)
    }

    /// Recorded-node arrivals only. Fractional arrivals need a separate virtual
    /// start representation; never move an edge-interior rider to its parent end.
    func cursor(pack: Int,arrival: NativeRoutingContinuation) throws -> Cursor {
        try RoutingWorkContext.check()
        guard topology.indices.contains(pack) else { throw Failure.invalidInput }
        guard case .node = arrival.location else { throw Failure.incompatibleArrival }
        let source = topology[pack]
        try source.validate()
        let imported = try source.import(arrival)
        let result = Cursor(pack: pack,turnState: imported.stateAtParentEnd,
            incomingEdge: imported.incomingEdge,arrivedFrom: imported.fromNode)
        guard try source.graphNode(of: result.turnState) == imported.toNode else { throw Failure.incompatibleArrival }
        try source.validate();return result
    }
    func continuation(_ cursor: Cursor) throws -> NativeRoutingContinuation {
        try RoutingWorkContext.check()
        guard topology.indices.contains(cursor.pack) else { throw Failure.invalidInput }
        guard cursor.incomingEdge >= 0,cursor.arrivedFrom >= 0 else { throw Failure.missingArrival }
        let source = topology[cursor.pack]
        try source.validate()
        let token = try source.export(state: cursor.turnState,edge: cursor.incomingEdge,from: cursor.arrivedFrom)
        try source.validate();return token
    }

    /// Halo duplicates share retrace identity even though local storage differs.
    func canonicalRoad(_ road: Road) throws -> CanonicalRoad {
        try RoutingWorkContext.check()
        guard sources.indices.contains(road.pack) else { throw Failure.invalidInput }
        let source = topology[road.pack]
        try source.validate()
        guard let epoch = source.sourceEpoch,!epoch.isEmpty,(0..<source.edgeCount).contains(road.edge) else { throw Failure.invalidInput }
        let row = try source.edge(road.edge)
        let a = try source.nodeID(row.from),b = try source.nodeID(row.to)
        let result = CanonicalRoad(sourceEpoch: epoch,wayID: row.way,firstNodeID: min(a,b),lastNodeID: max(a,b))
        try source.validate()
        return result
    }

    /// Existing native cost/access/town policy consumes these rows. Endpoint-only
    /// access is returned explicitly: this adapter must not silently allow it.
    func outgoing(_ cursor: Cursor, visit: (Traversal) throws -> Void) throws {
        try RoutingWorkContext.check()
        guard sources.indices.contains(cursor.pack) else { throw Failure.invalidInput }
        let source = topology[cursor.pack]
        try source.validate()
        let node = try source.graphNode(of: cursor.turnState)
        guard (0..<source.nodeCount).contains(node) else { throw Failure.invalidInput }
        try source.arcs(node) { arc in
            let state = try source.transition(state: cursor.turnState,edge: arc.edge,to: arc.to)
            if state < 0 { return }
            try visit(.init(destination: .init(pack: cursor.pack,turnState: state,incomingEdge: arc.edge,arrivedFrom: node),
                road: .init(pack: cursor.pack,edge: arc.edge),arc: arc.ordinal,from: node,to: arc.to,
                meters: arc.meters,attributes: arc.attributes,directedAccess: arc.directedAccess))
        }
        try source.validate(); try RoutingWorkContext.check()
    }

    /// Zero-distance legal-state transfer only at recorded identical OSM nodes.
    /// Missing turn context/road is an error, never a disconnected-road proof.
    /// Cursor carries actual predecessor identity without prescribing how labels
    /// merge states; the existing search must retain its exact legal state law.
    func transfers(_ cursor: Cursor) throws -> [Cursor] {
        try RoutingWorkContext.check()
        guard sources.indices.contains(cursor.pack) else { throw Failure.invalidInput }
        let source = topology[cursor.pack]
        try source.validate()
        let node = try source.graphNode(of: cursor.turnState)
        let destinations = portals[.init(pack: cursor.pack, node: node)] ?? []
        if destinations.isEmpty { return [] }
        guard cursor.incomingEdge >= 0, cursor.arrivedFrom >= 0 else { throw Failure.missingArrival }
        let token = try source.export(state: cursor.turnState,edge: cursor.incomingEdge,from: cursor.arrivedFrom)
        // Bound temporary token encoding before hashing; cache retains digest only.
        guard token.restrictionContext.count <= 256, token.activeRestrictions.count <= 256,
              token.restrictionContext.reduce(0, { $0 + $1.members.count }) <= 2048 else { throw Failure.resourceLimit }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(token))
        var result: [Cursor] = []
        for destination in destinations {
            try RoutingWorkContext.check()
            let target = topology[destination.pack]
            try target.validate()
            let transferred: Cursor
            var cached: Memo?
            for entry in memo {
                if let entry, entry.destinationPack == destination.pack, entry.digest == digest {
                    cached = entry; break
                }
            }
            if let hit = cached {
                transferCacheHits += 1; transferred = hit.cursor
            } else {
                transferCacheMisses += 1
                // Existing import validates exact directed road, epoch and full
                // restriction signatures; paged sources use their exact ID index.
                let imported = try target.import(token)
                guard imported.toNode == destination.node else { throw Failure.incompatibleArrival }
                transferred = .init(pack: destination.pack, turnState: imported.stateAtParentEnd,
                    incomingEdge: imported.incomingEdge, arrivedFrom: imported.fromNode)
                memo[replacement] = .init(digest: digest, destinationPack: destination.pack, cursor: transferred)
                replacement = (replacement + 1) % memo.count
            }
            guard try target.graphNode(of: transferred.turnState) == destination.node else { throw Failure.incompatibleArrival }
            try target.validate(); result.append(transferred)
        }
        try source.validate(); try RoutingWorkContext.check()
        return result
    }
}
