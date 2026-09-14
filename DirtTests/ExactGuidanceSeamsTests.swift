import Foundation
import Testing
@testable import Dirt

struct ExactGuidanceSeamsTests {
    private func fixture() throws -> GraphV2Pack {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/legal-topology-restrictions.graph.v4.bin")
        return try GraphV2Pack(data: Data(contentsOf: url))
    }
    private func anchor(_ pack: GraphV2Pack, nodeAtEnd: Bool = false) throws -> GraphV2Pack.CrossPackSeamAnchor {
        let from = try #require(pack.edgeFrom), to = try #require(pack.edgeTo)
        let a = Int(from[0]), b = Int(to[0]), node = nodeAtEnd ? b : a
        let id = "\(pack.osmWayIds[0]):\(pack.osmNodeIds[a]):\(pack.osmNodeIds[b])"
        return .init(neighborRegionId: "nb", longitude: Double(pack.nodeCoords[node*2]),
            latitude: Double(pack.nodeCoords[node*2+1]), osmWayId: String(pack.osmWayIds[0]),
            localEdgeId: id, remoteEdgeId: id, gapMeters: 0, osmNodeId: pack.osmNodeIds[node])
    }
    @Test func sameOriginalNodeBindsWithoutGeometryOrSpatialIndexAndDeduplicates() throws {
        let a = try fixture(), b = try fixture(), row = try anchor(a)
        #expect(a.exactSnapIndex == nil && a.geometry == nil)
        let result = try ExactGuidanceSeams.connections(local: a, remote: b,
            anchors: [row,row], reverse: [row,row])
        #expect(result.count == 1)
        #expect(a.osmNodeIds[result[0].localNode] == b.osmNodeIds[result[0].remoteNode])
    }
    @Test func bothEndpointsResolveIncludingIncomingOnlyRecordedEdge() throws {
        let a = try fixture(), b = try fixture()
        for atEnd in [false,true] {
            let row = try anchor(a,nodeAtEnd: atEnd)
            let result = try ExactGuidanceSeams.connections(local: a,remote: b,anchors: [row],reverse: [row])
            #expect(result.count == 1)
        }
    }
    @Test func missingReciprocalOrFalseOriginalNodeNeverFallsBackToCoordinates() throws {
        let a = try fixture(), b = try fixture(); var row = try anchor(a)
        #expect(throws: ExactGuidanceSeams.Failure.self) {
            try ExactGuidanceSeams.connections(local:a,remote:b,anchors:[row],reverse:[])
        }
        row.osmNodeId = Int64.max
        #expect(throws: ExactGuidanceSeams.Failure.self) {
            try ExactGuidanceSeams.connections(local:a,remote:b,anchors:[row],reverse:[row])
        }
    }
    @Test func expiredWindowCannotPublishBindings() throws {
        let a = try fixture(), b = try fixture(), row = try anchor(a)
        RoutingWorkContext.$deadline.withValue(0) {
            #expect(throws: (any Error).self) {
                try ExactGuidanceSeams.connections(local: a, remote: b, anchors: [row], reverse: [row])
            }
        }
    }
    @Test func verifiedSidecarDecodeDoesNotReplaceSharedPackDictionary() throws {
        let pack = try fixture(); pack.regionId = "ns"
        let row = try anchor(pack)
        let before = pack.crossPackSeams.count
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": "dirt-cross-pack-seams.v2", "regionId": "ns",
            "sourceEpoch": try #require(pack.sourceEpoch),
            "neighbors": ["nb": [["coordinate": [row.longitude,row.latitude],
                "gapMeters": 0, "osmNodeId": String(try #require(row.osmNodeId)),
                "osmWayId": row.osmWayId, "localEdgeId": row.localEdgeId,
                "remoteEdgeId": row.remoteEdgeId]]]
        ])
        let snapshot = try pack.decodedCrossPackSeams(data: data)
        #expect(snapshot["nb"]?.count == 1)
        #expect(pack.crossPackSeams.count == before)
    }

    @Test func unmatchedReverseRowIsIncompleteButExtraIdenticalRowsAreAllowed() throws {
        let a = try fixture(), b = try fixture(), row = try anchor(a)
        var unmatched = row; unmatched.osmNodeId = Int64.max
        #expect(throws: ExactGuidanceSeams.Failure.self) {
            try ExactGuidanceSeams.connections(local: a, remote: b, anchors: [row], reverse: [row,unmatched])
        }
        let result = try ExactGuidanceSeams.connections(local: a, remote: b, anchors: [row], reverse: [row,row])
        #expect(result.count == 1)
    }
    @Test func malformedStoredEndpointAndCSRFailWithoutUncheckedSubscripts() throws {
        let good = try fixture(), row = try anchor(good)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/legal-topology-restrictions.graph.v4.bin")
        let from = try #require(good.edgeFrom), to = try #require(good.edgeTo)
        let firstNode = Int(from[0]), lastNode = Int(to[0])
        // Follow the same endpoint order as the proof and locate the actual
        // directed CSR occurrence of the recorded edge. Local node/arc zero
        // need not belong to this seam, even though its undirected edge is zero.
        let referencedArc = try #require([firstNode,lastNode].lazy.compactMap { node in
            (Int(good.nodeOffsets[node])..<Int(good.nodeOffsets[node+1])).first {
                Int(good.edgeUndirectedIndex[$0]) == 0
            }
        }.first)
        let mutations: [(header: Int,cell: Int)] = [
            (24,firstNode), (28,referencedArc), (32,referencedArc), (64,0), (68,0)
        ]
        for mutation in mutations {
            var bytes = try Data(contentsOf: url)
            let section = Int(bytes.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: mutation.header,as: UInt32.self).littleEndian
            })
            let at = section + mutation.cell * MemoryLayout<UInt32>.stride
            bytes.replaceSubrange(at..<(at+4),with: [UInt8](repeating: 255,count: 4))
            let malformed: GraphV2Pack
            do { malformed = try GraphV2Pack(data: bytes) }
            catch { continue } // Earlier structural rejection is also safe.
            #expect(throws: ExactGuidanceSeams.Failure.self) {
                try ExactGuidanceSeams.connections(local: malformed,remote: good,anchors: [row],reverse: [row])
            }
        }
    }

}
