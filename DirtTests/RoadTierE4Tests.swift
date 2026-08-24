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

    @Test("Clean always prefers back roads; avoid-motorways follows the toggle")
    func cleanIntrinsicPreferBackRoads() {
        let off = RoadTierStats.e4Flags(
            for: .cleanest,
            avoidMotorways: false,
            preferBackRoads: false
        )
        #expect(off.avoidMotorways == false)
        #expect(off.preferBackRoads == true)
        let on = RoadTierStats.e4Flags(
            for: .cleanest,
            avoidMotorways: true,
            preferBackRoads: false
        )
        #expect(on.avoidMotorways == true)
        #expect(on.preferBackRoads == true)
    }
}
