import CryptoKit
import Foundation
import Testing
@testable import Dirt

struct ConnectedPackStageViewTests {
    private final class Validity { var valid = true }
    private func fixture() throws -> (GraphV2Pack, String) {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/legal-topology-restrictions.graph.v4.bin")
        let bytes = try Data(contentsOf: url)
        return (try GraphV2Pack(data: bytes), SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    private func setup() throws -> (ConnectedPackStageView, ConnectedPackStageView.Cursor, GraphV2Pack, Validity) {
        let (a, hash) = try fixture(), (b, _) = try fixture()
        let from = Int(try #require(a.edgeFrom?[0])), to = Int(try #require(a.edgeTo?[0]))
        try #require(a.hasDirectedArc(from: from, to: to, edge: 0))
        let id = "\(a.osmWayIds[0]):\(a.osmNodeIds[from]):\(a.osmNodeIds[to])"
        let anchor = GraphV2Pack.CrossPackSeamAnchor(neighborRegionId: "b",
            longitude: Double(a.nodeCoords[to * 2]), latitude: Double(a.nodeCoords[to * 2 + 1]),
            osmWayId: String(a.osmWayIds[0]), localEdgeId: id, remoteEdgeId: id,
            gapMeters: 0, osmNodeId: a.osmNodeIds[to])
        let valid = Validity()
        let view = try ConnectedPackStageView(sources: [
            .init(region: "a", pack: a, graphSHA256: hash, validate: {}),
            .init(region: "b", pack: b, graphSHA256: hash, validate: {
                if !valid.valid { throw ConnectedPackStageView.Failure.sourceChanged }
            })], boundaries: [.init(first: 0, second: 1, forward: [anchor], reverse: [anchor])], requiredRegions: ["a", "b"])
        let turns = a.makeV4TurnStateSpace(startNode: a.nodeCount, endNode: a.nodeCount + 1)
        return (view, .init(pack: 0, turnState: turns.stateForArrival(node: to, incomingEdge: 0), incomingEdge: 0, arrivedFrom: from), a, valid)
    }
    @Test func nativeTurnStateSurvivesSeamAndCSRStillUsesLocalIdentity() throws {
        let (view, cursor, pack, _) = try setup()
        let transferred = try #require(try view.transfers(cursor).first)
        #expect(transferred.pack == 1)
        var local: [ConnectedPackStageView.Traversal] = [], remote: [ConnectedPackStageView.Traversal] = []
        try view.outgoing(cursor) { local.append($0) }
        try view.outgoing(transferred) { remote.append($0) }
        let turns = pack.makeV4TurnStateSpace(startNode: pack.nodeCount, endNode: pack.nodeCount + 1)
        let node = turns.graphNode(of: cursor.turnState)
        let expected = (Int(pack.nodeOffsets[node])..<Int(pack.nodeOffsets[node + 1])).filter { arc in
            turns.transition(state: cursor.turnState, outgoingEdge: Int(pack.edgeUndirectedIndex[arc]), toNode: Int(pack.edgeTargets[arc])) >= 0
        }
        #expect(local.map(\.arc) == expected)
        #expect(local.map { $0.road.edge } == remote.map { $0.road.edge })
        #expect(try local.map { try view.canonicalRoad($0.road) } == remote.map { try view.canonicalRoad($0.road) })
        #expect(local.map(\.meters) == remote.map(\.meters))
        #expect(local.map(\.directedAccess) == remote.map(\.directedAccess))
        #expect(local.allSatisfy { $0.road.pack == 0 } && remote.allSatisfy { $0.road.pack == 1 })
        #expect(try view.transfers(cursor) == [transferred])
        #expect(view.transferCacheHits == 1 && view.transferCacheMisses == 1)
    }
    @Test func cachedTransferStillChecksSourceAndCancellation() throws {
        let (view, cursor, _, valid) = try setup()
        _ = try view.transfers(cursor)
        valid.valid = false
        #expect(throws: ConnectedPackStageView.Failure.self) { try view.transfers(cursor) }
        valid.valid = true
        RoutingWorkContext.$deadline.withValue(0) {
            #expect(throws: (any Error).self) { try view.transfers(cursor) }
        }
    }
    @Test func missingPackOrLegalArrivalCannotBecomeDisconnectedResult() throws {
        let (pack, hash) = try fixture()
        #expect(throws: ConnectedPackStageView.Failure.self) {
            try ConnectedPackStageView(sources: [.init(region: "a", pack: pack, graphSHA256: hash, validate: {})],
                boundaries: [], requiredRegions: ["a", "missing"])
        }
        let (view, cursor, _, _) = try setup()
        #expect(throws: ConnectedPackStageView.Failure.self) {
            try view.transfers(.init(pack: cursor.pack, turnState: cursor.turnState, incomingEdge: -1, arrivedFrom: -1))
        }
    }
}
