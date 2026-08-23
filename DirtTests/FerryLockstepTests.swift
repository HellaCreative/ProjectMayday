import Testing
@testable import Dirt

/// Phase G1 — ferry crossing cost lockstep with scripts/pack-fabric/routing/lib/ferry.js.
struct FerryLockstepTests {
    @Test func ferrySecondsAndStepCostMatchJs() {
        let meters = 18000.0
        let sec = OnDeviceProfileCosts.ferryCrossingSeconds(
            distanceMeters: meters,
            storedSeconds: 0
        )
        #expect(sec == 3600.0)
        let step = OnDeviceProfileCosts.ferryRelaxStepCost(crossingSeconds: sec)
        #expect(step == OnDeviceProfileCosts.ferryCostReferenceKmh)
    }

    @Test func ferryStructureDecode() {
        #expect(GraphV2Pack.isFerryStructure(GraphV2Pack.structureFerry))
        #expect(!GraphV2Pack.isFerryStructure(3))
    }

    @Test func honestSurfaceStatsExcludeFerryDenominator() {
        let rows: [(Double, String?)] = [
            (1000, "asphalt"),
            (500, "n/a")
        ]
        let withFerry = SurfaceFamilyStats.honestPercents(
            rows: rows,
            distanceMeters: 1500,
            familyMap: [:]
        )
        let pavedOnly = SurfaceFamilyStats.honestPercents(
            rows: [(1000, "asphalt")],
            distanceMeters: 1000,
            familyMap: [:]
        )
        #expect(withFerry.pavedPercent == 67)
        #expect(pavedOnly.pavedPercent == 100)
    }
}
