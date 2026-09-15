import Foundation
import Testing
import DirtRoutingEngine
@testable import Dirt

/// Opt-in replay of immutable local packs. Never installs into the rider's cache.
/// Set DIRT_OWNER_REPLAY_PACK_ROOT to a directory containing ns/ and nb/ manifests.
@Suite(.serialized)
struct Phase1OwnerFuelOffReplayTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRT_OWNER_REPLAY_PACK_ROOT"] != nil))
    func portersLakeToStStephenDirtFuelOff() throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DIRT_OWNER_REPLAY_PACK_ROOT"]), isDirectory: true)
        let started = ContinuousClock.now
        let budget = ComputationBudget(seconds: 60)
        let repository = try PackRepository(installedDirectories: ["ns": root.appendingPathComponent("ns"), "nb": root.appendingPathComponent("nb")])
        let packs = try ["ns", "nb"].map { try repository.open($0, requireSeams: true, budget: budget) }
        for pack in packs { #expect(pack.manifest.fabricReleaseId == "fabric-v4-20260909-02") }
        let graph = try IndexedGraph(RegionalGraph(packs: packs, budget: budget), budget: budget)
        var request = RoutingRequest(
            start: .init(longitude: -63.34024797349485, latitude: 44.764804567541226),
            end: .init(longitude: -67.29131337653283, latitude: 45.262939746458734),
            style: .dirt, allowUnknown: false, seed: 3_806_057_305_948_982
        )
        request.mapZoom = 12.5
        do {
            let route = try RoutingEngine(pack: graph).route(request, budget: budget)
            let quality = RouteQuality(route: route, urbanBoxes: graph.urbanCores)
            let duration = started.duration(to: .now).components
            let payload: [String: Any] = [
                "status": "road-complete",
                "elapsedSeconds": Double(duration.seconds) + Double(duration.attoseconds) / 1e18,
                "distanceMeters": route.distanceMeters,
                "knownDirtPercent": quality.knownDirtPercent,
                "unknownSurfacePercent": quality.unknownPercent,
                "coordinateCount": route.geometry.count,
                "pops": route.poppedLabels,
                "limit": route.limit as Any? ?? NSNull(),
                "geometry": route.geometry.map { [$0.longitude, $0.latitude] },
                "edgeIDs": route.segments.map(\.edgeID),
                "packIdentities": packs.map { ["region": $0.manifest.regionId, "graph": $0.graph.graphSHA256, "geometry": $0.graph.geometrySHA256] },
                "seed": request.options.seed,
                "mapZoom": 12.5,
                "profile": "dirt", "allowUnknown": false, "fuel": "off"
            ]
            try writeEvidence(payload)
            #expect(route.geometry.count > 1)
            #expect(route.distanceMeters > 100_000)
            #expect(route.start.coordinate.distance(to: request.start) <= 600)
            #expect(route.end.coordinate.distance(to: request.end) <= 600)
            // A low-dirt route is evidence, not successful owner qualification.
            #expect(quality.knownDirtPercent >= 70, "Owner Dirt qualification requires substantial connected known dirt")
            #expect(route.limit == nil, "An incomplete comparison is not a qualified replay")
        } catch {
            try writeEvidence(["status": "failure", "failure": String(describing: error), "seed": request.options.seed])
            throw error
        }
    }

    private func writeEvidence(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let path = ProcessInfo.processInfo.environment["DIRT_OWNER_REPLAY_OUTPUT"]
        let output = path.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Dirt-greenfield-owner-replay.json")
        try data.write(to: output, options: .atomic)
    }
}
