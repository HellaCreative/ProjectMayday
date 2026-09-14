import CryptoKit
import Foundation
import Testing
@testable import Dirt

struct PagedV4LegalMetadataTests {
    private func bytes() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/legal-topology-restrictions.graph.v4.bin"))
    }
    private func u32(_ data: Data,_ at: Int) -> Int {
        data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at,as: UInt32.self))) }
    }
    private func open<T>(_ data: Data,_ body: (PagedV4Core) throws -> T) throws -> T {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let identity = PagedV4Core.Identity(sha256: SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined(),bytes: data.count)
        let reader = try PagedV4Core(url: url,identity: identity); defer { reader.close() }
        return try body(reader)
    }
    @Test func preservesCompleteRestrictionRecordAndOpaquePolicyBytes() throws {
        var data = try bytes()
        let first = u32(data,120)+4
        // Preserve raw fields that the narrower GraphV2Pack projection discards.
        data[first+9] |= 0x80
        data[first+24] = 0x34; data[first+25] = 0x12
        data[first+28] = 7; data[first+29] = 0; data[first+30] = 0; data[first+31] = 0
        try open(data) { reader in
            try reader.withLegalQuery { query in
                var rows = 0
                try query.forEachRestriction { index,row in
                    rows += 1
                    if index == 0 {
                        #expect(row.flags & 0x80 != 0 && row.exceptMask == 0x1234)
                        #expect(row.conditionalIndex == 7)
                        #expect(row.via.count == data.withUnsafeBytes { Int(UInt16.routingDecode($0,at: first+10)) })
                        for (i,member) in row.via.enumerated() {
                            #expect(member.osmWayID == data.withUnsafeBytes { Int64.routingDecode($0,at: first+32+i*12) })
                            #expect(member.edge == data.withUnsafeBytes { Int32.routingDecode($0,at: first+40+i*12) })
                        }
                    }
                }
                #expect(rows == u32(data,u32(data,120)))
                var barriers = 0
                try query.forEachBarrier { index,row in
                    barriers += 1; let at = u32(data,116)+4+index*16
                    #expect(row.osmNodeID == data.withUnsafeBytes { Int64.routingDecode($0,at: at) })
                    #expect(row.decision == data[at+12])
                }
                #expect(barriers == u32(data,u32(data,116)))
                for (section,start,end) in [
                    (PagedV4Core.LegalSection.conditionals,124,128),(.provenance,128,132),(.capabilities,132,136),
                    (.enums,56,60),(.metadata,60,72)] {
                    let range = u32(data,start)..<u32(data,end)
                    var actual = Data()
                    for offset in stride(from: 0,to: range.count,by: 17) {
                        let lease = try query.sectionChunk(section,offset: offset,count: min(17,range.count-offset))
                        lease.withUnsafeBytes { actual.append(contentsOf: $0) }
                    }
                    #expect(actual == data.subdata(in: range))
                }
            }
            #expect(reader.pageStatistics.peakLivePayloadBytes <= reader.pageStatistics.maximumLivePayloadBytes)
        }
    }
    @Test func invalidRestrictionLengthIsDataFailureAndQueryCannotEscape() throws {
        var data = try bytes(); let first = u32(data,120)+4
        data[first+10] = 255; data[first+11] = 255
        try open(data) { reader in
            #expect(throws: PagedV4Core.Failure.invalidLegalMetadata) {
                try reader.withLegalQuery { try $0.forEachRestriction { _,_ in } }
            }
        }
        try open(bytes()) { reader in
            var escaped: PagedV4Core.LegalQuery?
            try reader.withLegalQuery { escaped = $0 }
            #expect(throws: PagedV4Core.Failure.queryClosed) { try escaped!.sectionLength(.conditionals) }
            #expect(throws: RoutingPageError.cancelled) {
                try reader.withLegalQuery(cancelled: { true }) { try $0.forEachBarrier { _,_ in } }
            }
        }
    }
}
