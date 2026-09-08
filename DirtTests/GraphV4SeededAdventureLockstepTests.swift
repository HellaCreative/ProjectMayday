import CoreLocation
import CryptoKit
import Foundation
import Testing
@testable import Dirt

@Suite("Sealed V4 seeded adventure lockstep", .serialized)
struct GraphV4SeededAdventureLockstepTests {
    private static let releaseID = "fabric-v4-20260907-01"

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func fixtureURL() -> URL {
        repositoryRoot()
            .appendingPathComponent("DirtTests/Fixtures/ns-graph.v4.seeded-adventure.lockstep.json")
    }

    private func packRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["DIRT_V4_TEST_PACK_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return repositoryRoot()
            .appendingPathComponent("scripts/pack-fabric/routing/candidates")
            .appendingPathComponent(Self.releaseID)
            .appendingPathComponent("packs/ns", isDirectory: true)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func doubles(_ value: Any?) -> [Double]? {
        (value as? [NSNumber])?.map(\.doubleValue)
    }

    @Test("nonzero route seed produces the identical legal V4 path in JS and Swift")
    func seededDirtPathMatchesJavaScript() throws {
        let fixtureData = try Data(contentsOf: fixtureURL())
        let fixture = try #require(
            JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
        )
        #expect(fixture["releaseId"] as? String == Self.releaseID)
        #expect(fixture["graphVersion"] as? Int == 4)
        #expect(fixture["legalTopologyCapability"] as? String == "legal-topology.v1")
        #expect(fixture["seamContract"] as? String == "dirt-cross-pack-seams.v2")

        let files = try #require(fixture["files"] as? [String: Any])
        let root = packRoot()
        func verifiedData(_ key: String) throws -> Data {
            let identity = try #require(files[key] as? [String: Any])
            let name = try #require(identity["name"] as? String)
            let expectedBytes = try #require(identity["bytes"] as? Int)
            let expectedSHA = try #require(identity["sha256"] as? String)
            let data = try Data(contentsOf: root.appendingPathComponent(name))
            #expect(data.count == expectedBytes, "\(name) byte identity")
            #expect(sha256(data) == expectedSHA, "\(name) checksum identity")
            return data
        }

        let graphData = try verifiedData("graph")
        let geometryData = try verifiedData("geometry")
        _ = try verifiedData("fuel")
        let seamData = try verifiedData("seams")
        let pack = try GraphV2Pack(data: graphData)
        pack.geometry = try GeometryV1Pack(data: geometryData)
        try pack.applyCrossPackSeams(data: seamData)
        #expect(pack.version == 4)
        #expect(pack.legalTopology)
        #expect(pack.capabilities.contains("legal-topology.v1"))
        #expect(pack.sourceEpoch == fixture["sourceEpoch"] as? String)
        #expect(pack.crossPackSeams.keys.sorted() == ["nb", "nl", "pe"])

        let route = try #require(fixture["route"] as? [String: Any])
        let routeSeed = try #require(route["routeSeed"] as? NSNumber).uint64Value
        #expect(routeSeed != 0)
        let from = try #require(doubles(route["from"]))
        let to = try #require(doubles(route["to"]))
        let startCoord = try #require(doubles(route["startCoord"]))
        let endCoord = try #require(doubles(route["endCoord"]))
        let expectedIDs = try #require(route["edgeIds"] as? [String])
        let startEdgeIndex = try #require(route["startEdgeIndex"] as? Int)
        let endEdgeIndex = try #require(route["endEdgeIndex"] as? Int)
        let startAlongM = try #require(route["startAlongM"] as? NSNumber).doubleValue
        let endAlongM = try #require(route["endAlongM"] as? NSNumber).doubleValue
        let router = OnDeviceRouter(pack: pack)
        let result = try #require(router.routeAdventureLockstep(
            from: CLLocationCoordinate2D(latitude: from[1], longitude: from[0]),
            to: CLLocationCoordinate2D(latitude: to[1], longitude: to[0]),
            startEdgeIndex: startEdgeIndex,
            endEdgeIndex: endEdgeIndex,
            startProjected: CLLocationCoordinate2D(
                latitude: startCoord[1], longitude: startCoord[0]
            ),
            endProjected: CLLocationCoordinate2D(
                latitude: endCoord[1], longitude: endCoord[0]
            ),
            startAlongM: startAlongM,
            endAlongM: endAlongM,
            profile: .dirt,
            routeSeed: routeSeed
        ))
        let actualIDs = result.edgeIds.filter {
            !$0.hasPrefix("soft-") && !$0.hasPrefix("perm-")
        }
        #expect(result.searchMeta.routeSeed == routeSeed)
        #expect(actualIDs == expectedIDs, "seeded V4 edge sequence drifted between JS and Swift")
    }
}
