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
        let incoming = try RoutingEngine(pack: graph).exactContinuation(route)
        #expect(incoming.edge == 0)
        #expect(incoming.coordinate == route.end.coordinate)
        #expect(incoming.forward == true)
        #expect(abs(incoming.alongMeters - line.distance(0)) < 0.01)
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
            #expect(a.count == 2)
            choices.insert(a.map { String($0.edge) }.joined(separator: ","))
        }
        #expect(choices.count > 1)
    }
}
