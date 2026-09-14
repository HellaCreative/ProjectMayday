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
        let pack: GraphV2Pack
        /// Verified graph SHA-256; caller must bind validate to the opened source.
        let graphSHA256: String
        let validate: () throws -> Void
    }
    struct Boundary {
        let first: Int
        let second: Int
        let forward: [GraphV2Pack.CrossPackSeamAnchor]
        let reverse: [GraphV2Pack.CrossPackSeamAnchor]
    }
    enum Failure: Error { case invalidInput, unloadedRegion(String), sourceChanged, resourceLimit, missingArrival, incompatibleArrival }
    private struct Portal: Hashable { let pack: Int; let node: Int }
    private struct Memo {
        let digest: SHA256.Digest
        let destinationPack: Int
        let cursor: Cursor
    }
    private let sources: [Source]
    private let turns: [GraphV2Pack.V4TurnStateSpace]
    private let portals: [Portal: [Portal]]
    // Fixed entry count and fixed-size keys/values: no retained token arrays.
    private var memo: [Memo?] = Array(repeating: nil, count: 128)
    private var replacement = 0
    private(set) var transferCacheHits = 0
    private(set) var transferCacheMisses = 0

    init(sources: [Source], boundaries: [Boundary], requiredRegions: Set<String>) throws {
        guard !sources.isEmpty, sources.count <= 32, boundaries.count <= 1024,
              Set(sources.map(\.region)).count == sources.count,
              sources.allSatisfy({ $0.graphSHA256.count == 64 && $0.pack.version >= 4 && $0.pack.legalTopology })
        else { throw Failure.invalidInput }
        for region in requiredRegions where !sources.contains(where: { $0.region == region }) {
            throw Failure.unloadedRegion(region)
        }
        self.sources = sources
        for source in sources { try RoutingWorkContext.check(); try source.validate() }
        self.turns = sources.map { $0.pack.makeV4TurnStateSpace(startNode: $0.pack.nodeCount, endNode: $0.pack.nodeCount + 1) }
        var links: [Portal: [Portal]] = [:]
        var linkCount = 0
        for boundary in boundaries {
            try RoutingWorkContext.check()
            guard sources.indices.contains(boundary.first), sources.indices.contains(boundary.second),
                  boundary.first != boundary.second else { throw Failure.invalidInput }
            let pairs = try ExactGuidanceSeams.connections(local: sources[boundary.first].pack,
                remote: sources[boundary.second].pack, anchors: boundary.forward, reverse: boundary.reverse)
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

    func hasPortal(_ cursor: Cursor) throws -> Bool {
        _ = try sourcePack(cursor.pack)
        let node = try self.node(cursor)
        return !(portals[.init(pack: cursor.pack, node: node)] ?? []).isEmpty
    }

    func validateSources() throws {
        for source in sources { try RoutingWorkContext.check(); try source.validate() }
    }

    func sourcePack(_ index: Int) throws -> GraphV2Pack {
        try RoutingWorkContext.check()
        guard sources.indices.contains(index) else { throw Failure.invalidInput }
        try sources[index].validate()
        return sources[index].pack
    }
    func node(_ cursor: Cursor) throws -> Int {
        guard turns.indices.contains(cursor.pack) else { throw Failure.invalidInput }
        return turns[cursor.pack].graphNode(of: cursor.turnState)
    }

    /// Halo duplicates share retrace identity even though local storage differs.
    func canonicalRoad(_ road: Road) throws -> CanonicalRoad {
        try RoutingWorkContext.check()
        guard sources.indices.contains(road.pack) else { throw Failure.invalidInput }
        let source = sources[road.pack], pack = source.pack
        try source.validate()
        guard let epoch = pack.sourceEpoch, !epoch.isEmpty,
              pack.osmWayIds.indices.contains(road.edge),
              let from = pack.edgeFrom, let to = pack.edgeTo,
              from.indices.contains(road.edge), to.indices.contains(road.edge),
              pack.osmNodeIds.indices.contains(Int(from[road.edge])),
              pack.osmNodeIds.indices.contains(Int(to[road.edge])) else { throw Failure.invalidInput }
        let a = pack.osmNodeIds[Int(from[road.edge])], b = pack.osmNodeIds[Int(to[road.edge])]
        let result = CanonicalRoad(sourceEpoch: epoch, wayID: pack.osmWayIds[road.edge],
            firstNodeID: min(a,b), lastNodeID: max(a,b))
        try source.validate()
        return result
    }

    /// Existing native cost/access/town policy consumes these rows. Endpoint-only
    /// access is returned explicitly: this adapter must not silently allow it.
    func outgoing(_ cursor: Cursor, visit: (Traversal) throws -> Void) throws {
        try RoutingWorkContext.check()
        guard sources.indices.contains(cursor.pack) else { throw Failure.invalidInput }
        let source = sources[cursor.pack], pack = source.pack, turn = turns[cursor.pack]
        try source.validate()
        let node = turn.graphNode(of: cursor.turnState)
        guard node >= 0, node < pack.nodeCount else { throw Failure.invalidInput }
        let begin = Int(pack.nodeOffsets[node]), end = Int(pack.nodeOffsets[node + 1])
        guard begin >= 0, end >= begin, end <= pack.edgeTargets.count,
              end <= pack.edgeUndirectedIndex.count else { throw Failure.invalidInput }
        for arc in begin..<end {
            try RoutingWorkContext.check()
            let edge = Int(pack.edgeUndirectedIndex[arc]), target = Int(pack.edgeTargets[arc])
            guard edge >= 0, edge < pack.undirectedEdgeCount, target >= 0, target < pack.nodeCount else { throw Failure.invalidInput }
            let state = turn.transition(state: cursor.turnState, outgoingEdge: edge, toNode: target)
            if state < 0 { continue }
            try visit(.init(destination: .init(pack: cursor.pack, turnState: state, incomingEdge: edge, arrivedFrom: node),
                road: .init(pack: cursor.pack, edge: edge), arc: arc, from: node, to: target,
                meters: Double(pack.edgeMeters[edge]), attributes: pack.edgeAttrs[edge],
                directedAccess: pack.v4AccessCode(ei: edge, from: node, to: target)))
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
        let source = sources[cursor.pack], turn = turns[cursor.pack]
        try source.validate()
        let node = turn.graphNode(of: cursor.turnState)
        let destinations = portals[.init(pack: cursor.pack, node: node)] ?? []
        if destinations.isEmpty { return [] }
        guard cursor.incomingEdge >= 0, cursor.arrivedFrom >= 0 else { throw Failure.missingArrival }
        let token = try turn.exportContinuation(state: cursor.turnState, incomingEdge: cursor.incomingEdge,
            arrivedFromNode: cursor.arrivedFrom, pack: source.pack)
        // Bound temporary token encoding before hashing; cache retains digest only.
        guard token.restrictionContext.count <= 256, token.activeRestrictions.count <= 256,
              token.restrictionContext.reduce(0, { $0 + $1.members.count }) <= 2048 else { throw Failure.resourceLimit }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(token))
        var result: [Cursor] = []
        for destination in destinations {
            try RoutingWorkContext.check()
            let target = sources[destination.pack]
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
                // restriction signatures. Its initial scan remains O(region).
                let imported = try turns[destination.pack].importContinuation(token, pack: target.pack)
                guard imported.toNode == destination.node else { throw Failure.incompatibleArrival }
                transferred = .init(pack: destination.pack, turnState: imported.stateAtParentEnd,
                    incomingEdge: imported.incomingEdge, arrivedFrom: imported.fromNode)
                memo[replacement] = .init(digest: digest, destinationPack: destination.pack, cursor: transferred)
                replacement = (replacement + 1) % memo.count
            }
            guard turns[destination.pack].graphNode(of: transferred.turnState) == destination.node else { throw Failure.incompatibleArrival }
            try target.validate(); result.append(transferred)
        }
        try source.validate(); try RoutingWorkContext.check()
        return result
    }
}
