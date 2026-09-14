import CoreLocation
import CryptoKit
import Foundation
import Testing
@testable import Dirt

@MainActor
struct GraphPackStoreGeometryPairTests {
    private func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    @Test(arguments:[false,true])
    func actualInstalledLoaderRequiresGraphAndGeometryToBeAPair(mismatched: Bool) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("graph-pair-load-"+UUID().uuidString)
        defer { try? fm.removeItem(at:root) }
        // Match the version/region layout used by actual installed-pack discovery.
        let target = root.appendingPathComponent("v1/ns")
        try fm.createDirectory(at:target,withIntermediateDirectories:true)
        let fixture = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/native-long-fuel/ns")
        var manifest = try #require(JSONSerialization.jsonObject(with:Data(contentsOf:fixture.appendingPathComponent("native-long-ns-pack-manifest.v2.json"))) as? [String:Any])
        var graphData = Data(),geometryData = Data()
        for (key,name) in [("graph","graph.v4.bin"),("geometry","geometry.v1.bin"),("fuel","fuel.v1.json"),("seams","cross-pack-seams.v2.json")] {
            var entry = try #require(manifest[key] as? [String:Any])
            let fixtureName = try #require(entry["name"] as? String)
            var data = try Data(contentsOf:fixture.appendingPathComponent(fixtureName))
            if key == "geometry",mismatched {
                // One valid Float32 coordinate changes, retaining edge/point
                // counts. Both files remain separately valid and manifest-hashed.
                let edgeCount = data.withUnsafeBytes { Int(UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:8,as:UInt32.self))) }
                let firstCoordinate = 16+(edgeCount+1)*4
                data[firstCoordinate] ^= 1
            }
            if key == "graph" { graphData = data }
            if key == "geometry" { geometryData = data }
            entry["name"] = name;entry["bytes"] = data.count;entry["sha256"] = hash(data);manifest[key] = entry
            try data.write(to:target.appendingPathComponent(name))
        }
        try JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys]).write(to:target.appendingPathComponent("pack-manifest.v2.json"))
        let independentGraph = try GraphV2Pack(data:graphData)
        _ = try GeometryV1Pack(data:geometryData)
        #expect((independentGraph.pairedGeometrySHA256 == hash(geometryData)) == !mismatched)
        let store = GraphPackStore(cacheRoot:root,refreshCatalogOnInit:false)
        #expect(store.isInstalled("ns"))
        // Exercise actual asynchronous activation → manifest validation → exact
        // index preparation → decodePack. No helper-only pairing assertion.
        await store.warmupActivePack(near:.init(latitude:44.764805,longitude:-63.340248))
        if mismatched {
            #expect(store.activePack == nil && !store.canRouteOnDevice)
            // The synchronous installed-pack path must not bypass the pairing
            // guard merely because it has no catalog/explicit identity argument.
            #expect(store.packIfInstalled("ns") == nil)
        } else {
            let active = try #require(store.activePack)
            #expect(active.regionId == "ns" && active.geometry != nil)
            #expect(active.pairedGeometrySHA256 == hash(geometryData))
            #expect(store.canRouteOnDevice)
        }
    }
}
