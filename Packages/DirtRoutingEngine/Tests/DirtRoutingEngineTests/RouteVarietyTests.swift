import Foundation
import Testing
@testable import DirtRoutingEngine

struct RouteVarietyTests {
    struct Fork: RoadGraph {
        let nodes: [Coordinate] = [(-0.01,0),(0,0),(0.01,0.005),(0.01,-0.005),(0.02,0),(0.03,0)].map {
            .init(longitude: $0.0,latitude: $0.1)
        }
        let edges = [(0,1),(1,2),(2,4),(1,3),(3,4),(4,5)]
        var blockNorth = false
        var nodeCount: Int { nodes.count }
        var edgeCount: Int { edges.count }
        var urbanCores: [GeographicBox] { [] }
        var restrictionIndex: RestrictionIndex { .init([]) }
        func coordinate(node: Int) -> Coordinate { nodes[node] }
        func outgoing(_ node: Int) -> [RoadArc] {
            edges.enumerated().flatMap { i,e -> [RoadArc] in
                if e.0 == node { return [.init(target: e.1,edge: i,forward: true)] }
                if e.1 == node { return [.init(target: e.0,edge: i,forward: false)] }
                return []
            }
        }
        func endpoint(_ edge: Int,from: Bool) -> Int { from ? edges[edge].0 : edges[edge].1 }
        func restrictionEdge(_ edge: Int) -> Int { edge }
        func edgeID(_ edge: Int) -> String { "fork-\(edge)" }
        func distance(_ edge: Int) -> Double { nodes[edges[edge].0].distance(to: nodes[edges[edge].1]) }
        func attributes(_ edge: Int) -> UInt16 { 0 }
        func crossingTime(_ edge: Int) -> Double { 0 }
        func accessCode(_ edge: Int,forward: Bool) -> UInt8 { blockNorth && (edge == 1 || edge == 2) ? 2 : 0 }
        func surfaceLeaf(_ edge: Int) -> String { "asphalt" }
        func roadClass(_ edge: Int) -> String { "tertiary" }
        func structure(_ edge: Int) -> String { "" }
        func polyline(_ edge: Int) -> [Coordinate] { [nodes[edges[edge].0],nodes[edges[edge].1]] }
        func match(_ edge: Int) -> RoadMatch {
            let line = polyline(edge)
            return .init(edge: edge,coordinate: .init(longitude: (line[0].longitude+line[1].longitude)/2,latitude: 0),
                         distanceMeters: 0,alongMeters: distance(edge)/2,geometryMeters: distance(edge))
        }
    }
    func route(_ graph: Fork,seed: UInt64,objective: SearchObjective = .profile) throws -> ComputedRoute {
        var options = SearchOptions(); options.seed = seed; options.objective = objective
        return try PathSearch(pack: graph).search(start: graph.match(0),end: graph.match(5),
            policy: .init(style: .cleanest),access: .init(),options: options)
    }
    @Test func pinnedSeedsRepeatAndFreshSeedsSelectBothLegalAlternatives() throws {
        let graph = Fork()
        var alternatives: Set<[String]> = []
        for seed in UInt64(0)..<64 {
            let first = try route(graph,seed: seed)
            let second = try route(graph,seed: seed)
            #expect(first.segments.map(\.edgeID) == second.segments.map(\.edgeID))
            #expect(first.geometry == second.geometry)
            alternatives.insert(first.segments.map(\.edgeID))
        }
        #expect(alternatives.count == 2)
    }
    @Test func varietyCannotOpenProhibitedRoads() throws {
        var graph = Fork(); graph.blockNorth = true
        for seed in UInt64(0)..<64 {
            let result = try route(graph,seed: seed)
            #expect(!result.segments.contains { $0.edge == 1 || $0.edge == 2 })
            #expect(result.segments.contains { $0.edge == 3 })
        }
    }
    @Test func distanceProbesRemainIndependentOfSeed() throws {
        let graph = Fork()
        let baseline = try route(graph,seed: 0,objective: .distance)
        for seed in UInt64(1)..<32 {
            let result = try route(graph,seed: seed,objective: .distance)
            #expect(result.segments.map(\.edgeID) == baseline.segments.map(\.edgeID))
            #expect(result.distanceMeters == baseline.distanceMeters)
        }
    }
    @Test func perturbationIsBoundedAndUsesTheWholeSeed() {
        for seed in UInt64(0)..<1000 {
            let value = RouteVariety.multiplier(seed: seed,edgeID: "road")
            #expect(value >= 0.96 && value < 1.04)
        }
        #expect(RouteVariety.multiplier(seed: 1,edgeID: "road") != RouteVariety.multiplier(seed: 1 + (1 << 32),edgeID: "road"))
    }
}
