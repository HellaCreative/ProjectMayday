import CryptoKit
import Foundation
import Testing
@testable import Dirt

@Suite struct VerifiedSeamConsumptionTests {
    @Test func sameSizePortalRemovalAfterPathPreflightCannotEnterProof() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("seam-snapshot-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let valid = Data("{\"schemaVersion\":\"dirt-cross-pack-seams.v2\",\"regionId\":\"ns\",\"sourceEpoch\":\"same\",\"neighbors\":{\"nb\":[{\"osmNodeId\":7,\"coordinate\":[-64,45],\"gapMeters\":0,\"osmWayId\":9,\"localEdgeId\":\"w9:a:b\",\"remoteEdgeId\":\"w9:a:b\"}]}}".utf8)
        var changed = Data("{\"schemaVersion\":\"dirt-cross-pack-seams.v2\",\"regionId\":\"ns\",\"sourceEpoch\":\"same\",\"neighbors\":{}}".utf8)
        changed.append(Data(repeating: 32, count: valid.count - changed.count))
        let hash = digest(valid)
        try valid.write(to: url, options: .atomic)
        #expect(GraphPackStore.fileMatchesIdentity(at: url, expectedBytes: valid.count, expectedSHA256: hash))
        // Models replacement across the activation await: size/schema/epoch
        // still match, but the portal required for a negative proof disappeared.
        try changed.write(to: url, options: .atomic)
        #expect(try GraphPackStore.verifiedSeamData(at: url,
            expectedBytes: valid.count, expectedSHA256: hash) == nil)
        try valid.write(to: url, options: .atomic)
        let snapshot = try #require(try GraphPackStore.verifiedSeamData(at: url,
            expectedBytes: valid.count, expectedSHA256: hash))
        try changed.write(to: url, options: .atomic)
        #expect(snapshot == valid)
        let decoded = try #require(try JSONSerialization.jsonObject(with: snapshot) as? [String: Any])
        let neighbors = try #require(decoded["neighbors"] as? [String: Any])
        #expect(neighbors["nb"] != nil)
    }

    @Test func wrongLengthMissingDataAndExpiredWindowNeverProduceValidatedBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("seam-validation-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("{}".utf8)
        #expect(try GraphPackStore.verifiedSeamData(at: url, expectedBytes: data.count,
            expectedSHA256: digest(data)) == nil)
        try data.write(to: url)
        #expect(try GraphPackStore.verifiedSeamData(at: url, expectedBytes: data.count + 1,
            expectedSHA256: digest(data)) == nil)
        #expect(throws: RoutingError.self) {
            try RoutingWorkContext.$deadline.withValue(0) {
                _ = try GraphPackStore.verifiedSeamData(at: url, expectedBytes: data.count,
                    expectedSHA256: digest(data))
            }
        }
    }
    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
