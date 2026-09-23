import Foundation
import Testing
@testable import DirtRoutingEngine

struct LocalRouteEditTests {
    @Test func cleanEditKeepsAcceptedRoadButNeverOverridesClosure() throws {
        let nodes = [Coordinate(longitude: 0, latitude: 0), .init(longitude: 0.01, latitude: 0),
                     .init(longitude: 0.03, latitude: 0), .init(longitude: 0.04, latitude: 0),
                     .init(longitude: 0.02, latitude: 0.012)]
        var source = PolicyTests.Line(nodes: nodes, edges: [(0,1),(1,2),(2,3),(1,4),(4,2)],
            surfaces: Array(repeating: "asphalt", count: 5),
            roads: ["tertiary","primary","tertiary","tertiary","tertiary"])
        var request = RoutingRequest(start: nodes[0], end: nodes[3], style: .cleanest)
        request.options.varietyEnabled = false
        let ordinary = try RoutingEngine(pack: IndexedGraph(source)).route(request)
        #expect(ordinary.segments.contains { $0.edge == 3 })
        request.options.preferredCorridorRoads = ["line-0","line-1","line-2"]
        let local = try RoutingEngine(pack: IndexedGraph(source)).route(request)
        #expect(local.segments.map(\.edge) == [0,1,2])
        source.edgeAccess = [0,2,0,0,0]
        let legal = try RoutingEngine(pack: IndexedGraph(source)).route(request)
        #expect(!legal.segments.contains { $0.edge == 1 })
        #expect(legal.segments.contains { $0.edge == 3 })
    }

    @Test func shortDirtConnectorRemainsAvailable() throws {
        let nodes = [Coordinate(longitude: 0, latitude: 0), .init(longitude: 0.01, latitude: 0),
                     .init(longitude: 0.013, latitude: 0), .init(longitude: 0.023, latitude: 0)]
        let graph = try IndexedGraph(PolicyTests.Line(nodes: nodes, edges: [(0,1),(1,2),(2,3)],
            surfaces: ["asphalt","gravel","asphalt"], roads: ["tertiary","residential","tertiary"]))
        var request = RoutingRequest(start: nodes[0], end: nodes[3], style: .balanced)
        request.options.varietyEnabled = false
        let route = try RoutingEngine(pack: graph).route(request)
        #expect(route.segments.map(\.edge) == [0,1,2])
        #expect(route.end.coordinate.distance(to: nodes[3]) < 1)
    }

    @Test func ownerCoastalBalancedAndCleanEdit() throws {
        guard let directory = ProcessInfo.processInfo.environment["DIRT_COASTAL_PACK"] else { return }
        let root = URL(fileURLWithPath: directory)
        let graph = try IndexedGraph(GraphPack(graphURL: root.appendingPathComponent("graph.v4.bin"),
            geometryURL: root.appendingPathComponent("geometry.v1.bin"), budget: .init(seconds: 120)), budget: .init(seconds: 120))
        let a = Coordinate(longitude: -63.340282994964475, latitude: 44.764788479181554)
        let b = Coordinate(longitude: -62.535082727942886, latitude: 44.9217014613305)
        var request = RoutingRequest(start: a, end: b, style: .balanced, seed: 1369334504736932)
        request.profile.wander = 0
        request.profile.avoidMajorHighways = true
        request.access.avoidFerries = true
        let engine = RoutingEngine(pack: graph)
        let balanced = try engine.route(request, budget: .init(seconds: 30))
        let quality = RouteQuality(route: balanced)
        #expect(balanced.distanceMeters < 131_000)
        #expect(quality.shortDirtScrapMeters < 1_000)
        #expect(quality.meaningfulDirtMeters >= 6_000)
        request.profile.style = .cleanest
        request.profile.preferBackRoads = true
        request.options.preferredCorridorRoads = Set(balanced.segments.map(\.edgeID))
        let clean = try engine.route(request, budget: .init(seconds: 30))
        #expect(RouteQuality(route: clean).knownDirtPercent == 0)
        #expect(clean.geometry.allSatisfy { $0.latitude < 45 })
        #expect(clean.start.coordinate.distance(to: balanced.start.coordinate) < 1)
        #expect(clean.end.coordinate.distance(to: balanced.end.coordinate) < 1)
    }
}
