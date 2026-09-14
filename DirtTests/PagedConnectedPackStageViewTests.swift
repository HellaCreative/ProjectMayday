import Foundation
import CryptoKit
import Testing
@testable import Dirt

struct PagedConnectedPackStageViewTests {
    private func fixture(_ name: String = "legal-topology-restrictions.graph.v4.bin") throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/"+name))
    }
    private func withPrepared(_ data: Data,_ body: (PagedV4Core,OriginalIDIndex) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paged-continuation-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let graph = dir.appendingPathComponent("graph.bin"),ids = dir.appendingPathComponent("ids.bin")
        try data.write(to: graph)
        let hash = SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined()
        try OriginalIDIndex.prepare(graphURL: graph,to: ids,identity: .init(graphSHA256: hash,graphBytes: data.count))
        let index = try OriginalIDIndex(url: ids,graphURL: graph,identity: .init(graphSHA256: hash,graphBytes: data.count))
        let core = try PagedV4Core(url: graph,identity: .init(sha256: hash,bytes: data.count))
        try body(core,index)
    }
    private func anchor(_ pack: GraphV2Pack,atEnd: Bool) throws -> GraphV2Pack.CrossPackSeamAnchor {
        let a = Int(try #require(pack.edgeFrom?[0])),b = Int(try #require(pack.edgeTo?[0]))
        let node = atEnd ? b : a
        let id = "\(pack.osmWayIds[0]):\(pack.osmNodeIds[a]):\(pack.osmNodeIds[b])"
        return .init(neighborRegionId: "other",longitude: Double(pack.nodeCoords[node*2]),latitude: Double(pack.nodeCoords[node*2+1]),
            osmWayId: String(pack.osmWayIds[0]),localEdgeId: id,remoteEdgeId: id,gapMeters: 0,osmNodeId: pack.osmNodeIds[node])
    }
    @Test func arrayAndPagedTraversalAndCachedTransfersAreIdentical() throws {
        let data = try fixture(),pack = try GraphV2Pack(data: data)
        let from = Int(try #require(pack.edgeFrom?[0])),to = Int(try #require(pack.edgeTo?[0]))
        let turns = pack.makeV4TurnStateSpace(startNode: pack.nodeCount,endNode: pack.nodeCount+1)
        let cursor = ConnectedPackStageView.Cursor(pack: 0,turnState: turns.stateForArrival(node: to,incomingEdge: 0),incomingEdge: 0,arrivedFrom: from)
        let row = try anchor(pack,atEnd: true)
        let hash = SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined()
        let array = try ConnectedPackStageView(sources: [
            .init(region: "a",pack: pack,graphSHA256: hash,validate: {}),
            .init(region: "b",pack: pack,graphSHA256: hash,validate: {})],
            boundaries: [.init(first: 0,second: 1,forward: [row],reverse: [row])],requiredRegions: ["a","b"])
        try withPrepared(data) { core,index in
            var escaped: ConnectedPackStageView?
            var expiredCursor: ConnectedPackStageView.Cursor?
            try core.withQuery { query in try core.withLegalQuery { legal in
                let paged = try ConnectedPackStageView(sources: [
                    .init(region: "a",core: core,query: query,legal: legal,index: index),
                    .init(region: "b",core: core,query: query,legal: legal,index: index)],
                    boundaries: [.init(first: 0,second: 1,forward: [row],reverse: [row])],requiredRegions: ["a","b"])
                #expect(paged.sourceCount == 2)
                #expect(try paged.sourceIdentityHash(pack: 0) == array.sourceIdentityHash(pack: 0))
                #expect(try paged.node(paged.startCursor(pack: 0,node: from)) == from)
                #expect(throws: (any Error).self) { try paged.startCursor(pack: 0,node: -1) }
                escaped = paged
                let pagedCursor = try paged.cursor(pack: 0,arrival: array.continuation(cursor))
                expiredCursor = pagedCursor
                #expect(try paged.node(pagedCursor) == array.node(cursor))
                #expect(try paged.hasPortal(pagedCursor) && array.hasPortal(cursor))
                let expectedTransfers = try array.transfers(cursor)
                let actualTransfers = try paged.transfers(pagedCursor)
                #expect(actualTransfers.map(\.pack) == expectedTransfers.map(\.pack))
                #expect(try actualTransfers.map { try paged.continuation($0) } == expectedTransfers.map { try array.continuation($0) })
                #expect(try paged.transfers(pagedCursor) == actualTransfers)
                #expect(paged.transferCacheHits == 1 && paged.transferCacheMisses == 1)
                for (current,pagedCurrent) in zip([cursor] + expectedTransfers,[pagedCursor] + actualTransfers) {
                    var expected: [ConnectedPackStageView.Traversal] = [],actual: [ConnectedPackStageView.Traversal] = []
                    try array.outgoing(current) { expected.append($0) }
                    try paged.outgoing(pagedCurrent) { actual.append($0) }
                    #expect(!expected.isEmpty)
                    #expect(actual.map(\.arc) == expected.map(\.arc))
                    #expect(actual.map(\.road) == expected.map(\.road))
                    #expect(try actual.map { try paged.continuation($0.destination) } == expected.map { try array.continuation($0.destination) })
                    #expect(actual.map(\.from) == expected.map(\.from))
                    #expect(actual.map(\.to) == expected.map(\.to))
                    #expect(actual.map(\.meters) == expected.map(\.meters))
                    #expect(actual.map(\.attributes) == expected.map(\.attributes))
                    #expect(actual.map(\.directedAccess) == expected.map(\.directedAccess))
                    #expect(try actual.map { try paged.canonicalRoad($0.road) } == expected.map { try array.canonicalRoad($0.road) })
                }
                let token = try array.continuation(cursor)
                let fractional = NativeRoutingContinuation(version: token.version,sourceEpoch: token.sourceEpoch,
                    incoming: token.incoming,location: .edge(fraction: 0.5),
                    restrictionContext: token.restrictionContext,activeRestrictions: token.activeRestrictions)
                #expect(throws: ConnectedPackStageView.Failure.incompatibleArrival) { try paged.cursor(pack: 0,arrival: fractional) }
                let stale = NativeRoutingContinuation(version: token.version,sourceEpoch: "wrong-epoch",
                    incoming: token.incoming,location: token.location,
                    restrictionContext: token.restrictionContext,activeRestrictions: token.activeRestrictions)
                #expect(throws: (any Error).self) { try paged.cursor(pack: 0,arrival: stale) }
                let missingContext = NativeRoutingContinuation(version: token.version,sourceEpoch: token.sourceEpoch,
                    incoming: token.incoming,location: token.location,restrictionContext: [],
                    activeRestrictions: [.init(relationID: Int64.max,memberIndex: 1)])
                #expect(throws: (any Error).self) { try paged.cursor(pack: 0,arrival: missingContext) }
                let wrongDirection = NativeRoutingContinuation(version: token.version,sourceEpoch: token.sourceEpoch,
                    incoming: .init(wayID: token.incoming.wayID,fromNodeID: token.incoming.toNodeID,toNodeID: token.incoming.fromNodeID),
                    location: token.location,restrictionContext: token.restrictionContext,activeRestrictions: token.activeRestrictions)
                #expect(throws: (any Error).self) { try paged.cursor(pack: 0,arrival: wrongDirection) }
                #expect(throws: ConnectedPackStageView.Failure.pagedArrayAccessUnsupported) { try paged.sourcePack(0) }
                RoutingWorkContext.$deadline.withValue(0) {
                    #expect(throws: (any Error).self) { try paged.transfers(pagedCursor) }
                }
            } }
            let closed = try #require(escaped)
            let cursor = try #require(expiredCursor)
            // Cached transfers must not extend the lifetime of either query.
            #expect(throws: (any Error).self) { try closed.transfers(cursor) }
            #expect(throws: (any Error).self) { try closed.outgoing(cursor) { _ in } }
            #expect(throws: (any Error).self) { try closed.canonicalRoad(.init(pack: 0,edge: 0)) }
            #expect(throws: (any Error).self) { try closed.hasPortal(cursor) }
        }
    }
}
