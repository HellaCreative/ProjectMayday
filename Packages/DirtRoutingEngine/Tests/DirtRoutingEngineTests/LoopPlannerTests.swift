import Foundation
import Testing
@testable import DirtRoutingEngine

struct LoopPlannerTests {
    private func parallelRoads(hops: Int = 30) throws -> IndexedGraph {
        var north: [Coordinate] = []
        var south: [Coordinate] = []
        for i in 0...hops {
            north.append(.init(longitude: Double(i) * 0.01, latitude: 0.002))
            south.append(.init(longitude: Double(i) * 0.01, latitude: -0.002))
        }
        let nodes = north + south
        var edges: [(Int, Int)] = []
        for i in 0..<hops { edges.append((i, i + 1)); edges.append((hops + 1 + i, hops + 2 + i)) }
        for i in 0...hops { edges.append((i, hops + 1 + i)) }
        let surfaces = Array(repeating: "dirt", count: edges.count)
        let roads = Array(repeating: "track", count: edges.count)
        return try IndexedGraph(PolicyTests.Line(nodes: nodes, edges: edges, surfaces: surfaces, roads: roads))
    }

    @Test func twoSearchesCloseOnParallelRoadsWithoutReriding() throws {
        let graph = try parallelRoads()
        let counter = SearchCounter()
        var request = LoopRequest(start: .init(longitude: 0.002, latitude: 0.002), headingRadians: .pi / 2,
                                  targetMeters: 50_000, style: .dirt)
        request.options.counter = counter
        request.options.cityWall = false
        let result = try LoopPlanner(pack: graph).plan(request, budget: .init(seconds: 10))
        #expect(counter.searches <= 4)
        #expect(result.outbound.distanceMeters > 1_000)
        #expect(result.inbound.distanceMeters > 1_000)
        #expect(result.far.longitude > request.start.longitude)
        let quality = RouteQuality(route: result.combined)
        #expect(quality.reriddenMeters < result.distanceMeters * 0.08)
    }

    @Test func aSingleRoadDoesNotReturnAFoldedCircuit() throws {
        let nodes = (0...8).map { Coordinate(longitude: Double($0) * 0.01, latitude: 0) }
        let graph = try IndexedGraph(PolicyTests.Line(
            nodes: nodes, edges: (0..<8).map { ($0, $0 + 1) },
            surfaces: Array(repeating: "dirt", count: 8),
            roads: Array(repeating: "track", count: 8)))
        #expect(throws: LoopFailure.self) {
            try LoopPlanner(pack: graph).plan(
                .init(start: .init(longitude: 0.002, latitude: 0), headingRadians: .pi / 2,
                      targetMeters: 12_000, style: .dirt),
                budget: .init(seconds: 10))
        }
    }

    @Test func headingExpansionDoesNotChangeOrdinaryABSearch() throws {
        let graph = try parallelRoads(hops: 8)
        let start = RoadMatch(edge: 0, coordinate: .init(longitude: 0.002, latitude: 0.002), distanceMeters: 0,
                              alongMeters: 1, geometryMeters: 1_112, forward: true)
        let end = RoadMatch(edge: 14, coordinate: .init(longitude: 0.078, latitude: 0.002), distanceMeters: 0,
                              alongMeters: 1_000, geometryMeters: 1_112, forward: true)
        var options = SearchOptions()
        options.cityWall = false
        let baseline = try PathSearch(pack: graph).search(start: start, end: end, policy: .init(style: .dirt),
                                                          access: .init(), options: options, budget: .init())
        #expect(options.expandToCap == false)
        #expect(options.headingRadians == nil)
        let again = try PathSearch(pack: graph).search(start: start, end: end, policy: .init(style: .dirt),
                                                       access: .init(), options: options, budget: .init())
        #expect(baseline.segments.map(\.edgeID) == again.segments.map(\.edgeID))
    }
}
