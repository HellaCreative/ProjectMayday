import Foundation
import CryptoKit
import Testing
@testable import Dirt

struct PagedExactSeamTests {
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
    @Test func pagedAndSharedArrayBindExactlyTheReferenceNodes() throws {
        let data = try fixture(),pack = try GraphV2Pack(data: data)
        try withPrepared(data) { core,index in
            try core.withQuery { query in try core.withLegalQuery { legal in
                let paged = try PagedExactSeamTopology(core: core,query: query,legal: legal,index: index)
                for atEnd in [false,true] {
                    let row = try anchor(pack,atEnd: atEnd)
                    let expected = try ExactGuidanceSeams.connections(local: pack,remote: pack,anchors: [row,row],reverse: [row])
                    let sharedArray = try ExactGuidanceSeams.connections(local: ArrayExactSeamTopology(pack: pack),remote: ArrayExactSeamTopology(pack: pack),anchors: [row,row],reverse: [row])
                    let actual = try ExactGuidanceSeams.connections(local: paged,remote: paged,anchors: [row,row],reverse: [row])
                    #expect(actual == expected && sharedArray == expected && actual.count == 1)
                    var forged = row
                    forged.osmNodeId = pack.osmNodeIds.first { $0 != pack.osmNodeIds[Int(pack.edgeFrom![0])] && $0 != pack.osmNodeIds[Int(pack.edgeTo![0])] }
                    // Identical coordinates cannot replace the recorded original
                    // endpoint membership with another graph node.
                    #expect(throws: (any Error).self) {
                        try ExactGuidanceSeams.connections(local: paged,remote: paged,anchors: [forged],reverse: [forged])
                    }
                    let other = GraphV2Pack.CrossPackSeamAnchor(
                        neighborRegionId: row.neighborRegionId, longitude: row.longitude,
                        latitude: row.latitude, osmWayId: row.osmWayId,
                        localEdgeId: row.localEdgeId, remoteEdgeId: row.remoteEdgeId + ":invalid",
                        gapMeters: row.gapMeters, osmNodeId: row.osmNodeId)
                    #expect(throws: (any Error).self) {
                        try ExactGuidanceSeams.connections(local: paged,remote: paged,anchors: [row],reverse: [other])
                    }
                }
            } }
        }
    }
    @Test func escapedQueryAndDifferentIndexCannotPublishSeams() throws {
        let data = try fixture(),pack = try GraphV2Pack(data: data),row = try anchor(pack,atEnd: false)
        try withPrepared(data) { core,index in
            var escaped: PagedExactSeamTopology?
            try core.withQuery { query in try core.withLegalQuery { legal in
                escaped = try PagedExactSeamTopology(core: core,query: query,legal: legal,index: index)
            } }
            let value = try #require(escaped)
            #expect(throws: (any Error).self) {
                try ExactGuidanceSeams.connections(local: value,remote: value,anchors: [row],reverse: [row])
            }
            var changed = data;changed[changed.count-1] ^= 1
            try withPrepared(changed) { other,_ in
                try other.withQuery { query in try other.withLegalQuery { legal in
                    #expect(throws: PagedV4Core.Failure.identityMismatch) {
                        try PagedExactSeamTopology(core: other,query: query,legal: legal,index: index)
                    }
                } }
            }
        }
    }
}
