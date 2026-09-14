import CoreLocation
import Foundation
import Testing
@testable import Dirt

@Suite struct ResourceTraversalUnitsTests {
    @Test func fractionalRoadDistanceUsesSameObjectiveUnitsAsWholeRoad() throws {
        func fixture(_ name: String) -> URL {
            let bundle = Bundle(for: ResourceUnitsFixtureBundle.self)
            return bundle.url(forResource: name, withExtension: nil)
                ?? bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
                ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/" + name)
        }
        let pack = try GraphV2Pack(data: Data(contentsOf: fixture("legal-topology-forecourt.graph.v4.bin")))
        pack.geometry = try GeometryV1Pack(data: Data(contentsOf: fixture("legal-topology-forecourt.geometry.v1.bin")))
        for (start, end) in [(-64.003, -63.997), (-64.0035, -63.9965)] {
            var router = try fixtureRouter(pack: pack)
            router.matchLimitMeters = 30
            let outcome = router.routeDetailed(from: .init(latitude: 45, longitude: start),
                to: .init(latitude: 45, longitude: end), profile: .balanced, allowUnknown: false,
                sessionSeed: 0)
            guard case .success(let route) = outcome else {
                Issue.record("Uniform legal road route failed: \(outcome)")
                continue
            }
            let cost = try #require(route.searchMeta.resourceSelectionCost)
            #expect(route.legs.count >= 3)
            #expect(route.backtrackMeters == 0)
            #expect(route.dirtPercent == 0)
            // On this unrestricted paved fixture, each complete road and each
            // fractional endpoint road has unit distance cost. The prior bug
            // charged fractional geometry 1,000 times more than full edges.
            #expect(abs(cost - route.distanceMeters / 1_000) < 0.01)
        }
    }
}
private final class ResourceUnitsFixtureBundle: NSObject {}
