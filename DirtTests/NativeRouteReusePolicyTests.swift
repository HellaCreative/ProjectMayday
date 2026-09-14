import CoreLocation
import Foundation
import Testing
@testable import Dirt

struct NativeRouteReusePolicyTests {
    private func completedFixture() throws -> OnDeviceRouter.Result {
        let prefix = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/native-preferences-city")
        let pack = try GraphV2Pack(data: Data(contentsOf: URL(fileURLWithPath: prefix.path + ".graph.v4.bin")))
        pack.geometry = try GeometryV1Pack(data: Data(contentsOf: URL(fileURLWithPath: prefix.path + ".geometry.v1.bin")))
        var router = try fixtureRouter(pack: pack)
        let start = try #require(pack.osmNodeIds.firstIndex(of: 1))
        let end = try #require(pack.osmNodeIds.firstIndex(of: 4))
        router.recordedStartNode = start; router.recordedEndNode = end
        func point(_ n: Int) -> CLLocationCoordinate2D {
            .init(latitude: Double(pack.nodeCoords[n * 2 + 1]), longitude: Double(pack.nodeCoords[n * 2]))
        }
        router.dirtResourceCandidatePopCapOverride = 0
        let outcome = router.routeDetailed(from: point(start), to: point(end), profile: .dirt,
            allowUnknown: false, sessionSeed: 17)
        guard case .success(let route) = outcome else { throw FixtureError.failed }
        return route
    }

    @Test func realCompletedIncumbentKeepsItsUnfinishedComparisonDisclosure() throws {
        let route = try completedFixture()
        #expect(route.searchMeta.timedOut)
        #expect(route.searchMeta.pass2Outcome == "completed")
        #expect(route.searchMeta.selectionLimitedOutcomes?.contains("popCap") == true)
        #expect(NativeRouteReusePolicy.canReuse(.success(route)))
        // Storage must preserve the result rather than clear the timedOut flag.
        // The integrated owner replay exercises actual GraphPackStore cache hits.
        let retained = route
        let response = RouteResponse(onDevice: retained, priorEdgeIDs: [])
        #expect(retained.searchMeta == route.searchMeta)
        #expect(response.debug?.searchMeta?.selectionLimitedOutcomes == route.searchMeta.selectionLimitedOutcomes)
        #expect(response.warnings?.contains { $0.code == "route_search_limited" } == true)
        #expect(retained.edgeIds == route.edgeIds)
    }

    @Test func failedSelectedOrDataIncompleteSearchesRemainRetryable() throws {
        let route = try completedFixture()
        for reason in ["timeCap", "popCap", "labelMemoryCap"] {
            var incomplete = route
            incomplete.searchMeta.pass2Outcome = reason
            #expect(!NativeRouteReusePolicy.canReuse(.success(incomplete)))
        }
        for reason in ["cancelled", "geometryUnavailable", "routingDataUnavailable", "routingPackUnavailable", "unknownLimit"] {
            var incomplete = route
            incomplete.searchMeta.selectionLimitedOutcomes = [reason]
            #expect(!NativeRouteReusePolicy.canReuse(.success(incomplete)))
            #expect(!NativeRouteReusePolicy.canReuse(.failure(.searchLimit(reason))))
        }
        for failure: OnDeviceRouter.Failure in [.cannotSnapStart, .cannotSnapEnd, .identicalEnds] {
            #expect(!NativeRouteReusePolicy.canReuse(.failure(failure)))
        }
        #expect(NativeRouteReusePolicy.canReuse(.failure(.noPath)),
            "A completed absence proof retains existing reuse behavior")
        var undisclosed = route
        undisclosed.searchMeta.selectionLimitedOutcomes = nil
        #expect(!NativeRouteReusePolicy.canReuse(.success(undisclosed)))
        var empty = route
        empty.coordinates = []
        #expect(!NativeRouteReusePolicy.canReuse(.success(empty)))
    }
    private enum FixtureError: Error { case failed }
}
