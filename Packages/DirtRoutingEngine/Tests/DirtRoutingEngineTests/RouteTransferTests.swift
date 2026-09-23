import Foundation
import Testing
@testable import DirtRoutingEngine

struct RouteTransferTests {
    @Test func optionalScrapIsRemovedButSubstantialDirtAndPinsStay() throws {
        let nodes: [Coordinate] = [.init(longitude: 0, latitude: 0), .init(longitude: 0.03, latitude: 0),
            .init(longitude: 0.06, latitude: 0), .init(longitude: 0.12, latitude: 0),
            .init(longitude: 0.035, latitude: -0.01), .init(longitude: 0.038, latitude: -0.01)]
        for reverse in [false, true] {
            let graph = try IndexedGraph(PolicyTests.Line(nodes: nodes,
                edges: [(0,1),(1,2),(2,3),(1,4),(4,5),(5,2)],
                surfaces: ["asphalt","asphalt","gravel","asphalt","gravel","asphalt"],
                roads: ["tertiary","primary","track","residential","track","residential"]))
            let request = RoutingRequest(start: nodes[reverse ? 3 : 0], end: nodes[reverse ? 0 : 3], style: .dirt)
            var detour = request; detour.options.avoidEdges = ["line-1"]; detour.options.simplifyTransfers = false
            let engine = RoutingEngine(pack: graph)
            let original = try engine.route(detour)
            #expect(original.segments.contains { $0.edge == 4 })
            let simplified = try engine.simplifiedTransfers(original, request: request, budget: .init(seconds: 10))
            #expect(!simplified.segments.contains { $0.edge == 4 })
            #expect(simplified.segments.contains { $0.edge == 1 })
            #expect(simplified.segments.contains { $0.edge == 2 })
            #expect(simplified.distanceMeters < original.distanceMeters)
            #expect(simplified.start == original.start && simplified.end == original.end)
        }
    }

    @Test func shortNecessaryConnectorIsRetained() throws {
        let nodes: [Coordinate] = [.init(longitude: 0, latitude: 0), .init(longitude: 0.02, latitude: 0),
            .init(longitude: 0.023, latitude: 0), .init(longitude: 0.05, latitude: 0)]
        let graph = try IndexedGraph(PolicyTests.Line(nodes: nodes, edges: [(0,1),(1,2),(2,3)],
            surfaces: ["asphalt","gravel","asphalt"], roads: ["tertiary","track","tertiary"]))
        for style in [RidingStyle.dirt, .balanced] {
            let result = try RoutingEngine(pack: graph).route(.init(start: nodes[0], end: nodes[3], style: style))
            #expect(result.segments.contains { $0.edge == 1 })
        }
    }

    @Test func ownerSeptember23LoopRemovesSmallDetoursAndRetainsSeparateDirtLegs() throws {
        guard let path = ProcessInfo.processInfo.environment["DIRT_COASTAL_PACK"] else { return }
        let root = URL(fileURLWithPath: path)
        let graph = try IndexedGraph(GraphPack(graphURL: root.appendingPathComponent("graph.v4.bin"),
            geometryURL: root.appendingPathComponent("geometry.v1.bin"), budget: .init(seconds: 120)), budget: .init(seconds: 120))
        let a = Coordinate(longitude: -63.34025664115886, latitude: 44.764817051109134)
        let b = Coordinate(longitude: -62.536457866023916, latitude: 44.92292596445551)
        let seed: UInt64 = 5418482707130398
        var request = LoopRequest(start: a, far: b, targetMeters: 131866.28924594066,
            style: .dirt, allowUnknown: false, seed: seed)
        request.profile.wander = 0.5; request.access.avoidFerries = true
        let initial = try LoopPlanner(pack: graph).plan(request)
        #expect(initial.distanceMeters < 250_000) // Phone: 279,283 m.
        #expect(initial.segments.allSatisfy { $0.access != 2 && $0.access != 5 && $0.structure != "ferry" })
        for route in [initial.outbound, initial.inbound] {
            #expect(RouteQuality.shortDirtExcursions(route.segments, maximumKnownMeters: 1_000).isDisjoint(with: route.segments.filter { $0.surface == .gravel || $0.surface == .loose }.map(\.edgeID)))
            // Bellefontaine dip in the exact phone result reached 44.70346.
            #expect(route.geometry.filter { $0.longitude > -63.33 && $0.longitude < -63.27 }.allSatisfy { $0.latitude > 44.73 })
        }
        var legs = [initial.outbound, initial.inbound]
        for index in 0...1 {
            var edit = RoutingRequest(start: index == 0 ? a : initial.outbound.end.coordinate,
                end: index == 0 ? initial.outbound.end.coordinate : initial.inbound.end.coordinate,
                style: .dirt, allowUnknown: true, seed: seed)
            edit.profile.wander = 0.5; edit.access.avoidFerries = true
            edit.mapZoom = index == 0 ? 7.9 : 8.1
            edit.options.composeDirtRide = true
            edit.options.loopCompanionRoads = Set(legs[1-index].segments.map(\.edgeID))
            if index == 1 {
                edit.options.priorEdges = Set(legs[0].segments.map(\.edgeID))
                edit.options.arrivalEdgeID = legs[0].endRoadIdentity
                edit.options.arrivalRestrictions = legs[0].arrivalRestrictions
            }
            legs[index] = try RoutingEngine(pack: graph).route(edit)
            #expect(RouteQuality.crossingCount(legs.flatMap(\.segments), in: graph) == 0)
            #expect(RouteQuality.shortDirtExcursions(legs[index].segments, maximumKnownMeters: 1_000).isDisjoint(with: legs[index].segments.filter { $0.surface == .gravel || $0.surface == .loose }.map(\.edgeID)))
        }
        let final = LoopPlanResult(outbound: legs[0], inbound: legs[1], far: b)
        #expect(RouteQuality(route: final.combined).knownDirtPercent > 50)
        #expect(final.reriddenMeters < final.distanceMeters * 0.1)
    }

    @Test func crossingDistinctRoadsIsDetectedButLollipopStemIsAllowed() throws {
        let nodes: [Coordinate] = [.init(longitude: -0.03, latitude: 0), .init(longitude: 0, latitude: 0),
            .init(longitude: 0.03, latitude: 0), .init(longitude: 0, latitude: 0.03),
            .init(longitude: 0, latitude: -0.03)]
        let graph = try IndexedGraph(PolicyTests.Line(nodes: nodes, edges: [(0,1),(1,2),(2,3),(3,1),(1,4)],
            surfaces: Array(repeating: "asphalt", count: 5), roads: Array(repeating: "tertiary", count: 5)))
        func segment(_ e: Int, _ forward: Bool = true) -> RouteSegment {
            .init(edge: e, edgeID: graph.edgeID(e), forward: forward, meters: graph.distance(e),
                surface: .paved, surfaceLeaf: "asphalt", roadClass: "tertiary", structure: "", access: 0,
                geometry: forward ? graph.polyline(e) : graph.polyline(e).reversed())
        }
        let figureEight = [segment(0),segment(1),segment(2),segment(3),segment(4)]
        #expect(RouteTopology.selfCrossings(figureEight, graph: graph) == [1])
        #expect(RouteTopology.crossings([segment(0),segment(1)], companion: ["line-3","line-4"],
            graph: graph, endpoints: [nodes[0],nodes[2]]) == [1])
        let lollipop = [segment(0),segment(1),segment(2),segment(3),segment(0,false)]
        #expect(RouteTopology.selfCrossings(lollipop, graph: graph).isEmpty)
    }
}
