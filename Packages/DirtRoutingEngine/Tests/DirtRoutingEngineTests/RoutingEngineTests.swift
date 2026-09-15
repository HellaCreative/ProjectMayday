import Foundation
import Testing
@testable import DirtRoutingEngine

struct RoutingEngineTests {
    /// A straight paved road. Balanced can never land in its 45–55% dirt band here,
    /// so the corridor sequence runs all the way to its final, unbounded width.
    private var request: RoutingRequest {
        .init(start: .init(longitude: 0.001,latitude: 0),end: .init(longitude: 0.059,latitude: 0),style: .balanced)
    }
    private func pavedLine() throws -> IndexedGraph {
        let nodes = (0...6).map { Coordinate(longitude: Double($0)*0.01,latitude: 0) }
        return try IndexedGraph(PolicyTests.Line(nodes: nodes,edges: (0..<6).map { ($0,$0+1) },
            surfaces: Array(repeating: "asphalt",count: 6),roads: Array(repeating: "tertiary",count: 6)))
    }

    @Test func balancedSummaryNamesTheUnboundedCorridorWithoutTrapping() throws {
        let route = try RoutingEngine(pack: pavedLine()).route(request,budget: .init(seconds: 20))
        #expect(route.distanceMeters > 0)
        #expect(route.searchSummary?.contains("∞") == true)
    }

    @Test func counterIncludesEverySearchNotJustTheSelectedRoute() throws {
        var counted = request
        let counter = SearchCounter()
        counted.options.counter = counter
        let route = try RoutingEngine(pack: pavedLine()).route(counted,budget: .init(seconds: 20))
        // At least one shortest-distance search and seven Balanced corridor widths.
        // Endpoint pairs that cannot connect add more: here the first destination
        // match faces the wrong way on a dead-end road and fails before the next pair.
        #expect(counter.searches >= 8)
        #expect(counter.pops > route.poppedLabels)
        #expect(counter.stageSummary.contains("match"))
        #expect(counter.stageSummary.contains("compass"))
    }
}
