import Foundation
import Testing
@testable import DirtRoutingEngine

struct UnknownConnectorTests {
    struct Graph: RoadGraph {
        let lengths: [Double]
        let access: [UInt8]
        var restrictions: [TurnRestriction] = []
        var wayIDs: [Int64] = []
        var nodeCount: Int { lengths.count + 1 }
        var edgeCount: Int { lengths.count }
        var urbanCores: [GeographicBox] { [] }
        var restrictionIndex: RestrictionIndex { .init(restrictions) }
        func coordinate(node: Int) -> Coordinate { .init(longitude: lengths.prefix(node).reduce(0,+) / 111_195, latitude: 0) }
        func outgoing(_ node: Int) -> [RoadArc] {
            var arcs: [RoadArc] = []
            if node > 0 { arcs.append(.init(target: node-1, edge: node-1, forward: false)) }
            if node < edgeCount { arcs.append(.init(target: node+1, edge: node, forward: true)) }
            return arcs
        }
        func endpoint(_ edge: Int, from: Bool) -> Int { from ? edge : edge+1 }
        func restrictionEdge(_ edge: Int) -> Int { edge }
        func edgeID(_ edge: Int) -> String { "connector-\(edge)" }
        func osmWayID(_ edge: Int) -> Int64 { wayIDs.isEmpty ? Int64(edge) : wayIDs[edge] }
        func distance(_ edge: Int) -> Double { lengths[edge] }
        func attributes(_ edge: Int) -> UInt16 { 0 }
        func crossingTime(_ edge: Int) -> Double { 0 }
        func accessCode(_ edge: Int, forward: Bool) -> UInt8 { access[edge] }
        func surfaceLeaf(_ edge: Int) -> String { "gravel" }
        func roadClass(_ edge: Int) -> String { "track" }
        func structure(_ edge: Int) -> String { "" }
        func polyline(_ edge: Int) -> [Coordinate] { [coordinate(node: edge), coordinate(node: edge+1)] }
    }

    func route(_ lengths: [Double], _ codes: [UInt8], unknown: Bool = false,
               style: RidingStyle = .dirt) throws -> ComputedRoute {
        let graph = Graph(lengths: lengths, access: codes)
        let start = RoadMatch(edge: 0, coordinate: graph.coordinate(node: 0), distanceMeters: 0,
                              alongMeters: 0, geometryMeters: lengths[0], forward: true)
        let e = graph.edgeCount-1
        let end = RoadMatch(edge: e, coordinate: graph.coordinate(node: e+1), distanceMeters: 0,
                            alongMeters: lengths[e], geometryMeters: lengths[e], forward: true)
        var options = SearchOptions(); options.objective = .distance
        return try PathSearch(pack: graph).search(start: start, end: end, policy: .init(style: style),
                                                  access: .init(allowUnknown: unknown), options: options)
    }

    @Test func offAllowsAtMostOneHundredContinuousMetersBetweenPermittedRoads() throws {
        let ride = try route([100, 40, 60, 100], [0, 1, 1, 0])
        #expect(ride.segments.filter { $0.access == 1 }.reduce(0) { $0+$1.meters } == 100)
        #expect(throws: RoutingFailure.noPath) { try route([100, 40, 61, 100], [0, 1, 1, 0]) }
        #expect(throws: RoutingFailure.noPath) { try route([100, 80, 80, 80, 100], [0, 1, 1, 1, 0]) }
    }

    @Test func zeroLengthPermittedPieceDoesNotResetContinuousAllowance() {
        #expect(throws: RoutingFailure.noPath) { try route([100, 60, 0, 60, 100], [0, 1, 0, 1, 0]) }
    }

    @Test func onAllowsLongerUnknownButNeverExplicitDenialOrClosure() throws {
        #expect(try route([100, 900, 100], [0, 1, 0], unknown: true).distanceMeters == 1100)
        for unknown in [false, true] {
            for denied: UInt8 in [2, 5] {
                #expect(throws: RoutingFailure.noPath) { try route([100, 20, 100], [0, denied, 0], unknown: unknown) }
            }
        }
    }

    @Test func offCannotStartOrFinishInsideUnknownAccess() {
        #expect(throws: RoutingFailure.noPath) { try route([20, 100], [1, 0]) }
        #expect(throws: RoutingFailure.noPath) { try route([100, 20], [0, 1]) }
    }

    @Test func cleanStillExcludesUnknownAccess() {
        #expect(throws: RoutingFailure.noPath) { try route([100, 20, 100], [0, 1, 0], style: .cleanest) }
    }
}
