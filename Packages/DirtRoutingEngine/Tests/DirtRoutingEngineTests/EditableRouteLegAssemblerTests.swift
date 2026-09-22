import Testing
@testable import DirtRoutingEngine

struct EditableRouteLegAssemblerTests {
    private func part(_ graph: UnknownConnectorTests.Graph, from a: Int, to b: Int) throws -> ComputedRoute {
        let start = RoadMatch(edge: a, coordinate: graph.coordinate(node: a), distanceMeters: 0,
            alongMeters: 0, geometryMeters: graph.distance(a), forward: true)
        let end = RoadMatch(edge: b - 1, coordinate: graph.coordinate(node: b), distanceMeters: 0,
            alongMeters: graph.distance(b - 1), geometryMeters: graph.distance(b - 1), forward: true)
        var options = SearchOptions(); options.objective = .distance
        var route = try PathSearch(pack: graph).search(start: start, end: end,
            policy: ProfilePolicy(style: .dirt), access: AccessPolicy(), options: options)
        route.editableBoundaries = try EditableRouteBoundary.proven(in: route, graph: graph)
        return route
    }

    @Test func streamsBeforeFinalAndPreservesEveryRoadAndArrivalIdentity() throws {
        let graph = UnknownConnectorTests.Graph(lengths: Array(repeating: 100, count: 18),
            access: Array(repeating: 0, count: 18))
        let a = try part(graph, from: 0, to: 11), b = try part(graph, from: 11, to: 18)
        var stream = EditableRouteLegAssembler(targetMeters: 800, thresholdMeters: 1000)
        let early = try stream.append(a)
        #expect(early.count == 1)
        #expect(early[0].distanceMeters == 800)
        #expect(early[0].endRoadIdentity == graph.identity(of: 7))
        let later = try stream.append(b)
        let full = try StagedRouter.stitch([a,b], windows: [["a"],["b"]])
        let legs = early + later + (try stream.finish(full))
        #expect(legs.map(\.distanceMeters) == [800,800,200])
        #expect(legs.flatMap(\.segments).map(\.edgeID) == full.segments.map(\.edgeID))
        #expect(legs[0].end.coordinate == legs[1].start.coordinate)
        #expect(legs[1].end.coordinate == legs[2].start.coordinate)
        #expect(legs.last?.end == full.end)
    }

    @Test func shortTailNeverMovesAnAlreadyPublishedPin() throws {
        let graph = UnknownConnectorTests.Graph(lengths: Array(repeating: 100, count: 17),
            access: Array(repeating: 0, count: 17))
        let a = try part(graph, from: 0, to: 16), b = try part(graph, from: 16, to: 17)
        var stream = EditableRouteLegAssembler(targetMeters: 800, thresholdMeters: 1000)
        let first = try stream.append(a)
        #expect(first.map(\.distanceMeters) == [800])
        #expect(try stream.append(b).isEmpty)
        let full = try StagedRouter.stitch([a,b], windows: [["a"],["b"]])
        let final = try stream.finish(full)
        #expect(final.map(\.distanceMeters) == [900])
        #expect(first[0].end.coordinate == final[0].start.coordinate)
    }

    @Test func failedChainMustBeResetBeforeAnotherRouteCanComplete() throws {
        let graph = UnknownConnectorTests.Graph(lengths: Array(repeating: 100, count: 15),
            access: Array(repeating: 0, count: 15))
        var stream = EditableRouteLegAssembler(targetMeters: 800, thresholdMeters: 1000)
        _ = try stream.append(part(graph, from: 0, to: 11))
        #expect(throws: (any Error).self) { try stream.finish(part(graph, from: 0, to: 15)) }
        stream = EditableRouteLegAssembler(targetMeters: 800, thresholdMeters: 1000)
        let legs = try stream.finish(part(graph, from: 0, to: 15))
        #expect(legs.map(\.distanceMeters) == [800,700])
    }

    @Test func belowThresholdIsNotSplitAndUnprovenCutsFailClosed() throws {
        let graph = UnknownConnectorTests.Graph(lengths: [400,500], access: [0,0])
        let full = try part(graph, from: 0, to: 2)
        var stream = EditableRouteLegAssembler(targetMeters: 800, thresholdMeters: 1000)
        #expect(try stream.finish(full).isEmpty)
        var missing = full; missing.editableBoundaries = nil
        var invalid = EditableRouteLegAssembler(targetMeters: 800, thresholdMeters: 1000)
        #expect(throws: (any Error).self) { try invalid.append(missing) }
    }
}
