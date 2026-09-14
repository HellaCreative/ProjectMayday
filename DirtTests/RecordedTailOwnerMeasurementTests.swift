import CoreLocation
import CryptoKit
import Foundation
import Testing
@testable import Dirt

@Suite(.serialized)
struct RecordedTailOwnerMeasurementTests {
    private func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Measurement only. The full builder replay must independently qualify the
    /// legal continuation, real fuel distance, final destination and ride style.
    @MainActor @Test func currentNBPumpRecordedNodeTailBound() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DIRT_CURRENT_PACK_ROOT"]
            ?? "/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/scripts/pack-fabric/routing/candidates/fabric-v4-20260909-02/packs")
        let fm = FileManager.default, release = "fabric-v4-20260909-02"
        let temp = fm.temporaryDirectory.appendingPathComponent("recorded-tail-"+UUID().uuidString)
        defer { try? fm.removeItem(at: temp) }
        var snapshots: [[String: [GraphV2Pack.CrossPackSeamAnchor]]] = [], seamData: [Data] = []
        for region in ["ns","nb"] {
            let source = root.appendingPathComponent(region), target = temp.appendingPathComponent(release+"/"+region)
            let manifestData = try Data(contentsOf: source.appendingPathComponent("pack-manifest.v2.json"))
            let manifest = try #require(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
            try #require(manifest["fabricReleaseId"] as? String == release && manifest["regionId"] as? String == region)
            try fm.createDirectory(at: target,withIntermediateDirectories: true)
            for key in ["graph","geometry","fuel","seams"] {
                let entry = try #require(manifest[key] as? [String:Any]), name = try #require(entry["name"] as? String)
                try #require(!name.contains("/") && name != "..")
                let original = source.appendingPathComponent(name)
                try #require(try original.resourceValues(forKeys: [.fileSizeKey]).fileSize == entry["bytes"] as? Int)
                try #require(try digest(original) == entry["sha256"] as? String)
                let copy = target.appendingPathComponent(name); try fm.copyItem(at: original,to: copy)
                try #require(try digest(copy) == entry["sha256"] as? String)
                if key == "seams" { seamData.append(try Data(contentsOf: copy)) }
            }
            try manifestData.write(to: target.appendingPathComponent("pack-manifest.v2.json"))
        }
        let store = GraphPackStore(cacheRoot: temp,refreshCatalogOnInit: false)
        var packs: [GraphV2Pack] = []
        let origins = [CLLocationCoordinate2D(latitude: 44.764919,longitude: -63.340350),
                       CLLocationCoordinate2D(latitude: 46.0878,longitude: -64.7782)]
        let measurement = RoutingMeasurement(metadata: ["case":"node1626239164-to-w548556836", "release":release])
        let bounds = try await RoutingWorkContext.$measurement.withValue(measurement) {
            for index in origins.indices {
                await store.warmupActivePack(near: origins[index])
                let pack = try #require(store.activePack)
                try #require(pack.regionId == ["ns","nb"][index])
                packs.append(pack); snapshots.append(try pack.decodedCrossPackSeams(data: seamData[index]))
            }
            let preparedPacks = packs, preparedSeams = snapshots
            return try await RoutingWorkContext.detachedThrowingSearch {
                try OnDeviceRouter.recordedTailLowerBounds(packs: preparedPacks, seamSnapshots: preparedSeams,
                    destination: .init(latitude: 45.870167,longitude: -64.279432),mapZoom: 7.9,matchLimitMeters: nil)
            }
        }
        let bound = try #require(bounds["nb"]?[1626239164])
        #expect(bound.isFinite && bound >= 0)
        let record = measurement.finish(outcome: "tail-bound-measured")
        print("[recorded-tail] node=1626239164 destination=45.870167,-64.279432 boundM=\(bound) priorRemainingM=16.051999999996 status=measurement-only")
        let artifact = fm.temporaryDirectory.appendingPathComponent("recorded-tail-node1626239164.json")
        try JSONEncoder().encode(record).write(to: artifact)
        print("[recorded-tail] measurement=\(artifact.path)")
    }
}
