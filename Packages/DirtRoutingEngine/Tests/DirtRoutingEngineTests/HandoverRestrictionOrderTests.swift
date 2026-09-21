import Foundation
import Testing
@testable import DirtRoutingEngine

struct HandoverRestrictionOrderTests {
    @Test func fallbackCannotCutInsideAMultiEdgeViaSequence() throws {
        var graph = UnknownConnectorTests.Graph(lengths: [100,100,100,100], access: [0,0,0,0])
        graph.restrictions = [.init(relationID: 1, fromEdge: 0, toEdge: 3,
            viaNode: 1, viaEdges: [1,2], only: true)]
        var request = RoutingRequest(start: graph.coordinate(node: 0),
            end: graph.coordinate(node: 4), style: .dirt)
        request.options.objective = .distance
        let start = RoadMatch(edge: 0, coordinate: request.start, distanceMeters: 0,
            alongMeters: 0, geometryMeters: 100, forward: true)
        let end = RoadMatch(edge: 3, coordinate: request.end, distanceMeters: 0,
            alongMeters: 100, geometryMeters: 100, forward: true)
        let route = try PathSearch(pack: graph).search(start: start, end: end,
            policy: request.profile, access: request.access, options: request.options)
        var next = graph
        // The only shared possible cuts are inside the active via sequence.
        // The final road is deliberately absent to exercise the cut fallback.
        next.wayIDs = [-1, 1, 2, -3]
        let result = try StagedRouter.handoverBeforeFinalRoad(route, request: request,
            graph: graph, nextGraph: next, budget: .init())
        #expect(result.segments.count == 4)
        #expect(result.distanceMeters == 400)
        #expect(result.end.coordinate == request.end)
    }
}
