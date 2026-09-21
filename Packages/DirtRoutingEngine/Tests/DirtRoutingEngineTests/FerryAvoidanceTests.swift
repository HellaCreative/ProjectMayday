import Foundation
import Testing
@testable import DirtRoutingEngine

struct FerryAvoidanceTests {
    private func graph(land: Bool = true) -> PolicyTests.Line {
        let nodes: [Coordinate] = [
            .init(longitude: 0, latitude: 0), .init(longitude: 0.02, latitude: 0),
            .init(longitude: 0.04, latitude: 0), .init(longitude: 0.06, latitude: 0),
            .init(longitude: 0.02, latitude: 0.025), .init(longitude: 0.04, latitude: 0.025)]
        let edges = land ? [(0,1),(1,2),(2,3),(1,4),(4,5),(5,2)] : [(0,1),(1,2),(2,3)]
        return PolicyTests.Line(nodes: nodes, edges: edges,
            surfaces: Array(repeating: "asphalt", count: edges.count),
            roads: Array(repeating: "trunk", count: edges.count),
            structures: ["", "ferry", ""] + (land ? ["", "bridge", ""] : []))
    }

    @Test func avoidsFerriesIncludingHighwayBridgeApproachesAndCacheChanges() throws {
        let pack = try IndexedGraph(graph())
        let engine = RoutingEngine(pack: pack, compassStore: RoadCompassStore())
        for style: RidingStyle in [.dirt, .balanced, .cleanest] {
            var request = RoutingRequest(start: pack.coordinate(node: 0), end: pack.coordinate(node: 3), style: style)
            request.profile.avoidMajorHighways = true
            // Exercise the same prepared graph and guidance store in both orders.
            for avoid in [false, true, false, true] {
                request.access.avoidFerries = avoid
                let route = try engine.route(request)
                #expect(route.limit == nil)
                if avoid {
                    #expect(!route.segments.contains { $0.structure == "ferry" })
                    #expect(route.segments.contains { $0.structure == "bridge" })
                } else {
                    #expect(route.segments.contains { $0.structure == "ferry" })
                }
            }
        }
    }

    @Test func necessaryFerryPromptsAndExplicitOptInWorks() throws {
        let pack = graph(land: false)
        let engine = RoutingEngine(pack: pack)
        var request = RoutingRequest(start: pack.nodes[0], end: pack.nodes[3], style: .dirt)
        request.access.avoidFerries = true
        #expect(throws: RoutingFailure.ferriesAvoided) { try engine.route(request) }
        var loop = LoopRequest(start: request.start, far: request.end, targetMeters: 20_000, style: .dirt)
        loop.access = request.access
        #expect(throws: RoutingFailure.ferriesAvoided) { try LoopPlanner(pack: pack).plan(loop) }
        request.access.avoidFerries = false
        #expect(try engine.route(request).segments.contains { $0.structure == "ferry" })
    }

    @Test func disconnectedRoadsDoNotMisreportANecessaryFerry() throws {
        var roads = graph(land: false)
        roads.structures = ["", "", ""]
        roads.edgeAccess = [0, 2, 0]
        let pack = try IndexedGraph(roads)
        var request = RoutingRequest(start: roads.nodes[0], end: roads.nodes[3], style: .balanced)
        request.matchRadiusMeters = 100
        request.access.avoidFerries = true
        #expect(throws: RoutingFailure.noPath) { try RoutingEngine(pack: pack).route(request) }
    }

    @Test func stagedHandoverCannotClaimFerryDependentContinuation() throws {
        let pack = try IndexedGraph(graph(land: false))
        var request = RoutingRequest(start: pack.coordinate(node: 0), end: pack.coordinate(node: 3), style: .dirt)
        request.access.avoidFerries = true
        var reach: EndpointReachability?
        #expect(try !StagedRouter.hopLooksLive(request.end, origin: request.start, graph: pack,
            request: request, budget: .init(), reach: &reach))
        request.access.avoidFerries = false
        reach = nil
        #expect(try StagedRouter.hopLooksLive(request.end, origin: request.start, graph: pack,
            request: request, budget: .init(), reach: &reach))
    }

    @Test func ferryEndpointCannotOverrideSwitchOrLegalAccess() throws {
        var pack = graph(land: false)
        let point = Coordinate(longitude: 0.03, latitude: 0)
        var request = RoutingRequest(start: pack.nodes[0], end: point, style: .dirt)
        request.access.avoidFerries = true
        #expect(throws: RoutingFailure.ferriesAvoided) { try RoutingEngine(pack: pack).route(request) }
        request.access.avoidFerries = false
        #expect(try RoutingEngine(pack: pack).route(request).segments.contains { $0.structure == "ferry" })
        pack.edgeAccess = [0,2,0]
        request.access.allowUnknown = true
        #expect(throws: RoutingFailure.noMatch) { try RoutingEngine(pack: pack).route(request) }
    }

    @Test func regionalChoiceExcludesWaterShortcutsAndDetectsNecessaryFerry() throws {
        let neighbors: [String:Set<String>] = ["ns":["nb","nl"], "nb":["ns","qs"],
            "qs":["nb","qn"], "qn":["qs","nl","lb"], "nl":["ns","qn"], "lb":["qn"]]
        let roads: [String:Set<String>] = ["ns":["nb"], "nb":["ns","qs"],
            "qs":["nb","qn"], "qn":["qs","lb"], "nl":[], "lb":["qn"]]
        let connectivity = RegionConnectivity(neighbors: neighbors)
        #expect(try connectivity.chains(from: "ns", to: "lb", roadNeighbors: roads, avoidFerries: true)
            == [["ns","nb","qs","qn","lb"]])
        #expect(throws: RoutingFailure.ferriesAvoided) {
            try connectivity.chains(from: "ns", to: "nl", roadNeighbors: roads, avoidFerries: true)
        }
        #expect(try connectivity.chains(from: "ns", to: "nl", roadNeighbors: roads).contains(["ns","nl"]))
    }
}
