import Foundation
import Testing
@testable import Dirt

/// Phase E1: honest Dirt% from surfaceLeaf must match the JS surface-family lockstep fixture.
struct GraphV3DirtPercentLockstepTests {
    private func fixtureURL(_ name: String) throws -> URL {
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: src.path) { return src }
        let bundle = Bundle(for: DirtPercentBundleToken.self)
        if let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") {
            return url
        }
        Issue.record("missing fixture \(name)")
        throw GraphV2Pack.PackError.truncated
    }

    private func nsV3PackURL() throws -> URL {
        // Prefer repo region pack (device/sim tests run from source tree).
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/pack-fabric/routing/data/regions/ns/graph.v3.bin")
        if FileManager.default.fileExists(atPath: repo.path) { return repo }
        let seed = try fixtureURL("DirtLocalPacks/ns/graph.v3.bin")
        return seed
    }

    @Test func honestDirtPercentMatchesJsLockstep() throws {
        let pack = try GraphV2Pack(data: Data(contentsOf: try nsV3PackURL()))
        #expect(pack.version == 3)
        #expect(pack.hasLeaves)

        let fixtureData = try Data(contentsOf: try fixtureURL("ns-graph.v3.dirt-percent.lockstep.json"))
        guard let fixture = try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any],
              let routes = fixture["routes"] as? [[String: Any]] else {
            Issue.record("fixture routes missing")
            return
        }
        #expect(pack.undirectedEdgeCount == (fixture["undirectedEdgeCount"] as? Int ?? -1))

        for route in routes {
            let id = route["id"] as? String ?? "?"
            guard let indexes = route["edgeIndexes"] as? [Int] else {
                Issue.record("missing edgeIndexes for \(id)")
                continue
            }
            let rows: [(meters: Double, surfaceLeaf: String?)] = indexes.map { ei in
                (Double(pack.edgeMeters[ei]), pack.surfaceLeaf(ei))
            }
            let got = SurfaceFamilyStats.honestPercents(
                rows: rows,
                distanceMeters: rows.reduce(0) { $0 + $1.meters }
            )
            let expDirt = route["dirtPercent"] as? Int ?? -1
            let expPaved = route["pavedPercent"] as? Int ?? -1
            let expUnknown = route["unknownSurfacePercent"] as? Int ?? -1
            #expect(got.dirtPercent == expDirt, "dirtPercent route=\(id)")
            #expect(got.pavedPercent == expPaved, "pavedPercent route=\(id)")
            #expect(got.unknownSurfacePercent == expUnknown, "unknownSurfacePercent route=\(id)")
            if let expGravel = route["gravelPercent"] as? Int {
                #expect(got.gravelPercent == expGravel, "gravelPercent route=\(id)")
            }
        }
    }

    @Test func v2PackKeepsCoarseDirtPercentWithoutLeaves() throws {
        let v2 = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/pack-fabric/routing/data/regions/ns/graph.v2.bin")
        guard FileManager.default.fileExists(atPath: v2.path) else { return }
        let pack = try GraphV2Pack(data: Data(contentsOf: v2))
        #expect(pack.version == 2)
        #expect(!pack.hasLeaves)
        #expect(pack.surfaceLeaf(0) == nil)
        let rows: [(meters: Double, surfaceLeaf: String?)] = [(1000, nil)]
        // Without leaves, callers must use coarse adventure stats — honest helper
        // treats nil leaf as Unknown (dirt). Confirm family map still loads empty→default.
        #expect(SurfaceFamilyStats.family(of: nil) == .unknown)
        #expect(SurfaceFamilyStats.family(of: "gravel") == .gravel)
        #expect(SurfaceFamilyStats.family(of: "unpaved") == .gravel)
        #expect(SurfaceFamilyStats.family(of: "dirt") == .loose)
        #expect(SurfaceFamilyStats.family(of: "asphalt;gravel") == .unknown)
        _ = rows
        _ = pack
    }
}

private final class DirtPercentBundleToken: NSObject {}
