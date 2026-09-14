import CryptoKit
import Foundation
import Testing
@testable import Dirt

struct PagedPolicyMetadataValidationTests {
    private func original() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/native-preferences-variety.graph.v4.bin"))
    }
    private func read(_ data: Data,_ at: Int) -> Int { data.withUnsafeBytes { Int(UInt32.routingDecode($0,at: at)) } }
    private func put(_ data: inout Data,_ at: Int,_ value: Int) {
        var value = UInt32(value).littleEndian
        Swift.withUnsafeBytes(of: &value) { data.replaceSubrange(at..<at+4,with: $0) }
    }
    private func enums(_ data: Data,_ change: (inout [String: Any]) -> Void) throws -> Data {
        let start = read(data,56), end = read(data,60)
        var object = try #require(try JSONSerialization.jsonObject(with: data.subdata(in: start..<end)) as? [String: Any])
        change(&object)
        let bytes = try JSONSerialization.data(withJSONObject: object,options: [.sortedKeys])
        let delta = bytes.count-(end-start)
        var output = data; output.replaceSubrange(start..<end,with: bytes)
        for at in stride(from: 24,through: 136,by: 4) {
            let old = read(data,at)
            if old >= end { put(&output,at,old+delta) }
        }
        return output
    }
    private func use<T>(_ bytes: Data,_ body: (PagedV4Core,PagedEdgeDetail) throws -> T) throws -> T {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x",$0) }.joined()
        let core = try PagedV4Core(url: url,identity: .init(sha256: hash,bytes: bytes.count)); defer { core.close() }
        let detail = try PagedEdgeDetail(url: url,identity: .init(sha256: hash,bytes: bytes.count,edgeCount: core.edgeCount))
        return try body(core,detail)
    }
    @Test func nonzeroOutOfDictionaryCodesAreDataErrorsButZeroIsUnknown() throws {
        for field in [72,76] {
            var bytes = try original(); bytes[read(bytes,field)] = 255
            try use(bytes) { core,detail in
                let metadata = try PagedCleanPolicyReadAccess.Metadata(core: core)
                try detail.withQuery { query in
                    let access = try PagedCleanPolicyReadAccess(metadata: metadata,details: detail,query: query)
                    #expect(throws: PagedCleanPolicyReadAccess.Failure.invalidMetadata) {
                        if field == 72 { _ = try access.surfaceFamily(0) } else { _ = try access.roadTier(0) }
                    }
                }
            }
        }
        var bytes = try original(); bytes[read(bytes,72)] = 0; bytes[read(bytes,76)] = 0
        try use(bytes) { core,detail in
            let metadata = try PagedCleanPolicyReadAccess.Metadata(core: core)
            try detail.withQuery { query in
                let access = try PagedCleanPolicyReadAccess(metadata: metadata,details: detail,query: query)
                #expect(try access.surfaceFamily(0) == .unknown)
                #expect(try access.roadTier(0) == .unknown)
            }
        }
    }
    @Test func dictionarySchemaIsBoundedAndTyped() throws {
        let base = try original()
        let variants = [
            try enums(base) { $0["roadClassLeafNames"] = Array(repeating: "unknown",count: 257) },
            try enums(base) { $0["surfaceLeafNames"] = [] as [String] },
            try enums(base) { $0["surfaceFamilyMap"] = ["asphalt": 123] },
            try enums(base) { $0["roadTierMap"] = ["unclassified": "unrecognized"] }
        ]
        for bytes in variants {
            try use(bytes) { core,_ in
                #expect(throws: PagedCleanPolicyReadAccess.Failure.invalidMetadata) { try PagedCleanPolicyReadAccess.Metadata(core: core) }
            }
        }
    }
    @Test func metadataCancellationAndWrongQueryOwnerAreRejected() throws {
        try use(original()) { core,detail in
            #expect(throws: RoutingPageError.cancelled) { try PagedCleanPolicyReadAccess.Metadata(core: core,cancelled: { true }) }
            let metadata = try PagedCleanPolicyReadAccess.Metadata(core: core)
            try use(original()) { _,other in
                try other.withQuery { query in
                    #expect(throws: PagedCleanPolicyReadAccess.Failure.identityMismatch) {
                        try PagedCleanPolicyReadAccess(metadata: metadata,details: detail,query: query)
                    }
                }
            }
        }
    }
}
