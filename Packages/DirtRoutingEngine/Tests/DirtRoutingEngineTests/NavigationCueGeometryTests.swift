import Testing
@testable import DirtRoutingEngine

struct NavigationCueGeometryTests {
    @Test func tinyStraightVerticesDoNotHideTurningApproaches() throws {
        let incoming = [Coordinate(longitude: 0, latitude: -0.001), .init(longitude: -0.00001, latitude: 0), .init(longitude: 0, latitude: 0)]
        let outgoing = [Coordinate(longitude: 0, latitude: 0), .init(longitude: 0.00001, latitude: 0), .init(longitude: 0.001, latitude: 0)]
        let turn = try #require(NavigationCues.turnDegrees(incoming: incoming, outgoing: outgoing))
        #expect(turn > 60 && turn < 110)
    }

    @Test func straightAndUTurnKeepTheirMeaning() throws {
        let west = Coordinate(longitude: -0.001, latitude: 0)
        let middle = Coordinate(longitude: 0, latitude: 0)
        let east = Coordinate(longitude: 0.001, latitude: 0)
        #expect(abs(try #require(NavigationCues.turnDegrees(incoming: [west, middle], outgoing: [middle, east]))) < 1)
        #expect(abs(try #require(NavigationCues.turnDegrees(incoming: [west, middle], outgoing: [middle, west]))) > 179)
    }
    @Test func reportedRoadAllowsRetreatButNotForwardTravelOrBlockedArrival() throws {
        let nodes = [Coordinate(longitude: 0, latitude: 0), .init(longitude: 0.01, latitude: 0),
                     .init(longitude: 0, latitude: 0.01), .init(longitude: 0.01, latitude: 0.01)]
        let graph = try IndexedGraph(PolicyTests.Line(nodes: nodes, edges: [(0,1),(0,2),(2,3),(3,1)],
            surfaces: Array(repeating: "asphalt", count: 4), roads: Array(repeating: "tertiary", count: 4)))
        let start = RoadMatch(edge: 0, coordinate: .init(longitude: 0.005, latitude: 0), distanceMeters: 0,
                              alongMeters: graph.distance(0) / 2, geometryMeters: graph.distance(0))
        let end = RoadMatch(edge: 3, coordinate: .init(longitude: 0.01, latitude: 0.005), distanceMeters: 0,
                            alongMeters: graph.distance(3) / 2, geometryMeters: graph.distance(3))
        var options = SearchOptions()
        options.avoidEdges = ["line-0"]
        options.blockedStartEscapeToward = nodes[0]
        let route = try PathSearch(pack: graph).search(start: start, end: end,
            policy: .init(style: .cleanest), access: .init(), options: options)
        #expect(route.segments.first?.edgeID == "line-0")
        #expect(route.segments.first?.forward == false)
        #expect(route.segments.dropFirst().allSatisfy { $0.edgeID != "line-0" })
        #expect(route.segments.map(\.edgeID) == ["line-0", "line-1", "line-2", "line-3"])
        var request = RoutingRequest(start: start.coordinate, end: end.coordinate, style: .cleanest)
        request.options = options
        let planned = try RoutingEngine(pack: graph).route(request)
        #expect(planned.segments.first?.forward == false)
        #expect(planned.segments.dropFirst().allSatisfy { $0.edgeID != "line-0" })
        let blockedEnd = RoadMatch(edge: 0, coordinate: nodes[1], distanceMeters: 0,
            alongMeters: graph.distance(0), geometryMeters: graph.distance(0))
        #expect(throws: RoutingFailure.noPath) {
            try PathSearch(pack: graph).search(start: start, end: blockedEnd,
                policy: .init(style: .cleanest), access: .init(), options: options)
        }
        let forwardOnlyStart = RoadMatch(edge: 0, coordinate: start.coordinate, distanceMeters: 0,
            alongMeters: start.alongMeters, geometryMeters: start.geometryMeters, forward: true)
        #expect(throws: RoutingFailure.noPath) {
            try PathSearch(pack: graph).search(start: forwardOnlyStart, end: end,
                policy: .init(style: .cleanest), access: .init(), options: options)
        }
    }

}
