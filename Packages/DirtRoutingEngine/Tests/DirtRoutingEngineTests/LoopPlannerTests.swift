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

    @Test func aOneWayOutboundCannotBeReversedIntoAnIllegalReturn() throws {
        let nodes = (0...8).map { Coordinate(longitude: Double($0) * 0.01, latitude: 0) }
        let graph = try IndexedGraph(PolicyTests.Line(nodes: nodes,
            edges: (0..<8).map { ($0, $0 + 1) }, surfaces: Array(repeating: "dirt", count: 8),
            roads: Array(repeating: "track", count: 8), reverseAccess: Array(repeating: 2, count: 8)))
        var request = LoopRequest(start: .init(longitude: 0.002, latitude: 0),
            far: .init(longitude: 0.078, latitude: 0), targetMeters: 12_000, style: .dirt)
        request.options.cityWall = false
        var visibleLegs = 0
        #expect(throws: RoutingFailure.noPath) {
            try LoopPlanner(pack: graph).plan(request) { _, _ in visibleLegs += 1 }
        }
        #expect(visibleLegs == 0)
    }

    @Test func aResourceLimitDoesNotMeanThePinIsUnreachable() throws {
        let graph = try parallelRoads()
        var request = LoopRequest(start: .init(longitude: 0.002, latitude: 0.002),
            far: .init(longitude: 0.28, latitude: 0.002), targetMeters: 50_000, style: .dirt)
        request.options.cityWall = false
        do {
            _ = try LoopPlanner(pack: graph).plan(request, budget: .init(seconds: 10, maximumLabels: 1))
            Issue.record("The deliberately exhausted label budget must fail")
        } catch RoutingFailure.resourceLimit { }
    }

    @Test func cancellationFromSelectedProgressDoesNotPublishTheReturn() throws {
        let graph = try parallelRoads()
        var request = LoopRequest(start: .init(longitude: 0.002, latitude: 0.002),
            far: .init(longitude: 0.28, latitude: 0.002), targetMeters: 50_000, style: .dirt)
        request.options.cityWall = false
        var indexes: [Int] = []
        #expect(throws: CancellationError.self) {
            try LoopPlanner(pack: graph).plan(request) { index, _ in
                indexes.append(index)
                throw CancellationError()
            }
        }
        #expect(indexes == [0])
    }

    @Test func observedLoopKeepsRoadsAndProvidesProvableLegsInOrder() throws {
        let graph = try parallelRoads()
        var request = LoopRequest(start: .init(longitude: 0.002, latitude: 0.002),
            far: .init(longitude: 0.28, latitude: 0.002), targetMeters: 50_000, style: .dirt)
        request.options.cityWall = false
        let baseline = try LoopPlanner(pack: graph).plan(request, budget: .init(seconds: 10))
        var indexes: [Int] = []
        let observed = try LoopPlanner(pack: graph).plan(request, budget: .init(seconds: 10)) { index, route in
            indexes.append(index)
            var proven = route
            proven.editableBoundaries = try EditableRouteBoundary.proven(in: route, graph: graph)
            var assembler = EditableRouteLegAssembler(targetMeters: 8_000, thresholdMeters: 10_000)
            let legs = try assembler.finish(proven)
            #expect(legs.count > 1)
            #expect(legs.flatMap(\.segments).map(\.edgeID) == route.segments.map(\.edgeID))
        }
        #expect(indexes == [0, 1])
        #expect(observed.segments.map(\.edgeID) == baseline.segments.map(\.edgeID))
        #expect(observed.distanceMeters == baseline.distanceMeters)
    }

    @Test func aLoopToAFarPinReturnsStartFarStart() throws {
        let graph = try parallelRoads()
        let start = Coordinate(longitude: 0.002, latitude: 0.002)
        let far = Coordinate(longitude: 0.28, latitude: 0.002)
        var request = LoopRequest(start: start, far: far, targetMeters: 50_000, style: .dirt)
        request.options.cityWall = false
        let result = try LoopPlanner(pack: graph).plan(request, budget: .init(seconds: 10))
        #expect(result.outbound.start.coordinate.distance(to: start) < 500)
        #expect(result.outbound.end.coordinate.distance(to: far) < 500)
        #expect(result.inbound.end.coordinate.distance(to: start) < 500)
        #expect(result.far.longitude == far.longitude)
        #expect(result.outbound.distanceMeters > 1_000)
        #expect(result.inbound.distanceMeters > 1_000)
    }

    @Test func returnPrefersTheOtherRoadWhenOneExists() throws {
        let graph = try parallelRoads()
        let start = Coordinate(longitude: 0.002, latitude: 0.002)
        let far = Coordinate(longitude: 0.28, latitude: 0.002)
        var request = LoopRequest(start: start, far: far, targetMeters: 50_000, style: .dirt)
        request.options.cityWall = false
        let result = try LoopPlanner(pack: graph).plan(request, budget: .init(seconds: 10))
        let quality = RouteQuality(route: result.combined)
        #expect(quality.reriddenMeters < result.outbound.distanceMeters * 0.2)
        let outboundIDs = Set(result.outbound.segments.map(\.edgeID))
        let inboundReuse = result.inbound.segments.filter { outboundIDs.contains($0.edgeID) }.reduce(0.0) { $0 + $1.meters }
        #expect(inboundReuse < result.inbound.distanceMeters * 0.5)
    }

    @Test func aDeadEndPinReturnsAnOutAndBackWithRepeatedDistance() throws {
        let nodes = (0...8).map { Coordinate(longitude: Double($0) * 0.01, latitude: 0) }
        let graph = try IndexedGraph(PolicyTests.Line(
            nodes: nodes, edges: (0..<8).map { ($0, $0 + 1) },
            surfaces: Array(repeating: "dirt", count: 8),
            roads: Array(repeating: "track", count: 8)))
        var request = LoopRequest(start: .init(longitude: 0.002, latitude: 0),
                                  far: .init(longitude: 0.078, latitude: 0),
                                  targetMeters: 12_000, style: .dirt)
        request.options.cityWall = false
        let result = try LoopPlanner(pack: graph).plan(request, budget: .init(seconds: 10))
        let quality = RouteQuality(route: result.combined)
        #expect(quality.reriddenMeters > 1_000)
        #expect(result.reriddenMeters == quality.reriddenMeters)
    }

    @Test func aLargerDistanceTargetOpensWanderAndStillReachesThePin() throws {
        let hops = 12
        var direct: [Coordinate] = []
        var scenic: [Coordinate] = []
        for i in 0...hops {
            direct.append(.init(longitude: Double(i) * 0.01, latitude: 0))
            scenic.append(.init(longitude: Double(i) * 0.01, latitude: 0.11))
        }
        let nodes = direct + scenic
        var edges: [(Int, Int)] = []
        var surfaces: [String] = []
        var roads: [String] = []
        func add(_ a: Int, _ b: Int, surface: String, road: String) {
            edges.append((a, b)); surfaces.append(surface); roads.append(road)
        }
        for i in 0..<hops {
            add(i, i + 1, surface: "asphalt", road: "tertiary")
            add(hops + 1 + i, hops + 2 + i, surface: "dirt", road: "track")
        }
        add(0, hops + 1, surface: "dirt", road: "track")
        add(hops, 2 * (hops + 1) - 1, surface: "dirt", road: "track")
        let graph = try IndexedGraph(PolicyTests.Line(nodes: nodes, edges: edges, surfaces: surfaces, roads: roads))
        let start = Coordinate(longitude: 0.002, latitude: 0)
        let far = Coordinate(longitude: 0.118, latitude: 0)
        var tight = LoopRequest(start: start, far: far, targetMeters: 20_000, style: .dirt)
        tight.options.cityWall = false
        var wide = LoopRequest(start: start, far: far, targetMeters: 120_000, style: .dirt)
        wide.options.cityWall = false
        let short = try LoopPlanner(pack: graph).plan(tight, budget: .init(seconds: 10))
        let long = try LoopPlanner(pack: graph).plan(wide, budget: .init(seconds: 10))
        #expect(short.outbound.end.coordinate.distance(to: far) < 500)
        #expect(long.outbound.end.coordinate.distance(to: far) < 500)
        let planner = LoopPlanner(pack: graph)
        #expect(planner.aimedWander(start: start, far: far, target: 120_000)
                > planner.aimedWander(start: start, far: far, target: 20_000) + 0.4)
        #expect(long.distanceMeters >= short.distanceMeters)
    }

    @Test func anOffNetworkFarPinFailsInTermsOfThePin() throws {
        let graph = try parallelRoads(hops: 4)
        var request = LoopRequest(start: .init(longitude: 0.002, latitude: 0.002),
                                  far: .init(longitude: 10, latitude: 10),
                                  targetMeters: 20_000, style: .dirt)
        request.options.cityWall = false
        #expect(throws: LoopFailure.pinUnreachable) {
            try LoopPlanner(pack: graph).plan(request, budget: .init(seconds: 10))
        }
    }

    @Test func loopGeometryNeverGoesPastTheFarPinExtent() throws {
        let graph = try parallelRoads(hops: 30)
        let start = Coordinate(longitude: 0.002, latitude: 0.002)
        let far = Coordinate(longitude: 0.28, latitude: 0.002)
        // Maximum target opens full wander, the case most likely to send the
        // search past the pin if the extent were not enforced.
        var request = LoopRequest(start: start, far: far, targetMeters: 200_000, style: .dirt)
        request.options.cityWall = false
        let result = try LoopPlanner(pack: graph).plan(request, budget: .init(seconds: 10))
        let allowed = start.distance(to: far) + LoopPlanner.extentToleranceMeters
        for point in result.outbound.geometry {
            #expect(start.distance(to: point) <= allowed + 1)
        }
        for point in result.inbound.geometry {
            #expect(start.distance(to: point) <= allowed + 1)
        }
    }

    @Test func extentCenterRejectsTheOnlyRoadPastItAndInfinityDoesNotChangeIt() throws {
        // A single line 0->1->2->3: reaching node 3 must pass through node 2,
        // which is the arc under test.
        let nodes = (0...3).map { Coordinate(longitude: Double($0) * 0.01, latitude: 0) }
        let graph = try IndexedGraph(PolicyTests.Line(
            nodes: nodes, edges: [(0, 1), (1, 2), (2, 3)],
            surfaces: Array(repeating: "asphalt", count: 3),
            roads: Array(repeating: "tertiary", count: 3)))
        let span = nodes[0].distance(to: nodes[1])
        let start = RoadMatch(edge: 0, coordinate: nodes[0], distanceMeters: 0, alongMeters: 0, geometryMeters: span, forward: true)
        let end = RoadMatch(edge: 2, coordinate: nodes[3], distanceMeters: 0, alongMeters: span, geometryMeters: span, forward: true)
        var options = SearchOptions()
        options.cityWall = false
        options.extentCenter = nodes[0]
        // Node 2 sits at 2x the first hop from node 0; a radius under that must
        // reject the only road there and fail the search.
        options.maxExtentMeters = span * 1.4
        #expect(throws: RoutingFailure.self) {
            try PathSearch(pack: graph).search(start: start, end: end, policy: .init(style: .dirt),
                                               access: .init(), options: options, budget: .init())
        }
        // A generous radius (or no cap at all) leaves the same road reachable.
        options.maxExtentMeters = span * 2.5
        let widened = try PathSearch(pack: graph).search(start: start, end: end, policy: .init(style: .dirt),
                                                         access: .init(), options: options, budget: .init())
        #expect(widened.end.coordinate.distance(to: nodes[3]) < 10)
        var uncapped = options
        uncapped.extentCenter = nil
        let unbounded = try PathSearch(pack: graph).search(start: start, end: end, policy: .init(style: .dirt),
                                                           access: .init(), options: uncapped, budget: .init())
        #expect(unbounded.segments.map(\.edgeID) == widened.segments.map(\.edgeID))
    }

    @Test func ordinaryABSearchIsUnchangedWhenRepeatEdgesAreEmpty() throws {
        let graph = try parallelRoads(hops: 8)
        let start = RoadMatch(edge: 0, coordinate: .init(longitude: 0.002, latitude: 0.002), distanceMeters: 0,
                              alongMeters: 1, geometryMeters: 1_112, forward: true)
        let end = RoadMatch(edge: 14, coordinate: .init(longitude: 0.078, latitude: 0.002), distanceMeters: 0,
                              alongMeters: 1_000, geometryMeters: 1_112, forward: true)
        var options = SearchOptions()
        options.cityWall = false
        let baseline = try PathSearch(pack: graph).search(start: start, end: end, policy: .init(style: .dirt),
                                                          access: .init(), options: options, budget: .init())
        let again = try PathSearch(pack: graph).search(start: start, end: end, policy: .init(style: .dirt),
                                                       access: .init(), options: options, budget: .init())
        #expect(baseline.segments.map(\.edgeID) == again.segments.map(\.edgeID))
        #expect(options.repeatEdges.isEmpty)
    }
}
