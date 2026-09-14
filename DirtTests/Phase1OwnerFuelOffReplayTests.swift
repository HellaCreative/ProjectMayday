import CoreLocation
import Foundation
import Testing
@testable import Dirt

/// Fuel-off owner replay against immutable `fabric-v4-20260909-02`.
/// Records riding character; does not freeze routing or start fuel work.
@MainActor
@Suite(.serialized)
struct Phase1OwnerFuelOffReplayTests {
    private let release = "fabric-v4-20260909-02"
    private let packRoot = URL(
        fileURLWithPath: "/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/scripts/pack-fabric/routing/candidates/fabric-v4-20260909-02/packs",
        isDirectory: true
    )

    @Test func portersLakeToStStephenDirtFuelOff() async throws {
        let origin = CLLocationCoordinate2D(latitude: 44.764804567541226, longitude: -63.34024797349485)
        let destination = CLLocationCoordinate2D(latitude: 45.262939746458734, longitude: -67.29131337653283)
        try installPacks(["ns", "nb"])
        let store = GraphPackStore()
        #expect(store.isInstalled("ns"))
        #expect(store.isInstalled("nb"))

        let started = CFAbsoluteTimeGetCurrent()
        let result = await store.routeOnDeviceDetailed(
            from: origin,
            to: destination,
            profile: .dirt,
            allowUnknown: false,
            sessionSeed: 3_806_057_305_948_982,
            mapZoom: 12.5
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        let payload: [String: Any]
        switch result {
        case .success(let route):
            payload = [
                "status": "success",
                "elapsedSeconds": elapsed,
                "distanceMeters": route.distanceMeters,
                "dirtPercent": route.dirtPercent,
                "pavedPercent": route.pavedPercent,
                "unknownSurfacePercent": route.unknownSurfacePercent,
                "reportedDirtPercent": route.reportedDirtPercent,
                "coordinateCount": route.coordinates.count,
                "legCount": route.legs.count,
                "debugNote": route.debugNote,
                "searchMeta": [
                    "pops": route.searchMeta.pops,
                    "timedOut": route.searchMeta.timedOut,
                    "pass2Outcome": route.searchMeta.pass2Outcome,
                    "elapsedMs": route.searchMeta.elapsedMs,
                    "corridorMeters": route.searchMeta.corridorMeters as Any? ?? NSNull(),
                    "maxCrossTrackMeters": route.searchMeta.maxCrossTrackMeters as Any? ?? NSNull(),
                    "fogChargedLabelBytes": route.searchMeta.fogChargedLabelBytes,
                    "fogNeighborhoodSeeds": route.searchMeta.fogNeighborhoodSeeds,
                    "fogNeighborhoodExpansions": route.searchMeta.fogNeighborhoodExpansions,
                    "rideObjective": route.searchMeta.rideObjective as Any? ?? NSNull()
                ] as [String: Any],
                "packRelease": release,
                "seed": 3_806_057_305_948_982,
                "profile": "dirt",
                "fuel": "off"
            ]
            #expect(route.coordinates.count > 1)
            #expect(route.distanceMeters > 100_000)
        case .failure(let failure):
            payload = [
                "status": "failure",
                "elapsedSeconds": elapsed,
                "failure": String(describing: failure),
                "packRelease": release,
                "seed": 3_806_057_305_948_982,
                "profile": "dirt",
                "fuel": "off"
            ]
            Issue.record("Porters Lake→St Stephen Dirt fuel-off failed: \(failure) after \(elapsed)s")
        }
        try writeEvidence(payload, name: "porters-lake-st-stephen-dirt")
    }

    private func installPacks(_ regions: [String]) throws {
        let fm = FileManager.default
        let support = try #require(
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let cache = support.appendingPathComponent("dirt-graph-packs", isDirectory: true)
        for region in regions {
            let source = packRoot.appendingPathComponent(region)
            let dest = cache.appendingPathComponent(release).appendingPathComponent(region)
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for name in [
                "graph.v4.bin", "geometry.v1.bin", "fuel.v1.json",
                "cross-pack-seams.v2.json", "pack-manifest.v2.json"
            ] {
                let from = source.appendingPathComponent(name)
                let to = dest.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                try fm.copyItem(at: from, to: to)
            }
        }
    }

    private func writeEvidence(_ value: [String: Any], name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        let tmp = URL(fileURLWithPath: "/tmp/Dirt-Phase1-Owner-FuelOff-20260914-\(name).json")
        try data.write(to: tmp)
        let repo = URL(fileURLWithPath: "/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/.build/recovery-evidence/phase1-routing-fuel-off")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try data.write(to: repo.appendingPathComponent("\(name).json"))
    }
}
