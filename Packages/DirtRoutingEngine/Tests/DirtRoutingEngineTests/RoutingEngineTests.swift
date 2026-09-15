import Foundation
import Testing
@testable import DirtRoutingEngine

struct RoutingEngineTests {
    /// A straight paved road. Balanced can never land in its 45–55% dirt band here,
    /// so the corridor sequence runs all the way to its final, unbounded width.
    private var request: RoutingRequest {
        .init(start: .init(longitude: 0.001,latitude: 0),end: .init(longitude: 0.059,latitude: 0),style: .balanced)
    }
    private func pavedLine() throws -> IndexedGraph {
        let nodes = (0...6).map { Coordinate(longitude: Double($0)*0.01,latitude: 0) }
        return try IndexedGraph(PolicyTests.Line(nodes: nodes,edges: (0..<6).map { ($0,$0+1) },
            surfaces: Array(repeating: "asphalt",count: 6),roads: Array(repeating: "tertiary",count: 6)))
    }

    @Test func balancedSummaryNamesTheUnboundedCorridorWithoutTrapping() throws {
        let route = try RoutingEngine(pack: pavedLine()).route(request,budget: .init(seconds: 20))
        #expect(route.distanceMeters > 0)
        #expect(route.searchSummary?.contains("∞") == true)
    }

    @Test func counterIncludesEverySearchNotJustTheSelectedRoute() throws {
        var counted = request
        let counter = SearchCounter()
        counted.options.counter = counter
        let route = try RoutingEngine(pack: pavedLine()).route(counted,budget: .init(seconds: 20))
        // The first pair arrives facing the wrong way on this dead-end road; its search
        // fails. Later pairs that cannot connect are ruled out without searching. The
        // connecting pair runs a shortest-distance search and the first corridor; no road
        // meets that corridor's limit, so the six wider corridors reuse its result.
        #expect(counter.searches == 3)
        #expect(route.searchSummary?.split(separator: ",").count == 7)
        #expect(counter.pops > route.poppedLabels)
        #expect(counter.stageSummary.contains("reachability"))
        #expect(counter.stageSummary.contains("compass"))
    }

    @Test func wrongWayArrivalOnADeadEndIsRuledOutWithoutSearching() throws {
        let graph = try pavedLine()
        let reachability = try EndpointReachability(graph: graph,budget: .init())
        let start = RoadMatch(edge: 0,coordinate: .init(longitude: 0.001,latitude: 0),distanceMeters: 0,
                              alongMeters: graph.distance(0)*0.1,geometryMeters: graph.distance(0),forward: true)
        func end(forward: Bool) -> RoadMatch {
            .init(edge: 5,coordinate: .init(longitude: 0.059,latitude: 0),distanceMeters: 0,
                  alongMeters: graph.distance(5)*0.9,geometryMeters: graph.distance(5),forward: forward)
        }
        #expect(try reachability.mayConnect(start: start,end: end(forward: true),budget: .init()))
        #expect(try !reachability.mayConnect(start: start,end: end(forward: false),budget: .init()))
        // The search agrees: arriving westbound means turning straight back at the dead end.
        #expect(throws: RoutingFailure.noPath) {
            try PathSearch(pack: graph).search(start: start,end: end(forward: false),policy: .init(style: .balanced),
                                               access: .init(),options: .init(),budget: .init())
        }
    }

    @Test func coincidentNodesKeepAPairReachable() throws {
        // Two roads broken at duplicate nodes 1 and 2: only the zero-length transfer joins them.
        let line = PolicyTests.Line(nodes: [.init(longitude: 0,latitude: 0),.init(longitude: 0.01,latitude: 0),
                                            .init(longitude: 0.01,latitude: 0),.init(longitude: 0.02,latitude: 0)],
                                    edges: [(0,1),(2,3)],surfaces: ["dirt","dirt"],roads: ["track","track"])
        let graph = try IndexedGraph(line)
        let start = RoadMatch(edge: 0,coordinate: line.nodes[0],distanceMeters: 0,alongMeters: 0,
                              geometryMeters: line.distance(0),forward: true)
        let end = RoadMatch(edge: 1,coordinate: line.nodes[3],distanceMeters: 0,alongMeters: line.distance(1),
                            geometryMeters: line.distance(1),forward: true)
        #expect(try EndpointReachability(graph: graph,budget: .init()).mayConnect(start: start,end: end,budget: .init()))
    }
}
