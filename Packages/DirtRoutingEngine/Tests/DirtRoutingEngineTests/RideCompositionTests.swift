import Foundation
import Testing
@testable import DirtRoutingEngine

struct RideCompositionTests {
    @Test func continuationUsesTraversedRoadAtJunctionRatherThanEndMatch() throws {
        let line = PolicyTests.Line(nodes: [.init(longitude: 0, latitude: 0), .init(longitude: 0.01, latitude: 0),
                                           .init(longitude: 0.02, latitude: 0)],
                                    edges: [(0, 1), (1, 2)], surfaces: ["gravel", "gravel"], roads: ["track", "track"])
        let graph = try IndexedGraph(line)
        let start = RoadMatch(edge: 0, coordinate: line.nodes[0], distanceMeters: 0, alongMeters: 0, geometryMeters: line.distance(0))
        let end = RoadMatch(edge: 1, coordinate: line.nodes[1], distanceMeters: 0, alongMeters: 0, geometryMeters: line.distance(1))
        var options = SearchOptions(); options.objective = .distance
        let route = try PathSearch(pack: graph).search(start: start, end: end, policy: .init(style: .dirt), access: .init(), options: options)
        #expect(route.segments.last?.edge == 0)
        #expect(route.end.edge == 1)
        #expect(route.endRoadIdentity == graph.identity(of: 0))
        let incoming = try RoutingEngine(pack: graph).exactContinuation(route)
        #expect(incoming.edge == 0)
        #expect(incoming.coordinate == route.end.coordinate)
        #expect(incoming.forward == true)
        #expect(abs(incoming.alongMeters - line.distance(0)) < 0.01)
    }

    @Test func composedRideRetainsEndpointsAndDoesNotRepeatASection() throws {
        var nodes: [Coordinate] = [], edges: [(Int, Int)] = []
        for y in 0..<9 { for x in 0..<9 { nodes.append(.init(longitude: Double(x) * 0.1, latitude: Double(y) * 0.1)) } }
        for y in 0..<9 { for x in 0..<9 {
            let n = y * 9 + x
            if x < 8 { edges.append((n, n + 1)) }
            if y < 8 { edges.append((n, n + 9)) }
        } }
        let line = PolicyTests.Line(nodes: nodes, edges: edges, surfaces: Array(repeating: "gravel", count: edges.count),
                                    roads: Array(repeating: "track", count: edges.count))
        let engine = RoutingEngine(pack: try IndexedGraph(line))
        var request = RoutingRequest(start: nodes[13], end: nodes[67], style: .dirt, seed: 1)
        request.options.composeDirtRide = true
        let result = try engine.route(request, budget: .init(seconds: 10))
        #expect(result.start.coordinate.distance(to: request.start) < 0.1)
        #expect(result.end.coordinate.distance(to: request.end) < 0.1)
        #expect(result.limit == nil)
        #expect(RouteQuality(route: result).reriddenMeters == 0)
        #expect(RouteQuality(route: result).knownDirtPercent == 100)
        #expect(result.searchSummary?.hasPrefix("composed-dirt") == true)
    }

    @Test func usefulComposedRideBelowSeventyPercentRemainsEligible() throws {
        // Every north/south connection is paved. East/west dirt can make a
        // worthwhile detour, but this finite grid cannot reach 70% without loops.
        var nodes: [Coordinate] = [], edges: [(Int, Int)] = [], surfaces: [String] = []
        for y in 0..<9 { for x in 0..<9 {
            nodes.append(.init(longitude: Double(x) * 0.1, latitude: Double(y) * 0.1))
        } }
        for y in 0..<9 { for x in 0..<9 {
            let n = y * 9 + x
            if x < 8 { edges.append((n, n + 1)); surfaces.append("gravel") }
            if y < 8 { edges.append((n, n + 9)); surfaces.append("asphalt") }
        } }
        let line = PolicyTests.Line(nodes: nodes, edges: edges, surfaces: surfaces,
            roads: surfaces.map { $0 == "gravel" ? "track" : "tertiary" })
        let graph = try IndexedGraph(line), engine = RoutingEngine(pack: graph)
        var request = RoutingRequest(start: nodes[13], end: nodes[67], style: .dirt, seed: 1)
        let ordinary = try engine.route(request, budget: .init(seconds: 10))
        request.options.composeDirtRide = true
        let result = try engine.route(request, budget: .init(seconds: 10))
        let quality = RouteQuality(route: result)
        #expect(result.limit == nil)
        #expect(result.start.coordinate.distance(to: request.start) < 0.1)
        #expect(result.end.coordinate.distance(to: request.end) < 0.1)
        #expect(quality.knownDirtPercent > RouteQuality(route: ordinary).knownDirtPercent)
        #expect(quality.knownDirtPercent < 70)
        #expect(quality.reriddenMeters == 0)
        #expect(!RouteQuality.hasClosedRoadCircuit(result.segments, in: graph))
        #expect(result.searchSummary?.hasPrefix("composed-dirt") == true)
    }

