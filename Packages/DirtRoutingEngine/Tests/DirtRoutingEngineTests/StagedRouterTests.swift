import Foundation
import Testing
@testable import DirtRoutingEngine

struct StagedRouterTests {
    private var portersLake: Coordinate { .init(longitude: -63.34024797349485, latitude: 44.764804567541226) }
    private var gaspe: Coordinate { .init(longitude: -64.273363, latitude: 48.922934) }
    private var dartmouth: Coordinate { .init(longitude: -63.57, latitude: 44.67) }

    @Test func longTwoPackAndThreePackStageWithCorrectWindows() {
        #expect(StagedRouter.shouldStage(regionCount: 3, start: portersLake, end: gaspe))
        #expect(StagedRouter.shouldStage(regionCount: 2, start: portersLake, end: gaspe))
        #expect(!StagedRouter.shouldStage(regionCount: 3, start: portersLake, end: dartmouth))
        #expect(!StagedRouter.shouldStage(regionCount: 2, start: portersLake, end: dartmouth))
        let sudbury = Coordinate(longitude: -81.0, latitude: 46.49)
        let parrySound = Coordinate(longitude: -80.035, latitude: 45.347)
        #expect(StagedRouter.shouldStage(regionCount: 2, start: parrySound, end: sudbury))
        #expect(StagedRouter.overlappingWindows(["ns", "nb", "qc"]) == [["ns", "nb"], ["nb", "qc"]])
        #expect(StagedRouter.overlappingWindows(["on-s", "on-n"]) == [["on-s"], ["on-n"]])
        #expect(StagedRouter.overlappingWindows(["ns", "nb"]) == [["ns"], ["nb"]])
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
