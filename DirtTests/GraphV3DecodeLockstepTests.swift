import Foundation
import Testing
@testable import Dirt

/// Phase D: Swift Graph-v3 leaf decode must match the JS decoder golden fixture.
struct GraphV3DecodeLockstepTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let bundle = Bundle(for: BundleToken.self)
        if let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") {
            return url
        }
        if let url = bundle.url(forResource: (name as NSString).deletingPathExtension,
                                withExtension: (name as NSString).pathExtension,
                                subdirectory: "Fixtures") {
            return url
        }
        // File-system-synced test targets often expose resources next to the test source.
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: src.path) {
            return src
        }
        Issue.record("missing fixture \(name)")
        throw GraphV2Pack.PackError.truncated
    }

    @Test func swiftV3LeavesMatchJsLockstepFixture() throws {
        let binURL = try fixtureURL("ns-graph.v3.candidate.bin")
        let jsonURL = try fixtureURL("ns-graph.v3.lockstep.json")
        let data = try Data(contentsOf: binURL)
        let pack = try GraphV2Pack(data: data)

        #expect(pack.version == 3)
        #expect(pack.hasLeaves)
        #expect((pack.flags & GraphV2Pack.flagV3Leaves) != 0)

        let fixtureData = try Data(contentsOf: jsonURL)
        let fixture = try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
        guard let fixture else {
            Issue.record("fixture JSON root missing")
            return
        }
        let expectedEdges = fixture["undirectedEdgeCount"] as? Int ?? -1
        #expect(pack.undirectedEdgeCount == expectedEdges)

        let atvKm = fixture["atvDesignatedKm"] as? Double ?? 0
        #expect(atvKm > 350.0 && atvKm < 360.0)

        var atvMeters: UInt64 = 0
        for ei in 0..<pack.undirectedEdgeCount where pack.atvDesignated(ei) {
            atvMeters += UInt64(pack.edgeMeters[ei])
        }
        let swiftAtvKm = Double(atvMeters) / 1000.0
        #expect(abs(swiftAtvKm - atvKm) < 0.05)

        guard let samples = fixture["samples"] as? [[String: Any]] else {
            Issue.record("fixture samples missing")
            return
        }
        #expect(samples.count > 100)

        for sample in samples {
            let ei = sample["edgeIndex"] as? Int ?? -1
            #expect(ei >= 0 && ei < pack.undirectedEdgeCount)

            let expSurface = sample["surfaceLeaf"] as? String
            let gotSurface = pack.surfaceLeaf(ei)
            #expect(gotSurface == expSurface, "surfaceLeaf ei=\(ei)")

            let expRoad = sample["roadClassLeaf"] as? String ?? "unknown"
            let gotRoad = pack.roadClassLeaf(ei) ?? "unknown"
            #expect(gotRoad == expRoad, "roadClassLeaf ei=\(ei)")

            let expTt = sample["tracktype"] as? Int ?? 0
            #expect(pack.tracktype(ei) == expTt, "tracktype ei=\(ei)")

            let expSm = sample["smoothness"] as? Int ?? 0
            #expect(pack.smoothness(ei) == expSm, "smoothness ei=\(ei)")

            let expLayer = sample["layer"] as? Int ?? 0
            #expect(pack.layer(ei) == expLayer, "layer ei=\(ei)")

            let expStruct = sample["structureLeaf"] as? String
            #expect(pack.structureLeaf(ei) == expStruct, "structureLeaf ei=\(ei)")

            let expAccess = sample["accessLeaf"] as? String
            #expect(pack.accessLeaf(ei) == expAccess, "accessLeaf ei=\(ei)")

            let expAtv = sample["atvDesignated"] as? Bool ?? false
            #expect(pack.atvDesignated(ei) == expAtv, "atvDesignated ei=\(ei)")
        }
    }

    @Test func shippedV2PackStillLoadsWithoutLeaves() throws {
        let shipped = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DirtTests
            .deletingLastPathComponent() // Dirt/
            .appendingPathComponent("scripts/pack-fabric/routing/data/regions/ns/graph.v2.bin")
        // Prefer fixture-adjacent path from repo root when running under xcodebuild.
        let candidates = [
            shipped,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("scripts/pack-fabric/routing/data/regions/ns/graph.v2.bin")
        ]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            // Allow skip when the local pack tree is absent (still covered by JS gate).
            return
        }
        let pack = try GraphV2Pack(data: Data(contentsOf: url))
        #expect(pack.version == 2)
        #expect(!pack.hasLeaves)
        #expect(pack.undirectedEdgeCount > 100_000)
        let leaf = pack.edgeLeaves(0)
        #expect(!leaf.fromLeaves)
        #expect(leaf.surfaceLeaf == nil)
        #expect(leaf.atvDesignated == false)
        #expect(pack.tracktype(0) == 0)
    }
}

private final class BundleToken: NSObject {}
