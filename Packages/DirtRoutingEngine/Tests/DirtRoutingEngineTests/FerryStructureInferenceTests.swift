import Foundation
import Testing
@testable import DirtRoutingEngine

/// Published fabric-v4 packs time ferry edges but omit structureLeaf "ferry".
/// GraphPack.structure() must still surface "ferry" so map dash paint and
/// itinerary ferry chrome fire without a pack rebuild.
struct FerryStructureInferenceTests {
    private var nsPackURL: URL? {
        let candidates = [
            "/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/scripts/pack-fabric/routing/candidates/fabric-v4-20260909-02/packs/ns",
            "/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt-multi-province-hops-fd40/scripts/pack-fabric/routing/candidates/fabric-v4-20260909-02/packs/ns"
        ]
        return candidates
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .first {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("graph.v4.bin").path)
            }
    }

    @Test func timedCrossingWithEmptyLeafReadsAsFerry() throws {
        guard let root = nsPackURL else { return }
        let pack = try GraphPack(
            graphURL: root.appendingPathComponent("graph.v4.bin"),
            geometryURL: root.appendingPathComponent("geometry.v1.bin"),
            budget: .init(seconds: 30)
        )
        var timed = 0
        var inferred = 0
        for edge in 0..<pack.edgeCount {
            guard pack.crossingTime(edge) > 0 else { continue }
            timed += 1
            #expect(pack.structure(edge) == "ferry")
            inferred += 1
        }
        #expect(timed > 0)
        #expect(inferred == timed)
        // Marine Atlantic North Sydney ↔ Port aux Basques (OSM way 119443515)
        var marineAtlantic = false
        for edge in 0..<pack.edgeCount where pack.osmWayID(edge) == 119_443_515 {
            #expect(pack.crossingTime(edge) >= 20_000)
            #expect(pack.structure(edge) == "ferry")
            marineAtlantic = true
        }
        #expect(marineAtlantic)
    }
}
