import Foundation
import Testing
@testable import DirtRoutingEngine

struct StagedRouterTests {
    private var portersLake: Coordinate { .init(longitude: -63.34024797349485, latitude: 44.764804567541226) }
    private var gaspe: Coordinate { .init(longitude: -64.273363, latitude: 48.922934) }
    private var yarmouth: Coordinate { .init(longitude: -66.09856, latitude: 43.84097) }
    private var ontarioPin: Coordinate { .init(longitude: -80.533860, latitude: 44.253137) }

    @Test func threePackLongTripStagesAndTwoPackNeverDoes() {
        #expect(StagedRouter.shouldStage(regionCount: 3, start: portersLake, end: gaspe))
        #expect(!StagedRouter.shouldStage(regionCount: 2, start: portersLake, end: gaspe))
        #expect(!StagedRouter.shouldStage(regionCount: 3, start: portersLake, end: yarmouth))
        #expect(StagedRouter.overlappingWindows(["ns", "nb", "qc"]) == [["ns", "nb"], ["nb", "qc"]])
        #expect(StagedRouter.overlappingWindows(["ns", "nb", "qc", "on"]) == [["ns", "nb"], ["nb", "qc"], ["qc", "on"]])
        #expect(StagedRouter.overlappingWindows(["ns", "nb"]) == [["ns", "nb"]])
    }

    @Test func handoverPrefersKnownYesAccessOverNearerUnknownOnly() throws {
        let dest = ontarioPin
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirt-staged-handover-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let seamsJSON = """
        {
          "schemaVersion": "dirt-cross-pack-seams.v2",
          "fabricReleaseId": "fixture",
          "sourceEpoch": "fixture",
          "regionId": "REGION",
          "neighbors": {
            "OTHER": [
              {
                "coordinate": [-69.07672, 47.28765],
                "gapMeters": 0,
                "osmNodeId": "1",
                "osmWayId": "10",
                "proof": "shared-osm-node-way-edge-legal-topology.v1",
                "edge": {
                  "osmWayId": "10", "fromOsmNodeId": "1", "toOsmNodeId": "2",
                  "accessForward": 1, "accessReverse": 1, "layer": 0, "structureLeaf": null
                },
                "barrierDecision": 0
              },
              {
                "coordinate": [-68.99963, 47.31007],
                "gapMeters": 0,
                "osmNodeId": "3",
                "osmWayId": "20",
                "proof": "shared-osm-node-way-edge-legal-topology.v1",
                "edge": {
                  "osmWayId": "20", "fromOsmNodeId": "3", "toOsmNodeId": "4",
                  "accessForward": 0, "accessReverse": 0, "layer": 0, "structureLeaf": null
                },
                "barrierDecision": 0
              },
              {
                "coordinate": [-66.68244, 48.01371],
                "gapMeters": 0,
                "osmNodeId": "5",
                "osmWayId": "30",
                "proof": "shared-osm-node-way-edge-legal-topology.v1",
                "edge": {
                  "osmWayId": "30", "fromOsmNodeId": "5", "toOsmNodeId": "6",
                  "accessForward": 0, "accessReverse": 0, "layer": 0, "structureLeaf": null
                },
                "barrierDecision": 0
              }
            ]
          }
        }
        """
        for (id, other) in [("nb", "qc"), ("qc", "nb")] {
            let dir = root.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let body = seamsJSON
                .replacingOccurrences(of: "REGION", with: id)
                .replacingOccurrences(of: "OTHER", with: other)
            try Data(body.utf8).write(to: dir.appendingPathComponent("cross-pack-seams.v2.json"))
        }
        let repository = try PackRepository(installedDirectories: [
            "nb": root.appendingPathComponent("nb"),
            "qc": root.appendingPathComponent("qc")
        ])
        let ranked = try StagedRouter.handoverCandidates(from: "nb", into: "qc", toward: dest, repository: repository)
        #expect(ranked.count == 3)
        #expect(abs(ranked[0].longitude - (-68.99963)) < 1e-5)
        #expect(abs(ranked[0].latitude - 47.31007) < 1e-5)
        // Unknown-only seam is after every known-yes pin, even though it is nearest the dest.
        #expect(abs(ranked[2].longitude - (-69.07672)) < 1e-5)
        #expect(abs(ranked[2].latitude - 47.28765) < 1e-5)
    }

    @Test func compassCapDoesNotChangeAnUncappedTableOnATinyGraph() throws {
        let nodes = (0...4).map { Coordinate(longitude: Double($0) * 0.01, latitude: 0) }
        let graph = try IndexedGraph(PolicyTests.Line(nodes: nodes, edges: (0..<4).map { ($0, $0 + 1) },
            surfaces: Array(repeating: "asphalt", count: 4), roads: Array(repeating: "tertiary", count: 4)))
        let end = RoadMatch(edge: 3, coordinate: nodes[4], distanceMeters: 0, alongMeters: graph.distance(3),
                            geometryMeters: graph.distance(3))
        let full = try RoadCompass.toward(end: end, pack: graph, budget: .init())
        let capped = try RoadCompass.toward(end: end, pack: graph, budget: .init(), maxRemaining: .infinity)
        #expect(full.remaining == capped.remaining)
    }
}
