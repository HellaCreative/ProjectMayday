import Foundation
import Testing
@testable import DirtRoutingEngine

struct StagedRouterTests {
    private var portersLake: Coordinate { .init(longitude: -63.34024797349485, latitude: 44.764804567541226) }
    private var gaspe: Coordinate { .init(longitude: -64.273363, latitude: 48.922934) }
    private var yarmouth: Coordinate { .init(longitude: -66.09856, latitude: 43.84097) }

    @Test func threePackLongTripStagesAndTwoPackNeverDoes() {
        #expect(StagedRouter.shouldStage(regionCount: 3, start: portersLake, end: gaspe))
        #expect(!StagedRouter.shouldStage(regionCount: 2, start: portersLake, end: gaspe))
        #expect(!StagedRouter.shouldStage(regionCount: 3, start: portersLake, end: yarmouth))
        #expect(StagedRouter.overlappingWindows(["ns", "nb", "qc"]) == [["ns", "nb"], ["nb", "qc"]])
        #expect(StagedRouter.overlappingWindows(["ns", "nb"]) == [["ns", "nb"]])
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