    @Test func seededRidingAreasAreReproducibleAndOfferDifferentDirections() throws {
        var nodes: [Coordinate] = [], edges: [(Int, Int)] = []
        for y in 0..<9 { for x in 0..<9 { nodes.append(.init(longitude: Double(x) * 0.1, latitude: Double(y) * 0.1)) } }
        for y in 0..<9 { for x in 0..<9 {
            let n = y * 9 + x
            if x < 8 { edges.append((n, n + 1)) }
            if y < 8 { edges.append((n, n + 9)) }
        } }
        let line = PolicyTests.Line(nodes: nodes, edges: edges, surfaces: Array(repeating: "gravel", count: edges.count),
                                    roads: Array(repeating: "track", count: edges.count))
        let graph = try IndexedGraph(line), engine = RoutingEngine(pack: graph)
        let startEdge = edges.firstIndex { $0.0 == 13 && $0.1 == 22 }!
        let endEdge = edges.firstIndex { $0.0 == 58 && $0.1 == 67 }!
        let start = RoadMatch(edge: startEdge, coordinate: nodes[13], distanceMeters: 0, alongMeters: 0, geometryMeters: line.distance(startEdge))
        let end = RoadMatch(edge: endEdge, coordinate: nodes[67], distanceMeters: 0, alongMeters: line.distance(endEdge), geometryMeters: line.distance(endEdge))
        var choices = Set<String>()
        for seed in 1...4 {
            let request = RoutingRequest(start: start.coordinate, end: end.coordinate, style: .dirt, seed: UInt64(seed))
            let a = try engine.ridingAreas(request, start: start, end: end, budget: .init())
            let b = try engine.ridingAreas(request, start: start, end: end, budget: .init())
            #expect(a.map(\.edge) == b.map(\.edge))
            #expect((2...6).contains(a.count))
            #expect(Set(a.map(\.edge)).count == a.count)
            choices.insert(a.map { String($0.edge) }.joined(separator: ","))
        }
        #expect(choices.count > 1)
    }
    @Test func closedCircuitUsesJunctionIdentityNotProximity() {
        let nodes: [Coordinate] = [.init(longitude: 0, latitude: 0),
            .init(longitude: 0.1, latitude: 0), .init(longitude: 0.1, latitude: 0.1),
            .init(longitude: 0, latitude: 0.001), .init(longitude: 0, latitude: 0)]
        let graph = PolicyTests.Line(nodes: nodes, edges: [(0,1),(1,2),(2,0),(2,3),(2,4)],
            surfaces: Array(repeating: "gravel", count: 5), roads: Array(repeating: "track", count: 5))
        func section(_ e: Int) -> RouteSegment {
            .init(edge: e, edgeID: graph.edgeID(e), forward: true, meters: graph.distance(e),
                  surface: .gravel, surfaceLeaf: "gravel", roadClass: "track", structure: "",
                  access: 0, geometry: graph.polyline(e))
        }
        #expect(RouteQuality.hasClosedRoadCircuit([section(0),section(1),section(2)], in: graph))
        let nearby = [section(0),section(1),section(3)]
        #expect(RouteQuality.returnMeters(nearby) > 0)
        #expect(!RouteQuality.hasClosedRoadCircuit(nearby, in: graph))
        // A different source node at exactly the same coordinate is not a junction.
        #expect(!RouteQuality.hasClosedRoadCircuit([section(0),section(1),section(4)], in: graph))
    }

    @Test func clippedRoadAndAdjacentSplitDoNotInventVisitedJunctions() {
        let graph = PolicyTests.Line(nodes: [.init(longitude: 0, latitude: 0),.init(longitude: 0.1, latitude: 0)],
            edges: [(0,1)], surfaces: ["gravel"], roads: ["track"])
        func piece(_ from: Double, _ to: Double) -> RouteSegment {
            .init(edge: 0, edgeID: "road", forward: true, meters: (to-from)*111_195,
                surface: .gravel, surfaceLeaf: "gravel", roadClass: "track", structure: "", access: 0,
                geometry: [.init(longitude: from, latitude: 0),.init(longitude: to, latitude: 0)])
        }
        #expect(!RouteQuality.hasClosedRoadCircuit([piece(0,0.05),piece(0.05,0.1)], in: graph))
    }

}
