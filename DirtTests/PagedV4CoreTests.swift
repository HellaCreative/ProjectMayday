import CryptoKit
import Foundation
import Testing
@testable import Dirt

struct PagedV4CoreTests {
    private func original() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/legal-topology-restrictions.graph.v4.bin"))
    }
    private func identity(_ bytes: Data) -> PagedV4Core.Identity {
        .init(sha256: SHA256.hash(data: bytes).map { String(format: "%02x",$0) }.joined(),bytes: bytes.count)
    }
    private func file<T>(_ bytes: Data,_ body: (URL) throws -> T) throws -> T {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }
    private func read(_ bytes: Data,_ at: Int) -> Int {
        bytes.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at,as: UInt32.self))) }
    }
    private func put(_ bytes: inout Data,_ at: Int,_ value: Int) {
        var value = UInt32(value).littleEndian
        Swift.withUnsafeBytes(of: &value) { bytes.replaceSubrange(at..<at+4,with: $0) }
    }
    private func tail(_ original: Data,count: Int) -> Data {
        var bytes = original
        let n = read(bytes,8), arcs = read(bytes,16)
        let oldOffsets = read(bytes,24), oldCoords = read(bytes,44), oldIDs = read(bytes,104)
        var offsets = bytes.subdata(in: oldOffsets..<(oldOffsets+(n+1)*4))
        for _ in 0..<count { var end = UInt32(arcs).littleEndian; Swift.withUnsafeBytes(of: &end) { offsets.append(contentsOf: $0) } }
        var coords = bytes.subdata(in: oldCoords..<(oldCoords+n*8)); coords.append(Data(repeating: 0,count: count*8))
        var ids = bytes.subdata(in: oldIDs..<(oldIDs+n*8))
        for i in 0..<count { var id = Int64(100_000+i).littleEndian; Swift.withUnsafeBytes(of: &id) { ids.append(contentsOf: $0) } }
        func add(_ section: Data) -> Int {
            while bytes.count%8 != 0 { bytes.append(0) }
            let at = bytes.count; bytes.append(section); return at
        }
        let o = add(offsets), c = add(coords), i = add(ids)
        put(&bytes,8,n+count); put(&bytes,24,o); put(&bytes,44,c); put(&bytes,104,i)
        return bytes
    }
    @Test func exactCoreRowsAndCSRMatchDecodedFixture() throws {
        let bytes = try original(), expected = try GraphV2Pack(data: bytes)
        try file(bytes) { url in
            let reader = try PagedV4Core(url: url,identity: identity(bytes))
            defer { reader.close() }
            #expect(reader.preparation.validationArcs == expected.directedArcCount)
            #expect(reader.preparation.hashedBytes == bytes.count)
            #expect(reader.queryStatistics.scalars == 0)
            try reader.withQuery { query in
                for node in 0..<expected.nodeCount {
                    let row = try query.node(node)
                    #expect(row.longitude.bitPattern == expected.nodeCoords[node*2].bitPattern)
                    #expect(row.latitude.bitPattern == expected.nodeCoords[node*2+1].bitPattern)
                    #expect(row.osmID == expected.osmNodeIds[node])
                    var indices: [Int] = []
                    try query.outgoing(node) { arc in
                        indices.append(arc.index)
                        #expect(arc.source == node && arc.target == Int(expected.edgeTargets[arc.index]))
                        #expect(arc.edge == Int(expected.edgeUndirectedIndex[arc.index]))
                    }
                    #expect(indices == Array(Int(expected.nodeOffsets[node])..<Int(expected.nodeOffsets[node+1])))
                }
                for edge in 0..<expected.undirectedEdgeCount {
                    let row = try query.edge(edge)
                    #expect(row.from == Int(expected.edgeFrom![edge]) && row.to == Int(expected.edgeTo![edge]))
                    #expect(row.meters == expected.edgeMeters[edge] && row.attributes == expected.edgeAttrs[edge])
                    #expect(row.osmWayID == expected.osmWayIds[edge])
                    #expect(row.forwardAccess == expected.edgeAccess[edge*2] && row.reverseAccess == expected.edgeAccess[edge*2+1])
                }
            }
            #expect(reader.pageStatistics.peakLivePayloadBytes <= reader.pageStatistics.maximumLivePayloadBytes)
            #expect(throws: PagedV4Core.Failure.legalMetadataUnavailable) { try reader.requireLegalMetadata() }
        }
    }
    @Test func largeUnusedTailProofReuseDoesNotDecodeWholeCoreOnQuery() throws {
        let bytes = tail(try original(),count: 4096)
        try file(bytes) { url in
            let prepared = try PagedV4Core(url: url,identity: identity(bytes))
            let proof = prepared.proof
            #expect(prepared.preparation.validationNodes > 4096)
            prepared.close()
            let reader = try PagedV4Core(url: url,identity: identity(bytes),proof: proof)
            defer { reader.close() }
            #expect(reader.preparation.reusedTopologyProof && reader.preparation.validationArcs == 0)
            try reader.withQuery { query in
                _ = try query.node(reader.nodeCount-1)
                try query.outgoing(reader.nodeCount-1) { _ in Issue.record("Unused tail acquired invented arc") }
            }
            #expect(reader.queryStatistics.nodes == 1 && reader.queryStatistics.arcs == 0)
            #expect(reader.queryStatistics.scalars == 5)
            #expect(reader.queryStatistics.borrowedPages <= 4)
            #expect(reader.pageStatistics.peakLivePayloadBytes <= reader.pageStatistics.maximumLivePayloadBytes)
        }
    }
    @Test func queriedInvalidIdentityCoordinatesAndAccessAreDataErrors() throws {
        for corruption in 0..<4 {
            var bytes = try original()
            switch corruption {
            case 0:
                let offset = read(bytes,104)
                bytes.replaceSubrange(offset..<offset+8,with: Data(repeating: 0,count: 8))
            case 1: put(&bytes,read(bytes,44),Int(Float.nan.bitPattern))
            case 2: put(&bytes,read(bytes,44)+4,Int(Float(91).bitPattern))
            default: bytes[read(bytes,112)] = 255
            }
            try file(bytes) { url in
                let reader = try PagedV4Core(url: url,identity: identity(bytes))
                defer { reader.close() }
                try reader.withQuery { query in
                    if corruption == 3 {
                        #expect(throws: PagedV4Core.Failure.invalidLegalMetadata) { try query.edge(0) }
                    } else {
                        #expect(throws: PagedV4Core.Failure.invalidTopology) { try query.node(0) }
                    }
                }
            }
        }
    }
    @Test func corruptionAndWrongProofCannotBecomeDisconnected() throws {
        let bytes = try original()
        try file(bytes) { url in
            let first = try PagedV4Core(url: url,identity: identity(bytes)); let proof = first.proof; first.close()
            var bad = bytes; put(&bad,read(bad,28),read(bad,8))
            try file(bad) { badURL in
                #expect(throws: PagedV4Core.Failure.invalidTopology) { try PagedV4Core(url: badURL,identity: identity(bad)) }
                #expect(throws: PagedV4Core.Failure.identityMismatch) { try PagedV4Core(url: badURL,identity: identity(bad),proof: proof) }
            }
        }
    }
    @Test func cancellationClosedScopesAndChangedSourceThrow() throws {
        let bytes = try original()
        try file(bytes) { url in
            #expect(throws: RoutingPageError.cancelled) { try PagedV4Core(url: url,identity: identity(bytes),cancelled: { true }) }
            let reader = try PagedV4Core(url: url,identity: identity(bytes))
            defer { reader.close() }
            var escaped: PagedV4Core.Query?
            try reader.withQuery { escaped = $0; _ = try $0.node(0) }
            #expect(throws: PagedV4Core.Failure.queryClosed) { try escaped!.node(0) }
            #expect(throws: RoutingPageError.cancelled) { try reader.withQuery(cancelled: { true }) { try $0.edge(0) } }
            #expect(throws: (any Error).self) {
                try reader.withQuery { query in
                    _ = try query.node(0)
                    let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                    try handle.truncate(atOffset: 140)
                    // Final source validation must reject even already cached rows.
                }
            }
        }
    }
    @Test func leaflessV4IsExplicitlyUnsupported() throws {
        var bytes = try original(); bytes[6] &= ~UInt8(2)
        try file(bytes) { url in
            #expect(throws: PagedV4Core.Failure.unsupportedLeaflessV4) {
                try PagedV4Core(url: url,identity: identity(bytes))
            }
        }
    }

}
