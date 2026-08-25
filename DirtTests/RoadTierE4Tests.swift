import Foundation
import Testing
@testable import Dirt

@Suite("Phase E4 road preference knobs")
struct RoadTierE4Tests {
    @Test("defaults off leave costs at 1 — Dirt/Balanced baseline unchanged")
    func defaultsOffAreIdentity() {
        #expect(
            RoadTierStats.e4LeafCostMult(
                tier: .motorway,
                avoidMotorways: false,
                preferBackRoads: false,
                metersFromStart: 1e9,
                metersToDestination: 1e9,
                startOnHighway: false,
                endOnHighway: false
            ) == 1
        )
        #expect(
            RoadTierStats.e4PreferBackRoadsMult(tier: .arterial, enabled: false) == 1
        )
    }

    @Test("avoid motorways and prefer back roads are independent")
    func knobsIndependent() {
        let avoidOnly = RoadTierStats.e4LeafCostMult(
            tier: .motorway,
            avoidMotorways: true,
            preferBackRoads: false,
            metersFromStart: 1e9,
            metersToDestination: 1e9,
            startOnHighway: false,
            endOnHighway: false
        )
        let backArterial = RoadTierStats.e4LeafCostMult(
            tier: .arterial,
            avoidMotorways: false,
            preferBackRoads: true,
            metersFromStart: 1e9,
            metersToDestination: 1e9,
            startOnHighway: false,
            endOnHighway: false
        )
        let backMotorway = RoadTierStats.e4LeafCostMult(
            tier: .motorway,
            avoidMotorways: false,
            preferBackRoads: true,
            metersFromStart: 1e9,
            metersToDestination: 1e9,
            startOnHighway: false,
            endOnHighway: false
        )
        #expect(avoidOnly == RoadTierStats.e4AvoidMotorwayMult)
        #expect(backArterial == RoadTierStats.e4PreferBackArterialMult)
        #expect(backMotorway == 1)
        #expect(RoadTierStats.e4PreferBackRoadsMult(tier: .collector, enabled: true) < 1)
        #expect(RoadTierStats.e4PreferBackRoadsMult(tier: .arterial, enabled: true) > 1)
    }

    @Test("prefer back roads never hard-excludes arterial or collector")
    func neverHardExclude() {
        let a = RoadTierStats.e4PreferBackRoadsMult(tier: .arterial, enabled: true)
        let c = RoadTierStats.e4PreferBackRoadsMult(tier: .collector, enabled: true)
        #expect(a.isFinite && a > 0)
        #expect(c.isFinite && c > 0)
    }

    @Test("Dirt/Balanced ignore E4 flags — pre-E4 costing")
    func nonCleanProfilesIgnoreFlags() {
        for profile in [RouteProfile.dirt, .balanced] {
            let flags = RoadTierStats.e4Flags(
                for: profile,
                avoidMotorways: true,
                preferBackRoads: true
            )
            #expect(flags.avoidMotorways == false)
            #expect(flags.preferBackRoads == false)
        }
    }

    @Test("Clean avoids motorway, trunk, and primary when major highways are off")
    func cleanMotorwayPolicy() {
        let off = RoadTierStats.e4Flags(
            for: .cleanest,
            avoidMotorways: false,
            preferBackRoads: false
        )
        #expect(off.avoidMotorways == false)
        #expect(off.preferBackRoads == false)
        let on = RoadTierStats.e4Flags(
            for: .cleanest,
            avoidMotorways: true,
            preferBackRoads: false
        )
        #expect(on.avoidMotorways == true)
        #expect(on.preferBackRoads == false)

        let primary = RoadTierStats.cleanLeafCostMult(tier: .arterial, family: .paved)
        let secondary = RoadTierStats.cleanLeafCostMult(tier: .collector, family: .paved)
        let avoidedPrimary = primary * RoadTierStats.e4LeafCostMult(
            tier: .arterial,
            avoidMotorways: true,
            preferBackRoads: false,
            metersFromStart: 1e9,
            metersToDestination: 1e9,
            startOnHighway: false,
            endOnHighway: false
        )
        let allowedMotorway = RoadTierStats.cleanLeafCostMult(tier: .motorway, family: .paved)
        let avoidedMotorway = allowedMotorway * RoadTierStats.e4LeafCostMult(
            tier: .motorway,
            avoidMotorways: true,
            preferBackRoads: false,
            metersFromStart: 1e9,
            metersToDestination: 1e9,
            startOnHighway: false,
            endOnHighway: false
        )
        #expect(primary == 0.96)
        #expect(secondary == 0.92)
        #expect(avoidedPrimary == primary * 8)
        #expect(allowedMotorway == 1)
        #expect(avoidedMotorway == 40)
    }

    @Test("Clean defaults to major-highway avoidance and Allow removes it")
    func cleanRequestDefaultsAndAllowState() {
        let from = UUID()
        let to = UUID()
        let leg = RiderLeg(
            from: from,
            to: to,
            profile: .cleanest,
            allowUnknown: false
        )
        #expect(leg.avoidMotorways)
        #expect(!leg.preferBackRoads)

        let locations = [
            RouteLocation(latitude: 44.64, longitude: -63.57, label: "A"),
            RouteLocation(latitude: 44.74, longitude: -63.47, label: "B")
        ]
        let defaultRequest = RouteRequest(
            profile: .cleanest,
            locations: locations,
            allowUnknown: false,
            avoidMotorways: true
        )
        #expect(defaultRequest.options?.avoidMotorways == true)
        #expect(defaultRequest.options?.preferBackRoads == nil)

        let allowedRequest = RouteRequest(
            profile: .cleanest,
            locations: locations,
            allowUnknown: false,
            avoidMotorways: false
        )
        #expect(allowedRequest.options == nil)
    }

    @Test("Clean charges once on highway-tier entry and again after leaving")
    func highwayEntryCost() {
        func entry(
            _ from: RoadTier,
            _ to: RoadTier,
            enabled: Bool = true,
            metersToDestination: Double = 1e9,
            endOnHighway: Bool = false
        ) -> Double {
            RoadTierStats.e4MajorHighwayEntryCost(
                fromTier: from,
                toTier: to,
                enabled: enabled,
                metersFromStart: 1e9,
                metersToDestination: metersToDestination,
                startOnHighway: false,
                endOnHighway: endOnHighway
            )
        }

        #expect(entry(.collector, .trunk) == RoadTierStats.e4MajorHighwayEntryCostUnits)
        #expect(entry(.trunk, .motorway) == 0)
        #expect(entry(.motorway, .trunk) == 0)
        #expect(entry(.trunk, .collector) == 0)
        #expect(entry(.collector, .trunk) == RoadTierStats.e4MajorHighwayEntryCostUnits)
        #expect(entry(.collector, .arterial) == 0)
        #expect(entry(.collector, .trunk, enabled: false) == 0)
        #expect(entry(.collector, .trunk, metersToDestination: 1000, endOnHighway: true) == 0)
    }
}
