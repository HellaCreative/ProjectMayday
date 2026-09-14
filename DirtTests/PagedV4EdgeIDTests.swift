import Foundation
import CryptoKit
import Testing
@testable import Dirt

struct PagedV4EdgeIDTests {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/"+name))
    }
    private func u32(_ data: Data,_ at: Int) -> Int {
        data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at,as: UInt32.self))) }
    }
    private func put(_ value: UInt32,_ at: Int,_ data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.replaceSubrange(at..<at+4,with: $0) }
    }
    private func withCore(_ data: Data,_ body: (PagedV4Core,URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paged-edge-id-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("graph.bin");try data.write(to: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined()
        let core = try PagedV4Core(url: url,identity: .init(sha256: hash,bytes: data.count))
        try body(core,url)
    }
    @Test(arguments: ["legal-topology-restrictions.graph.v4.bin","yarmouth-harbour.graph.v4.bin"])
    func bothFormatsMatchNativeWithoutRetainingBlob(_ name: String) throws {
        let data = try fixture(name),pack = try GraphV2Pack(data: data)
        try withCore(data) { core,_ in
            var escaped: PagedV4Core.Query?
            try core.withQuery { query in
                escaped = query
                for edge in 0..<core.edgeCount {
                    let actual = try query.edgeID(edge)
                    #expect(actual == pack.edgeId(edge))
                }
                _ = #expect(throws: PagedV4Core.Failure.metadataLimit) { try query.edgeID(0,maximumBytes: 1) }
                _ = #expect(throws: PagedV4Core.Failure.invalidRow) { try query.edgeID(core.edgeCount) }
            }
            let closed = try #require(escaped)
            _ = #expect(throws: PagedV4Core.Failure.queryClosed) { try closed.edgeID(0) }
            var cancelled = false
            try core.withQuery(cancelled: { cancelled }) { query in
                cancelled = true
                _ = #expect(throws: RoutingPageError.cancelled) { try query.edgeID(0) }
                cancelled = false
            }
        }
    }
    @Test func explicitInvalidOffsetsAndUTF8FailInsteadOfReturningUnknownID() throws {
        let data = try fixture("yarmouth-harbour.graph.v4.bin")
        let offsets = u32(data,48),blob = u32(data,52)
        for mutation in 0..<3 {
            var changed = data
            if mutation == 0 { put(UInt32.max,offsets,&changed) }
            if mutation == 1 { put(UInt32(u32(data,56)-blob+1),offsets+4,&changed) }
            if mutation == 2 { changed[blob] = 0xff }
            try withCore(changed) { core,_ in
                try core.withQuery { query in
                    _ = #expect(throws: PagedV4Core.Failure.invalidRow) { try query.edgeID(0) }
                }
            }
        }
    }
    @Test func oversizedExplicitIDIsBoundedBeforeReadingAndSourceChangeFails() throws {
        var data = try fixture("yarmouth-harbour.graph.v4.bin")
        // Grow only the last explicit ID by inserting bytes before the enums;
        // relocate all following recorded sections, preserving topology bytes.
        let offsets = u32(data,48),blob = u32(data,52),enums = u32(data,56),edges = u32(data,12)
        let growth = 65_537
        data.insert(contentsOf: repeatElement(UInt8(97),count: growth),at: enums)
        put(UInt32(enums-blob+growth),offsets+edges*4,&data)
        for at in stride(from: 56,through: 136,by: 4) {
            let value = u32(data,at)
            if value >= enums { put(UInt32(value+growth),at,&data) }
        }
        try withCore(data) { core,url in
            try core.withQuery { query in
                _ = #expect(throws: PagedV4Core.Failure.metadataLimit) { try query.edgeID(edges-1) }
            }
            _ = #expect(throws: (any Error).self) {
                try core.withQuery { query in
                    _ = try query.edgeID(0)
                    var changed = data;changed[blob] ^= 1;try changed.write(to: url)
                    _ = try query.edgeID(0)
                }
            }
        }
    }
}
