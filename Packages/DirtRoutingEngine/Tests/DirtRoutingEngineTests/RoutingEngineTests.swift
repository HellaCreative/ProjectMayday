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
        #expect(route.searchSummary?.contains("shortest") == true)
        #expect(route.searchSummary?.contains("∞") != true)
    }

    @Test func counterIncludesEverySearchNotJustTheSelectedRoute() throws {
        var counted = request
        let counter = SearchCounter()
        counted.options.counter = counter
        let route = try RoutingEngine(pack: pavedLine()).route(counted,budget: .init(seconds: 20))
        // Shortest path plus a 50/50 profile search; an all-paved line then tries
        // the dirt-preferring correction. None of those flood past B.
        #expect(counter.searches == 3)
        #expect((route.searchSummary?.split(separator: ",").filter { !$0.hasPrefix("shape:") }.count) == 3)
        #expect(counter.pops >= route.poppedLabels)
        #expect(counter.stageSummary.contains("compass"))
    }

    @Test func balancedStopsAtTheDestinationInsteadOfFloodingForFiftyPercent() throws {
        var counted = request
        let counter = SearchCounter()
        counted.options.counter = counter
        let route = try RoutingEngine(pack: pavedLine()).route(counted,budget: .init(seconds: 20))
        #expect(route.distanceMeters > 0)
        #expect(counter.peakLabels < 1_000)
        #expect(counter.pops < 1_000)
    }

    @Test func destinationDirectionDoesNotForceAWrongWayArrival() throws {
        let graph = try pavedLine()
        let start = RoadMatch(edge: 0,coordinate: .init(longitude: 0.001,latitude: 0),distanceMeters: 0,
                              alongMeters: graph.distance(0)*0.1,geometryMeters: graph.distance(0),forward: true)
        // A westbound destination match on the eastern dead end. Reaching it westbound would
        // mean turning straight back; arrival instead uses the road's eastbound direction.
        let end = RoadMatch(edge: 5,coordinate: .init(longitude: 0.059,latitude: 0),distanceMeters: 0,
                            alongMeters: graph.distance(5)*0.9,geometryMeters: graph.distance(5),forward: false)
        let route = try PathSearch(pack: graph).search(start: start,end: end,policy: .init(style: .balanced),
                                                       access: .init(),options: .init(),budget: .init())
        #expect(route.end.edge == 5)
        #expect(route.segments.last?.forward == true)
        #expect(try EndpointReachability(graph: graph,budget: .init()).mayConnect(start: start,end: end,budget: .init()))
    }

    @Test func disconnectedPairIsRuledOutWithoutSearching() throws {
        let line = PolicyTests.Line(nodes: [.init(longitude: 0,latitude: 0),.init(longitude: 0.01,latitude: 0),
                                            .init(longitude: 0.5,latitude: 0),.init(longitude: 0.51,latitude: 0)],
                                    edges: [(0,1),(2,3)],surfaces: ["asphalt","asphalt"],roads: ["tertiary","tertiary"])
        let graph = try IndexedGraph(line)
        let start = RoadMatch(edge: 0,coordinate: line.nodes[0],distanceMeters: 0,alongMeters: 0,
                              geometryMeters: line.distance(0),forward: true)
        let end = RoadMatch(edge: 1,coordinate: line.nodes[3],distanceMeters: 0,alongMeters: line.distance(1),
                            geometryMeters: line.distance(1),forward: true)
        #expect(try !EndpointReachability(graph: graph,budget: .init()).mayConnect(start: start,end: end,budget: .init()))
        #expect(throws: RoutingFailure.noPath) {
            try PathSearch(pack: graph).search(start: start,end: end,policy: .init(style: .balanced),
                                               access: .init(),options: .init(),budget: .init())
        }
    }

    @Test func cleanestTakesBackRoadsAndStaysNearTheShortestLegalNonHighway() throws {
        let pack = PolicyTests.Line(
            nodes: [
                .init(longitude: 0,latitude: 0),.init(longitude: 0.015,latitude: 0.02),
                .init(longitude: 0.045,latitude: 0.02),.init(longitude: 0.06,latitude: 0)
            ],
            edges: [(0,1),(1,2),(2,3),(0,3)],
            surfaces: Array(repeating: "asphalt", count: 4),
            roads: ["tertiary","tertiary","tertiary","motorway"]
        )
        let graph = try IndexedGraph(pack)
        var clean = RoutingRequest(start: .init(longitude: 0.002,latitude: 0.018),
                                   end: .init(longitude: 0.058,latitude: 0.018),style: .cleanest)
        clean.matchRadiusMeters = 2000
        let backRoad = try RoutingEngine(pack: graph).route(clean,budget: .init(seconds: 20))
        #expect(!backRoad.segments.contains { ProfilePolicy.tier($0.roadClass) == "motorway" })
        let local = pack.distance(0)+pack.distance(1)+pack.distance(2)
        let motorway = pack.distance(3)
        #expect(motorway < local)
        #expect(backRoad.distanceMeters <= local * 1.12)
    }

    @Test func cleanestDoesNotTakeDirtWhenAPavedBackRoadExists() throws {
        let pack = PolicyTests.Line(
            nodes: [
                .init(longitude: 0,latitude: 0),.init(longitude: 0.015,latitude: 0.02),
                .init(longitude: 0.045,latitude: 0.02),.init(longitude: 0.06,latitude: 0)
            ],
            edges: [(0,1),(1,2),(2,3),(0,3)],
            surfaces: ["asphalt","asphalt","asphalt","dirt"],
            roads: ["residential","residential","residential","track"]
        )
        let graph = try IndexedGraph(pack)
        var clean = RoutingRequest(start: .init(longitude: 0.002,latitude: 0.018),
                                   end: .init(longitude: 0.058,latitude: 0.018),style: .cleanest)
        clean.matchRadiusMeters = 2000
        let backRoad = try RoutingEngine(pack: graph).route(clean,budget: .init(seconds: 20))
        let dirtShortcut = pack.distance(3)
        let paved = pack.distance(0)+pack.distance(1)+pack.distance(2)
        #expect(dirtShortcut < paved)
        let dirtMeters = backRoad.segments.filter { $0.surface == .gravel || $0.surface == .loose }.reduce(0) { $0+$1.meters }
        #expect(dirtMeters / max(1,backRoad.distanceMeters) < 0.05)
        #expect(!backRoad.segments.contains { $0.surface == .loose || $0.surface == .gravel })
        #expect(backRoad.searchSummary?.contains("paved/") == true)
        #expect(backRoad.searchSummary?.contains("shortest/") == true)
    }

    @Test func cleanestCapsLengthAgainstPinSpan() throws {
        // Long scenic paved loop vs short paved spine. Cap is 1.5× span.
        let pack = PolicyTests.Line(
            nodes: [
                .init(longitude: 0, latitude: 0),
                .init(longitude: 0.05, latitude: 0),
                .init(longitude: 0.01, latitude: 0.08),
                .init(longitude: 0.025, latitude: 0.12),
                .init(longitude: 0.04, latitude: 0.08)
            ],
            edges: [(0,1),(0,2),(2,3),(3,4),(4,1)],
            surfaces: Array(repeating: "asphalt", count: 5),
            roads: Array(repeating: "tertiary", count: 5)
        )
        let graph = try IndexedGraph(pack)
        let start = Coordinate(longitude: 0.002, latitude: 0)
        let end = Coordinate(longitude: 0.048, latitude: 0)
        var clean = RoutingRequest(start: start, end: end, style: .cleanest)
        clean.matchRadiusMeters = 2000
        let route = try RoutingEngine(pack: graph).route(clean, budget: .init(seconds: 20))
        let span = start.distance(to: end)
        #expect(route.distanceMeters <= span * 1.50 + 1_000)
    }

    @Test func cleanestUsesAHighwayOnlyWhenNoBackRoadConnects() throws {
        let pack = PolicyTests.Line(
            nodes: [
                .init(longitude: 0,latitude: 0.01),.init(longitude: 0.01,latitude: 0.01),
                .init(longitude: 0.05,latitude: 0.01),.init(longitude: 0.06,latitude: 0.01)
            ],
            edges: [(0,1),(2,3),(1,2)],
            surfaces: ["asphalt","asphalt","asphalt"],
            roads: ["tertiary","tertiary","motorway"]
        )
        let graph = try IndexedGraph(pack)
        var clean = RoutingRequest(start: .init(longitude: 0.002,latitude: 0.01),
                                   end: .init(longitude: 0.058,latitude: 0.01),style: .cleanest)
        clean.matchRadiusMeters = 2000
        let route = try RoutingEngine(pack: graph).route(clean,budget: .init(seconds: 20))
        #expect(route.segments.contains { ProfilePolicy.tier($0.roadClass) == "motorway" })
        #expect(route.distanceMeters > 0)
    }

    @Test func coincidentDistinctSourceNodesRemainUnreachable() throws {
        // Separate source nodes at one position are not evidence of a junction.
        let line = PolicyTests.Line(nodes: [.init(longitude: 0,latitude: 0),.init(longitude: 0.01,latitude: 0),
                                            .init(longitude: 0.01,latitude: 0),.init(longitude: 0.02,latitude: 0)],
                                    edges: [(0,1),(2,3)],surfaces: ["dirt","dirt"],roads: ["track","track"])
        let graph = try IndexedGraph(line)
        let start = RoadMatch(edge: 0,coordinate: line.nodes[0],distanceMeters: 0,alongMeters: 0,
                              geometryMeters: line.distance(0),forward: true)
        let end = RoadMatch(edge: 1,coordinate: line.nodes[3],distanceMeters: 0,alongMeters: line.distance(1),
                            geometryMeters: line.distance(1),forward: true)
        #expect(try !EndpointReachability(graph: graph,budget: .init()).mayConnect(start: start,end: end,budget: .init()))
    }

    @Test func dirtOpeningPrefersArterialProgressOverPavedCollectorU() throws {
        // Porters Lake shape: from a local junction, arterial goes toward B;
        // a longer paved collector dips south then rejoins. No dirt on either
        // opening path — Dirt must hang the arterial instead of fleeing ×8.
        let pack = PolicyTests.Line(
            nodes: [
                .init(longitude: 0, latitude: 0),          // 0 start
                .init(longitude: 0.02, latitude: 0.01),    // 1 arterial mid
                .init(longitude: 0.04, latitude: 0.02),    // 2 dest approach
                .init(longitude: 0.01, latitude: -0.025),  // 3 south dip
                .init(longitude: 0.03, latitude: -0.02),   // 4 south return
            ],
            edges: [
                (0, 1), // arterial toward pin
                (1, 2), // arterial finish
                (0, 3), // collector south
                (3, 4), // collector along bottom
                (4, 2), // collector rejoin
            ],
            surfaces: Array(repeating: "asphalt", count: 5),
            roads: ["primary", "primary", "secondary", "secondary", "secondary"]
        )
        let graph = try IndexedGraph(pack)
        let start = RoadMatch(edge: 0, coordinate: pack.nodes[0], distanceMeters: 0, alongMeters: 0,
                              geometryMeters: pack.distance(0), forward: true)
        let end = RoadMatch(edge: 1, coordinate: pack.nodes[2], distanceMeters: 0,
                            alongMeters: pack.distance(1), geometryMeters: pack.distance(1), forward: true)
        let compass = try RoadCompass.toward(end: end, pack: graph, budget: .init())
        var options = SearchOptions()
        options.objective = .pavement
        options.corridorMeters = .infinity
        options.roadRemaining = compass.remaining
        let route = try PathSearch(pack: graph).search(
            start: start, end: end, policy: .init(style: .dirt),
            access: .init(), options: options, budget: .init(seconds: 20))
        let ids = Set(route.segments.map(\.edgeID))
        #expect(ids.contains("line-0"))
        #expect(ids.contains("line-1"))
        #expect(!ids.contains("line-2"))
        #expect(!ids.contains("line-3"))
        let south = route.geometry.map { (pack.nodes[0].latitude - $0.latitude) * 111_320 }.max() ?? 0
        #expect(south < 500)
    }
}
