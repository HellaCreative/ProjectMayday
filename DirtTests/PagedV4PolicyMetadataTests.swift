import CryptoKit
import Foundation
import Testing
@testable import Dirt

struct PagedV4PolicyMetadataTests {
    private func bytes(_ name: String = "native-preferences-city") throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/"+name+".graph.v4.bin"))
    }
    private func read(_ data: Data,_ at: Int) -> Int { data.withUnsafeBytes { Int(UInt32.routingDecode($0,at: at)) } }
    private func put(_ data: inout Data,_ at: Int,_ value: Int) {
        var value = UInt32(value).littleEndian
        Swift.withUnsafeBytes(of: &value) { data.replaceSubrange(at..<at+4,with: $0) }
    }
    private func replacingMetadata(_ data: Data,with replacement: Data) -> Data {
        let start = read(data,60),end = read(data,72),delta = replacement.count-(end-start)
        var result = data; result.replaceSubrange(start..<end,with: replacement)
        for at in stride(from: 24,through: 136,by: 4) {
            let old = read(data,at); if old >= end { put(&result,at,old+delta) }
        }
        return result
    }
    private func use<T>(_ data: Data,_ body: (PagedV4Core,URL) throws -> T) throws -> T {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let identity = PagedV4Core.Identity(sha256: SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined(),bytes: data.count)
        let core = try PagedV4Core(url: url,identity: identity); defer { core.close() }
        return try body(core,url)
    }
    private func equal(_ a: [UrbanCore.Box],_ b: [UrbanCore.Box]) {
        #expect(a.count == b.count)
        for (a,b) in zip(a,b) {
            #expect(a.minLat.bitPattern == b.minLat.bitPattern && a.maxLat.bitPattern == b.maxLat.bitPattern)
            #expect(a.minLon.bitPattern == b.minLon.bitPattern && a.maxLon.bitPattern == b.maxLon.bitPattern)
            #expect(a.name == b.name)
        }
    }
    @Test func nativeMetadataAndPreferenceResolversRemainExact() throws {
        for name in ["native-preferences-city","native-preferences-variety"] {
            let data = try bytes(name), reference = try GraphV2Pack(data: data)
            try use(data) { core,_ in
                let metadata = try PagedV4PolicyMetadata(core: core)
                #expect(metadata.regionID == reference.regionId)
                equal(metadata.urbanCores,reference.urbanCores); equal(metadata.settlements,reference.settlements)
                #expect(metadata.retainedPayloadBytes <= PagedV4PolicyMetadata.Limits().maximumRetainedPayloadBytes)
                for profile in [RouteProfile.cleanest,.dirt,.balanced] {
                    for initial in [false,true] { for avoid in [false,true] {
                        var preferences = RidePreferences(); preferences.avoidCities = avoid
                        let actual = metadata.resolved(profile: profile,preferences: preferences,initialFuelApproach: initial)
                        let disabled = !initial && !avoid
                        equal(actual.urbanCores,disabled ? [] : (reference.urbanCores.isEmpty ? UrbanCore.boxes : reference.urbanCores))
                        equal(actual.settlementWalls,disabled ? [] : reference.settlements)
                        equal(actual.scoredSettlements,disabled ? [] : UrbanCore.settlementBoxes(embedded: reference.settlements,regionId: reference.regionId,profile: profile))
                    } }
                }
            }
        }
    }
    @Test func absentOptionalFieldsRetainCompatibilityDefaults() throws {
        let data = replacingMetadata(try bytes(),with: Data("{\"province\":\"ns\"}".utf8))
        try use(data) { core,_ in
            let metadata = try PagedV4PolicyMetadata(core: core)
            #expect(metadata.regionID == "ns" && metadata.urbanCores.isEmpty && metadata.settlements.isEmpty)
            equal(metadata.resolved(profile: .cleanest,preferences: nil,initialFuelApproach: false).urbanCores,UrbanCore.boxes)
        }
    }
    @Test func malformedAvoidanceRowsAndResourceLimitsCannotBecomeEmptyMap() throws {
        let base = try bytes()
        for raw in ["{", "[]", "{\"urbanCores\":{}}", "{\"settlements\":[{\"name\":\"missing coordinates\"}]}",
                    "{\"urbanCores\":[{\"minLat\":2,\"maxLat\":1,\"minLon\":0,\"maxLon\":1}]}"] {
            try use(replacingMetadata(base,with: Data(raw.utf8))) { core,_ in
                #expect(throws: PagedV4PolicyMetadata.Failure.malformedMetadata) { try PagedV4PolicyMetadata(core: core) }
            }
        }
        try use(base) { core,_ in
            var limits = PagedV4PolicyMetadata.Limits(); limits.maximumInputBytes = 1
            #expect(throws: PagedV4PolicyMetadata.Failure.metadataLimit) { try PagedV4PolicyMetadata(core: core,limits: limits) }
            limits = .init(); limits.maximumBoxes = 0
            #expect(throws: PagedV4PolicyMetadata.Failure.metadataLimit) { try PagedV4PolicyMetadata(core: core,limits: limits) }
        }
    }
    @Test func cancellationAndSourceMutationInvalidateMetadata() throws {
        try use(bytes()) { core,url in
            #expect(throws: RoutingPageError.cancelled) { try PagedV4PolicyMetadata(core: core,cancelled: { true }) }
            let metadata = try PagedV4PolicyMetadata(core: core)
            let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
            try handle.truncate(atOffset: 140)
            #expect(throws: (any Error).self) { try metadata.validate(for: core) }
            #expect(throws: (any Error).self) { try PagedV4PolicyMetadata(core: core) }
        }
    }
}
