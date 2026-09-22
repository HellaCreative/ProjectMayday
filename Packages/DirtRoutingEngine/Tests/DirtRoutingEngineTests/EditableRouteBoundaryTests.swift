import Testing
@testable import DirtRoutingEngine

struct EditableRouteBoundaryTests {
    private func route(_ graph: UnknownConnectorTests.Graph, endFraction: Double = 1) throws -> ComputedRoute {
        let last = graph.edgeCount - 1
        let a = graph.coordinate(node: last), b = graph.coordinate(node: last + 1)
        let point = Coordinate(longitude: a.longitude + (b.longitude - a.longitude) * endFraction,
                               latitude: a.latitude + (b.latitude - a.latitude) * endFraction)
        let start = RoadMatch(edge: 0, coordinate: graph.coordinate(node: 0), distanceMeters: 0,
                              alongMeters: 0, geometryMeters: graph.distance(0), forward: true)
        let end = RoadMatch(edge: last, coordinate: point, distanceMeters: 0,
                            alongMeters: graph.distance(last) * endFraction,
                            geometryMeters: graph.distance(last), forward: true)
        var options = SearchOptions(); options.objective = .distance
        return try PathSearch(pack: graph).search(start: start, end: end,
            policy: ProfilePolicy(style: .dirt), access: AccessPolicy(), options: options)
    }

    @Test func generatedPinCannotResetAnActiveViaWaySequence() throws {
        var graph = UnknownConnectorTests.Graph(lengths: [100,100,100,100], access: [0,0,0,0])
        graph.restrictions = [.init(relationID: 1, fromEdge: 0, toEdge: 3,
                                    viaNode: 1, viaEdges: [1,2], only: true)]
        let route = try route(graph)
        let boundaries = try #require(try EditableRouteBoundary.proven(in: route, graph: graph))
        #expect(boundaries.map(\.segmentCount) == [1,4])
        #expect(boundaries.map(\.meters) == [100,400])
        #expect(boundaries.last?.incomingRoadIdentity == graph.identity(of: 3))
    }

    @Test func unknownConnectorIsNotAnEligibleGeneratedDestination() throws {
        let graph = UnknownConnectorTests.Graph(lengths: [100,50,100], access: [0,1,0])
        let boundaries = try #require(try EditableRouteBoundary.proven(in: try route(graph), graph: graph))
        #expect(boundaries.map(\.segmentCount) == [1,3])
    }

    @Test func partialFinalRoadRetainsExactMatchedPosition() throws {
        let graph = UnknownConnectorTests.Graph(lengths: [100,100], access: [0,0])
        let route = try route(graph, endFraction: 0.5)
        let boundaries = try #require(try EditableRouteBoundary.proven(in: route, graph: graph))
        #expect(boundaries.last?.match == route.end)
        #expect(boundaries.last?.meters == 150)
        #expect(boundaries.last?.match.coordinate != graph.coordinate(node: 2))
    }

    @Test func incompleteOrUnverifiableRouteDoesNotInventLegalCuts() throws {
        let graph = UnknownConnectorTests.Graph(lengths: [100,100], access: [0,0])
        let route = try route(graph)
        #expect(try EditableRouteBoundary.proven(in: route.reportingLimit("time"), graph: graph) == nil)
        #expect(try EditableRouteBoundary.proven(in: route, graph: graph,
            initialRestrictions: [.init(pattern: 999, progress: 1)]) == nil)
    }
}
