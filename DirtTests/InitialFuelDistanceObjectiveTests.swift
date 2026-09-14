import CoreLocation
import Foundation
import Testing
@testable import Dirt

@Suite struct InitialFuelDistanceObjectiveTests {
    @Test func initialApproachCrossesTownOnShortRoadWhileRecreationalCleanAvoidsIt() throws {
        for profile: RouteProfile in [.dirt, .balanced, .cleanest] {
            let result = try route("urban", profile: profile, initial: true)
            #expect(ways(result).contains("w20"))
            #expect(!ways(result).contains("w30"))
            #expect(result.distanceMeters < 3_500)
            #expect(result.searchMeta.rideObjective == "initial-fuel-approach")
            #expect(!result.searchMeta.urbanCoreFallbackUsed)
        }
        let recreation = try route("urban", profile: .cleanest, initial: false)
        #expect(ways(recreation).contains("w30"))
        #expect(!ways(recreation).contains("w20"))
    }

    @Test func initialApproachDoesNotPenalizePreviouslyUsedShortRoad() throws {
        for profile: RouteProfile in [.dirt, .balanced, .cleanest] {
            let initial = try route("plain", profile: profile, initial: true, priorShortRoad: true)
            #expect(ways(initial).contains("w20"))
            #expect(initial.distanceMeters < 3_500)
        }
        let recreation = try route("plain", profile: .cleanest, initial: false, priorShortRoad: true)
        #expect(ways(recreation).contains("w30"))
    }

    @Test func fullAndFractionalFerryApproachesUseDistanceInsteadOfCrossingTime() throws {
        for start in [-0.005, 0.005] {
            let result = try route("ferry", profile: .balanced, initial: true, start: start)
            #expect(ways(result).contains("w20"))
            #expect(!ways(result).contains("w30"))
            #expect(result.legs.contains { $0.structureType == "ferry" })
            #expect(result.distanceMeters < (start < 0 ? 3_500 : 2_300))
        }
    }

    @Test func shortestApproachStillRespectsExplicitDenialAndTurnRestrictions() throws {
        for variant in ["denied", "turn"] {
            for profile: RouteProfile in [.dirt, .balanced, .cleanest] {
                let result = try route(variant, profile: profile, initial: true)
                #expect(ways(result).contains("w30"))
                #expect(!ways(result).contains("w20"))
            }
        }
    }

    private func ways(_ result: OnDeviceRouter.Result) -> Set<String> {
        Set(result.edgeIds.map { String($0.split(separator: ":")[0]) })
    }
    private func route(_ variant: String, profile: RouteProfile, initial: Bool,
                       priorShortRoad: Bool = false, start: Double = -0.005) throws -> OnDeviceRouter.Result {
        func url(_ suffix: String) -> URL {
            let file = "initial-distance-" + variant + suffix
            let bundle = Bundle(for: InitialFuelDistanceObjectiveBundle.self)
            return bundle.url(forResource: file, withExtension: nil)
                ?? bundle.url(forResource: file, withExtension: nil, subdirectory: "Fixtures")
                ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/" + file)
        }
        let pack = try GraphV2Pack(data: Data(contentsOf: url(".graph.v4.bin")))
        pack.geometry = try GeometryV1Pack(data: Data(contentsOf: url(".geometry.v1.bin")))
        var router = try fixtureRouter(pack: pack)
        router.initialFuelApproach = initial
        router.matchLimitMeters = 20
        router.endEndpointKind = "customers"
        router.ridePreferences = RidePreferences(wander: 0, avoidCities: true, avoidHighways: true)
        let prior = Set((0..<pack.undirectedEdgeCount).map { pack.edgeId($0) }.filter { $0.hasPrefix("w20:") })
        let outcome = router.routeDetailed(from: .init(latitude: 0, longitude: start),
            to: .init(latitude: 0, longitude: 0.025), profile: profile, allowUnknown: true,
            priorEdgeIds: priorShortRoad ? prior : [], backtrackFactor: 100, sessionSeed: 0,
            maxRouteMeters: 20_000, cleanMetroMultiplier: 100,
            avoidMotorways: true, preferBackRoads: true)
        guard case .success(let result) = outcome else { throw FixtureError.failed("\(outcome)") }
        return result
    }
    private enum FixtureError: Error { case failed(String) }
}
private final class InitialFuelDistanceObjectiveBundle: NSObject {}
