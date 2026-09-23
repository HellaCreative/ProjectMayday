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
    @Test func ownerLoopEditsKeepSeparateSidesAndCleanUsesDirectRoad() throws {
        guard let directory = ProcessInfo.processInfo.environment["DIRT_COASTAL_PACK"] else { return }
        let root = URL(fileURLWithPath: directory)
        let graph = try IndexedGraph(GraphPack(graphURL: root.appendingPathComponent("graph.v4.bin"),
            geometryURL: root.appendingPathComponent("geometry.v1.bin"), budget: .init(seconds: 120)), budget: .init(seconds: 120))
        let a = Coordinate(longitude: -63.34023965707092, latitude: 44.76481859931819)
        let b = Coordinate(longitude: -63.23295900164769, latitude: 44.97126234174599)
        let seed: UInt64 = 2208728428561571
        let engine = RoutingEngine(pack: graph)
        var loop = LoopRequest(start: a, far: b, targetMeters: 48914.142495787826,
                               style: .dirt, allowUnknown: false, seed: seed)
        loop.profile.wander = 0.5; loop.profile.avoidMajorHighways = false; loop.access.avoidFerries = true
        var failedPin = LoopRequest(start: a,
            far: .init(longitude: -63.369380, latitude: 44.928931),
            targetMeters: 36_785, style: .dirt, seed: 5468655885203066)
        failedPin.profile.wander = 0.5
        failedPin.profile.avoidMajorHighways = false
        failedPin.access.avoidFerries = true
        let recovered = try LoopPlanner(pack: graph).plan(failedPin)
        #expect(recovered.outbound.limit == nil && recovered.inbound.limit == nil)
        #expect(recovered.outbound.end.coordinate.distance(to: failedPin.far) < 150)
        #expect(recovered.inbound.end.coordinate.distance(to: a) < 150)
        let initial = try LoopPlanner(pack: graph).plan(loop)
        var legs = [initial.outbound, initial.inbound]
        for index in 0...1 {
            var edit = RoutingRequest(start: index == 0 ? a : b, end: index == 0 ? b : a,
                style: .dirt, allowUnknown: true, seed: seed)
            edit.profile.wander = 0.5; edit.access.avoidFerries = true
            edit.options.composeDirtRide = true
            edit.options.loopCompanionRoads = Set(legs[1-index].segments.map(\.edgeID))
            if index == 1 {
                edit.options.priorEdges = Set(legs[0].segments.map(\.edgeID))
                edit.options.arrivalEdgeID = legs[0].endRoadIdentity
                edit.options.arrivalRestrictions = legs[0].arrivalRestrictions
            }
            let began = ContinuousClock.now
            legs[index] = try engine.route(edit)
            print("owner loop edit half=\(index) elapsed=\(began.duration(to: .now)) roadsInCompanion=\(edit.options.loopCompanionRoads.count)")
            #expect(legs[index].limit == nil)
            #expect(legs[index].end.coordinate.distance(to: edit.end) < 150)
        }
        let circuit = LoopPlanResult(outbound: legs[0], inbound: legs[1], far: b)
        #expect(circuit.reriddenMeters < 1_000)
        #expect(RouteQuality(route: circuit.combined).meaningfulDirtMeters > 30_000)
        #expect(circuit.distanceMeters < 110_000)
        // Replay the rider's Balanced -> Clean return edit separately.
        var out = RoutingRequest(start: a, end: b, style: .balanced, allowUnknown: true, seed: seed)
        out.profile.wander = 0.5; out.access.avoidFerries = true; out.mapZoom = 9.6
        let outbound = try engine.route(out)
        var back = RoutingRequest(start: outbound.end.coordinate, end: a, style: .balanced, seed: seed)
        back.profile.wander = 0.5; back.access.avoidFerries = true; back.mapZoom = 9.6
        back.options.arrivalEdgeID = outbound.endRoadIdentity
        back.options.arrivalRestrictions = outbound.arrivalRestrictions
        back.options.priorEdges = Set(outbound.segments.map(\.edgeID))
        let balanced = try engine.route(back)
        back.profile.style = .cleanest
        back.options.preferredCorridorRoads = Set(balanced.segments.map(\.edgeID))
        let clean = try engine.route(back)
        #expect(clean.distanceMeters < 48_000) // Phone: 56,293 m via Bellafontaine.
        #expect(RouteQuality(route: clean).knownDirtPercent == 0)
        #expect(clean.geometry.allSatisfy { $0.latitude > 44.73 })
    }

}
