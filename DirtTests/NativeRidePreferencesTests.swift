import CoreLocation
import Foundation
import Testing
@testable import Dirt

@Suite("Native ride preferences", .serialized)
struct NativeRidePreferencesTests {
    @Test func wanderKeepsDirtAndMakesLongerCoherentChoiceAvailable() throws {
        let low = try route("native-preferences-variety", profile: .dirt, preferences: .init(wander: 0))
        let high = try route("native-preferences-variety", profile: .dirt, preferences: .init(wander: 1))
        let clean = try route("native-preferences-variety", profile: .cleanest, preferences: .init(wander: 0))
        #expect(low.dirtPercent >= 40)
        #expect(low.dirtPercent > clean.dirtPercent)
        #expect(high.dirtPercent > low.dirtPercent)
        #expect(high.distanceMeters > low.distanceMeters)
        #expect(low.backtrackMeters == 0)
        #expect(high.backtrackMeters == 0)
    }

    @Test func balancedRetainsItsMixAtBothWanderExtremes() throws {
        for wander in [0.0, 1.0] {
            let result = try route("native-preferences-variety", profile: .balanced, preferences: .init(wander: wander))
            #expect((45...55).contains(result.dirtPercent))
            #expect(result.distanceMeters > 0)
        }
    }

    @Test func explicitDefaultsPreserveAllProfileRoutes() throws {
        for profile: RouteProfile in [.dirt, .balanced, .cleanest] {
            let legacy = try route("native-preferences-variety", profile: profile, preferences: nil)
            let defaults = try route("native-preferences-variety", profile: profile, preferences: .init())
            #expect(legacy.edgeIds == defaults.edgeIds)
            #expect(legacy.distanceMeters == defaults.distanceMeters)
            #expect(legacy.dirtPercent == defaults.dirtPercent)
        }
    }

    @Test func cityAndHighwayControlsChooseExistingLegalAlternative() throws {
        let direct = try route("native-preferences-city", profile: .cleanest,
            preferences: .init(avoidCities: false, avoidHighways: false))
        let cities = try route("native-preferences-city", profile: .cleanest,
            preferences: .init(avoidCities: true, avoidHighways: false))
        let highways = try route("native-preferences-city", profile: .cleanest,
            preferences: .init(avoidCities: false, avoidHighways: true))
        #expect(direct.edgeIds.contains { $0.hasPrefix("w20:") })
        #expect(!cities.edgeIds.contains { $0.hasPrefix("w20:") })
        #expect(!highways.edgeIds.contains { $0.hasPrefix("w20:") })
        #expect(cities.distanceMeters > direct.distanceMeters)
        #expect(highways.distanceMeters > direct.distanceMeters)
        for result in [direct, cities, highways] {
            #expect(result.legs.allSatisfy { $0.accessName == "motorized_verified" })
        }
    }

    @Test func sameParentShortcutCannotBypassCityOrHighwayPreference() throws {
        for preferences in [RidePreferences(), RidePreferences(avoidCities: false, avoidHighways: true)] {
            let result = try route("native-preferences-city", profile: .cleanest,
                preferences: preferences, startID: 2, endID: 3)
            #expect(!result.edgeIds.contains { $0.hasPrefix("w20:") })
            #expect(result.edgeIds.contains { $0.hasPrefix("w30:") })
        }
    }

    @Test func initialFuelApproachIgnoresRecreationalPreferences() throws {
        let plain = try route("native-preferences-variety", profile: .dirt,
            preferences: nil, initialFuelApproach: true)
        let custom = try route("native-preferences-variety", profile: .dirt,
            preferences: .init(preferDifferentRoads: true, wander: 0,
                avoidCities: false, avoidHighways: true), initialFuelApproach: true)
        #expect(plain.edgeIds == custom.edgeIds)
        #expect(plain.distanceMeters == custom.distanceMeters)
        #expect(custom.searchMeta.rideObjective == "initial-fuel-approach")
    }

    @Test func preferenceCostPreservesSurfaceOrderingAndContinuousDistanceCharge() {
        var lastExtra = Double.infinity
        for wander in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let preferences = RidePreferences(wander: wander)
            let dirt = NativeRidePreferenceCosts.edgeCost(base: 0.7, meters: 1_000, roadClass: "unclassified", preferences: preferences)
            let paved = NativeRidePreferenceCosts.edgeCost(base: 150, meters: 1_000, roadClass: "unclassified", preferences: preferences)
            #expect(dirt < paved)
            let extra = NativeRidePreferenceCosts.distancePenalty(preferences)
            #expect(extra < lastExtra)
            lastExtra = extra
        }
    }

    private func route(_ name: String, profile: RouteProfile,
                       preferences: RidePreferences?, initialFuelApproach: Bool = false,
                       startID: Int64 = 1, endID: Int64 = 4) throws -> OnDeviceRouter.Result {
        func fixture(_ suffix: String) throws -> URL {
            let file = name + suffix
            let bundle = Bundle(for: NativeRidePreferencesFixtureBundle.self)
            if let url = bundle.url(forResource: file, withExtension: nil)
                ?? bundle.url(forResource: file, withExtension: nil, subdirectory: "Fixtures") { return url }
            return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/" + file)
        }
        let pack = try GraphV2Pack(data: Data(contentsOf: fixture(".graph.v4.bin")))
        pack.geometry = try GeometryV1Pack(data: Data(contentsOf: fixture(".geometry.v1.bin")))
        let start = try #require(pack.osmNodeIds.firstIndex(of: startID))
        let end = try #require(pack.osmNodeIds.firstIndex(of: endID))
        func coordinate(_ node: Int) -> CLLocationCoordinate2D {
            .init(latitude: Double(pack.nodeCoords[node * 2 + 1]), longitude: Double(pack.nodeCoords[node * 2]))
        }
        var router = try fixtureRouter(pack: pack)
        router.ridePreferences = preferences
        router.initialFuelApproach = initialFuelApproach
        router.recordedStartNode = start
        router.recordedEndNode = end
        switch router.routeDetailed(from: coordinate(start), to: coordinate(end), profile: profile,
                                    allowUnknown: false, sessionSeed: 17) {
        case .success(let result): return result
        case .failure(let failure): throw FixtureFailure.failed("\(profile): \(failure)")
        }
    }
    private enum FixtureFailure: Error { case failed(String) }
}
private final class NativeRidePreferencesFixtureBundle: NSObject {}
