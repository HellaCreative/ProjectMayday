import CoreLocation
import Foundation
import Testing
@testable import Dirt

@Suite("Native selection limit metadata", .serialized)
struct NativeSelectionSearchAuditTests {
    @Test func completedWinnerRetainsDiscardedResourceLimitWithoutChangingRoute() throws {
        let prefix = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/native-preferences-city")
        let pack = try GraphV2Pack(data: Data(contentsOf: URL(fileURLWithPath: prefix.path+".graph.v4.bin")))
        pack.geometry = try GeometryV1Pack(data: Data(contentsOf: URL(fileURLWithPath: prefix.path+".geometry.v1.bin")))
        var router = try fixtureRouter(pack: pack)
        let start = try #require(pack.osmNodeIds.firstIndex(of: 1))
        let end = try #require(pack.osmNodeIds.firstIndex(of: 4))
        router.recordedStartNode = start
        router.recordedEndNode = end
        func point(_ n: Int) -> CLLocationCoordinate2D {
            .init(latitude: Double(pack.nodeCoords[n*2+1]),longitude: Double(pack.nodeCoords[n*2]))
        }
        func calculate(_ router: OnDeviceRouter) throws -> OnDeviceRouter.Result {
            let outcome = router.routeDetailed(from: point(start),to: point(end),profile: .dirt,
                allowUnknown: false,sessionSeed: 17)
            guard case .success(let route) = outcome else { throw FixtureError.failed }
            return route
        }
        let reference = try calculate(router)
        var incompleteAlternative = reference
        incompleteAlternative.searchMeta.timedOut = true
        incompleteAlternative.searchMeta.pass2Outcome = "timeCap"
        var audit = NativeSelectionSearchAudit()
        audit.record(.success(incompleteAlternative))
        audit.record(.success(reference))
        var winnerMeta = reference.searchMeta
        audit.apply(to: &winnerMeta)
        #expect(winnerMeta.timedOut)
        #expect(winnerMeta.selectionLimitedOutcomes == ["timeCap"])
        #expect(winnerMeta.pops == reference.searchMeta.pops)
        #expect(winnerMeta.elapsedMs == reference.searchMeta.elapsedMs)
        router.dirtResourceCandidatePopCapOverride = 0
        let limited = try calculate(router)
        #expect(limited.coordinates.map(\.latitude) == reference.coordinates.map(\.latitude))
        #expect(limited.coordinates.map(\.longitude) == reference.coordinates.map(\.longitude))
        #expect(limited.edgeIds == reference.edgeIds)
        #expect(limited.distanceMeters == reference.distanceMeters)
        #expect(limited.searchMeta.pops == reference.searchMeta.pops)
        #expect(limited.searchMeta.pass2Outcome == "completed")
        #expect(limited.searchMeta.timedOut)
        #expect(limited.searchMeta.selectionLimitedOutcomes?.contains("popCap") == true)
        #expect((limited.searchMeta.selectionAttempts ?? 0) >= 3)
        #expect((limited.searchMeta.calculationElapsedMs ?? -1) >= limited.searchMeta.elapsedMs)
        #expect(limited.searchMeta.limitedSearchWarning?.code == "route_search_limited")
        let debug = limited.searchMeta.responseDebug
        let decoded = try JSONDecoder().decode(RouteResponseDebug.self,from: JSONEncoder().encode(debug))
        #expect(decoded.searchMeta?.selectionLimitedOutcomes == limited.searchMeta.selectionLimitedOutcomes)
        #expect(decoded.searchMeta?.calculationElapsedMs == limited.searchMeta.calculationElapsedMs)
        #expect(decoded.searchMs == limited.searchMeta.elapsedMs)
    }

    @Test func negativeAndMatchingFailuresDoNotBecomeSearchLimits() {
        var audit = NativeSelectionSearchAudit()
        for failure: OnDeviceRouter.Failure in [.noPath,.cannotSnapStart,.cannotSnapEnd,.identicalEnds] {
            audit.record(.failure(failure))
        }
        var meta = OnDeviceRouter.SearchMeta(pops: 31,elapsedMs: 5)
        audit.apply(to: &meta)
        #expect(!meta.timedOut)
        #expect(meta.selectionAttempts == 4)
        #expect(meta.selectionLimitedOutcomes?.isEmpty == true)
        #expect(meta.pops == 31 && meta.elapsedMs == 5)
        audit.record(.failure(.searchLimit("labelMemoryCap")))
        audit.apply(to: &meta)
        #expect(meta.timedOut)
        #expect(meta.selectionLimitedOutcomes == ["labelMemoryCap"])
        #expect(meta.pops == 31 && meta.elapsedMs == 5)
    }
    @Test func alternativeDataFailureRetainsReasonWithoutClaimingAResourceLimit() {
        var audit = NativeSelectionSearchAudit()
        audit.record(.failure(.searchLimit("geometryUnavailable")))
        var meta = OnDeviceRouter.SearchMeta(pass2Outcome: "completed",pops: 7,elapsedMs: 1)
        audit.apply(to: &meta)
        #expect(meta.timedOut)
        #expect(meta.selectionLimitedOutcomes == ["geometryUnavailable"])
        #expect(meta.pass2Outcome == "completed")
        #expect(meta.pops == 7 && meta.elapsedMs == 1)
        #expect(meta.limitedSearchWarning?.code == "route_search_limited")
        #expect(meta.limitedSearchWarning?.message == "Route found. Comparison of riding alternatives could not finish.")
        #expect(meta.responseDebug.searchMeta?.selectionLimitedOutcomes == ["geometryUnavailable"])
    }

    private enum FixtureError: Error { case failed }
}
