import CoreLocation
import Foundation
import Testing
@testable import Dirt

/// Lockstep verification: Swift routing engine vs JS find-path-v2.js.
///
/// Every test mirrors a corresponding value or behaviour from the JavaScript
/// routing engine. JS reference values come from running:
///   node --test scripts/pack-fabric/routing/lib/find-path-v2.test.js
/// (all 15 JS tests pass).
///
/// Swift must produce results that match **or exceed** the JS reference at
/// every decision point. For time budgets, "exceed" means Swift gets at least
/// as much wall-clock time; for candidate selection, it means identical ordering.
struct RoutingEngineLockstepTests {

    // MARK: - Constants lockstep (find-path-v2.js lines 271–289)

    @Test func budgetConstantsMatchJS() {
        #expect(HopSearchPolicy.dirtBaseSearchBudgetMs == 3_500)
        #expect(HopSearchPolicy.dirtMaxSearchBudgetMs == 18_000)
        #expect(HopSearchPolicy.balancedBaseSearchBudgetMs == 8_000)
        #expect(HopSearchPolicy.balancedMaxSearchBudgetMs == 45_000)
        #expect(HopSearchPolicy.largeGraphBaseSearchBudgetMs == 12_000)
        #expect(HopSearchPolicy.cleanBaseSearchBudgetMs == 12_000)
        #expect(HopSearchPolicy.cleanMaxSearchBudgetMs == 18_000)
        #expect(HopSearchPolicy.balancedLongRouteMeters == 500_000)
        #expect(HopSearchPolicy.balancedLargeGraphNodes == 500_000)
        #expect(HopSearchPolicy.provinceScaleGraphNodes == 1_500_000)
        #expect(HopSearchPolicy.dirtRecoveryExtraMeters == 40_000)
        #expect(HopSearchPolicy.dirtRecoveryDistanceRatio == 1.5)
    }

    @Test func searchConstantsMatchJS() {
        #expect(HopSearchPolicy.pass2TimeCapSeconds == 18)
        #expect(HopSearchPolicy.pass2PopCap == 400_000)
        #expect(HopSearchPolicy.dirtCandidateTimeCapSeconds == 7)
        #expect(HopSearchPolicy.dirtCandidatePopCap == 200_000)
        #expect(HopSearchPolicy.balancedBuckets == 20)
        #expect(HopSearchPolicy.varietySlots == 3)
        #expect(HopSearchPolicy.varietyMargin == 0.08)
    }

    @Test func corridorConstantsMatchJS() {
        #expect(HopSearchPolicy.dirtCorridorMeters == 60_000)
        #expect(HopSearchPolicy.balancedCorridorMeters == 40_000)
        #expect(HopSearchPolicy.corridorFreeRadiusDirtMeters == 40_000)
        #expect(HopSearchPolicy.corridorFreeRadiusBalancedMeters == 28_000)
        #expect(HopSearchPolicy.corridorRampPerKmDirt == 0.018)
        #expect(HopSearchPolicy.corridorRampPerKmBalanced == 0.035)
    }

    @Test func dirtRideCostConstantsMatchJS() {
        #expect(HopSearchPolicy.dirtRidePavedPerKm == 150)
        #expect(HopSearchPolicy.dirtRideGravelPerKm == 0.7)
        #expect(HopSearchPolicy.dirtRideResourcePerKm == 0.5)
        #expect(HopSearchPolicy.dirtRideUnknownTrackPerKm == 0.9)
        #expect(HopSearchPolicy.minimumEarnedDirtExcursionMeters == 1_000)
        #expect(HopSearchPolicy.insignificantDirtRunMeters == 500)
        #expect(HopSearchPolicy.maximumShortDirtRepairPasses == 3)
    }

    // MARK: - Large graph pressure (find-path-v2.js largeGraphPressure)

    @Test func largeGraphPressureZeroForSmallGraphs() {
        #expect(HopSearchPolicy.largeGraphPressure(nodeCount: 250_000) == 0)
        #expect(HopSearchPolicy.largeGraphPressure(nodeCount: 500_000) == 0)
    }

    @Test func largeGraphPressureScalesLinearly() {
        let mid = HopSearchPolicy.largeGraphPressure(nodeCount: 1_000_000)
        #expect(mid == 0.5)

        let ontario = HopSearchPolicy.largeGraphPressure(nodeCount: 1_470_000)
        #expect(ontario == 0.97)

        let max = HopSearchPolicy.largeGraphPressure(nodeCount: 1_500_000)
        #expect(max == 1.0)

        let beyond = HopSearchPolicy.largeGraphPressure(nodeCount: 2_000_000)
        #expect(beyond == 1.0)
    }

    // MARK: - Adaptive budget
    // JS uses Math.round(ms). Swift returns ceil(ms/1000) in seconds.
    // Swift budget must always be >= JS budget (more search time is better).

    /// JS test: `balancedSearchBudgetMs(250_000, 250_000)` === 8000
    @Test func ordinaryBalancedBudget() {
        let swiftS = HopSearchPolicy.profileSearchBudgetSeconds(
            profile: .balanced, straightLineMeters: 250_000, nodeCount: 250_000
        )
        #expect(swiftS * 1000 >= 8_000, "Swift must give at least 8000ms")
        #expect(swiftS * 1000 <= 9_000, "Swift should not over-allocate")
    }

    /// JS test: `balancedSearchBudgetMs(1_016_620, 1_470_000)` >= 40000 && <= 45000
    @Test func longRouteProvinceGraphBalancedBudget() {
        let swiftS = HopSearchPolicy.balancedSearchBudgetSeconds(
            straightLineMeters: 1_016_620, nodeCount: 1_470_000
        )
        let ms = swiftS * 1000
        #expect(ms >= 40_000, "Ontario-scale budget too low: \(ms)ms")
        #expect(ms <= HopSearchPolicy.balancedMaxSearchBudgetMs)
    }

    /// JS test: small graphs retain established profile budgets.
    @Test func smallGraphsRetainBaseBudgets() {
        let nodes = 250_000
        let dirtS = HopSearchPolicy.profileSearchBudgetSeconds(
            profile: .dirt, straightLineMeters: 67_000, nodeCount: nodes
        )
        let balancedS = HopSearchPolicy.profileSearchBudgetSeconds(
            profile: .balanced, straightLineMeters: 67_000, nodeCount: nodes
        )
        let cleanS = HopSearchPolicy.profileSearchBudgetSeconds(
            profile: .cleanest, straightLineMeters: 67_000, nodeCount: nodes
        )
        // JS: exactly DIRT_BASE (3500). Swift ceil → 4000. Must be >= JS.
        #expect(dirtS * 1000 >= 3_500)
        #expect(dirtS * 1000 <= 4_500)
        // JS: exactly BALANCED_BASE (8000). Swift: 8000 (no rounding needed).
        #expect(balancedS * 1000 >= 8_000)
        #expect(balancedS * 1000 <= 9_000)
        // JS: exactly CLEAN_BASE (12000). Swift: 12000.
        #expect(cleanS * 1000 >= 12_000)
        #expect(cleanS * 1000 <= 13_000)
    }

    /// JS test: province-sized graphs get elevated budgets for short routes.
    @Test func shortRoutesOnProvinceGraphs() {
        let nodes = 1_470_000
        let dirtMs = HopSearchPolicy.profileSearchBudgetSeconds(
            profile: .dirt, straightLineMeters: 67_000, nodeCount: nodes
        ) * 1000
        let balancedMs = HopSearchPolicy.profileSearchBudgetSeconds(
            profile: .balanced, straightLineMeters: 67_000, nodeCount: nodes
        ) * 1000
        let cleanMs = HopSearchPolicy.profileSearchBudgetSeconds(
            profile: .cleanest, straightLineMeters: 67_000, nodeCount: nodes
        ) * 1000

        #expect(dirtMs >= 16_000 && dirtMs <= HopSearchPolicy.dirtMaxSearchBudgetMs,
                "dirt budget: \(dirtMs)ms")
        #expect(balancedMs >= 10_000 && balancedMs <= HopSearchPolicy.largeGraphBaseSearchBudgetMs,
                "balanced budget: \(balancedMs)ms")
        #expect(cleanMs >= HopSearchPolicy.cleanBaseSearchBudgetMs &&
                cleanMs <= HopSearchPolicy.cleanMaxSearchBudgetMs,
                "clean budget: \(cleanMs)ms")
    }

    /// Swift must never give the search less time than JS would.
    @Test func swiftBudgetNeverLessThanJS() {
        let cases: [(RouteProfile, Double, Int)] = [
            (.dirt, 67_000, 250_000),
            (.dirt, 67_000, 1_470_000),
            (.dirt, 500_000, 1_000_000),
            (.balanced, 250_000, 250_000),
            (.balanced, 67_000, 1_470_000),
            (.balanced, 1_016_620, 1_470_000),
            (.balanced, 100_000, 750_000),
            (.cleanest, 67_000, 250_000),
            (.cleanest, 67_000, 1_470_000),
        ]
        for (profile, meters, nodes) in cases {
            let swiftMs = HopSearchPolicy.profileSearchBudgetSeconds(
                profile: profile, straightLineMeters: meters, nodeCount: nodes
            ) * 1000
            let jsBudgetMs = jsProfileSearchBudgetMs(profile, meters, nodes)
            #expect(swiftMs >= jsBudgetMs - 1,
                    "\(profile) m=\(meters) n=\(nodes): Swift \(swiftMs)ms < JS \(jsBudgetMs)ms")
        }
    }

    // MARK: - Pop cap (find-path-v2.js profileSearchPopCap)

    @Test func popCapSmallGraph() {
        let nodes = 250_000
        #expect(HopSearchPolicy.profileSearchPopCap(profile: .dirt, nodeCount: nodes, dirtComparison: true) == 200_000)
        #expect(HopSearchPolicy.profileSearchPopCap(profile: .dirt, nodeCount: nodes) == 400_000)
        #expect(HopSearchPolicy.profileSearchPopCap(profile: .balanced, nodeCount: nodes) == 1_600_000)
    }

    @Test func popCapProvinceGraphScalesUp() {
        let nodes = 1_470_000
        #expect(HopSearchPolicy.profileSearchPopCap(profile: .dirt, nodeCount: nodes, dirtComparison: true) > 200_000)
        #expect(HopSearchPolicy.profileSearchPopCap(profile: .balanced, nodeCount: nodes) > 400_000)
    }

    // MARK: - Corridor multipliers (find-path-v2.js balancedCorridorMultipliers)

    @Test func ordinaryBalancedCorridorMultipliers() {
        #expect(HopSearchPolicy.dynamicBalancedCorridorMultipliers(straightLineMeters: 250_000) ==
                [1, 2, 3, 4, 6, 8])
    }

    @Test func longRouteSkipsSmallestMultiplier() {
        #expect(HopSearchPolicy.dynamicBalancedCorridorMultipliers(straightLineMeters: 1_016_620) ==
                [2, 3, 4, 6, 8])
    }

    @Test func corridorMultiplierBoundary() {
        #expect(HopSearchPolicy.dynamicBalancedCorridorMultipliers(straightLineMeters: 500_000) ==
                [1, 2, 3, 4, 6, 8])
        #expect(HopSearchPolicy.dynamicBalancedCorridorMultipliers(straightLineMeters: 500_001) ==
                [2, 3, 4, 6, 8])
    }

    // MARK: - Dirt recovery path cap (find-path-v2.js dirtRecoveryPathCap)

    @Test func dirtRecoveryPathCapMatchesJS() {
        #expect(HopSearchPolicy.dirtRecoveryPathCap(primaryRideMeters: 51_864) == 91_864)
        #expect(HopSearchPolicy.dirtRecoveryPathCap(primaryRideMeters: 110_275) == 165_412.5)
        #expect(HopSearchPolicy.dirtRecoveryPathCap(primaryRideMeters: 382_484, activePathCap: 382_500) == 382_500)
    }

    // MARK: - Balanced envelope multipliers

    @Test func balancedEnvelopeMultipliers() {
        #expect(HopSearchPolicy.balancedEnvelopeMultipliers == [2, 3, 4, 6, 8, 1])
    }

    // MARK: - Short dirt excursion (find-path-v2.js shortDirtExcursionEdgeIds)

    @Test func subKilometreDirtExcursionRepriced() {
        let edges = OnDeviceRouter.shortDirtExcursionEdgeIDs(in: [
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 2_000, surfaceName: "paved", edgeId: "paved-a"),
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 450, surfaceName: "gravel", edgeId: "gravel-a"),
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 800, surfaceName: "unknown", edgeId: "unknown-a"),
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 500, surfaceName: "track", edgeId: "track-a"),
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 2_000, surfaceName: "paved", edgeId: "paved-b"),
        ])
        #expect(edges.sorted() == ["gravel-a", "track-a", "unknown-a"].sorted())
    }

    @Test func oneKilometreEarnsDiversion() {
        let edges = OnDeviceRouter.shortDirtExcursionEdgeIDs(in: [
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 2_000, surfaceName: "paved", edgeId: "paved-a"),
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 400, surfaceName: "gravel", edgeId: "gravel-a"),
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 800, surfaceName: "unknown", edgeId: "unknown-a"),
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 600, surfaceName: "track", edgeId: "track-a"),
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 2_000, surfaceName: "paved", edgeId: "paved-b"),
        ])
        #expect(edges.isEmpty)
    }

    @Test func unknownSurfaceNeverEarnsKilometre() {
        let edges = OnDeviceRouter.shortDirtExcursionEdgeIDs(in: [
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 2_000, surfaceName: "paved", edgeId: "paved-a"),
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 1_500, surfaceName: "unknown", edgeId: "unknown-a"),
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 2_000, surfaceName: "paved", edgeId: "paved-b"),
        ])
        #expect(edges == Set(["unknown-a"]))
    }

    @Test func routeEndpointDirtEligible() {
        let edges = OnDeviceRouter.shortDirtExcursionEdgeIDs(in: [
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 2_000, surfaceName: "paved", edgeId: "paved-a"),
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 300, surfaceName: "gravel", edgeId: "gravel-a"),
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 300, surfaceName: "track", edgeId: "destination"),
        ])
        #expect(edges.isEmpty)
    }

    // MARK: - V4 access code (via fixture pack)
    // Access code logic is covered by GraphV4PackTests (forecourtPaths,
    // forbiddenForecourt, restrictionTests, etc.) which exercises the same
    // `v4AccessCode` / `v4AccessAllowed` functions against real fixture packs.
    // Those tests verify lockstep with JS `v4TransitionState`.

    @Test func v4AccessAllowedSkipsNonV4() throws {
        let pack = try loadFixturePack("legal-topology-forecourt.graph.v4.bin")
        let allowed = pack.v4AccessAllowed(
            ei: 0, from: 0, to: 1,
            startEi: 0, endEi: 5, allowUnknown: false
        )
        _ = allowed
    }

    // MARK: - Variety / relax (hop-search.js considerRelax)

    @Test func varietyRelaxDeterministic() {
        let first = HopSearchPolicy.considerRelax(
            newCost: 100, oldCost: 100, newEi: 2, oldEi: 1, node: 9,
            newIsDirt: true, oldIsDirt: false, seed: 42, variety: true, slotsUsed: 0
        )
        let second = HopSearchPolicy.considerRelax(
            newCost: 100, oldCost: 100, newEi: 2, oldEi: 1, node: 9,
            newIsDirt: true, oldIsDirt: false, seed: 42, variety: true, slotsUsed: 0
        )
        #expect(first == second)
    }

    @Test func varietySlotsExhausted() {
        let atMax = HopSearchPolicy.considerRelax(
            newCost: 100, oldCost: 100, newEi: 2, oldEi: 1, node: 9,
            newIsDirt: true, oldIsDirt: false, seed: 42, variety: true,
            slotsUsed: HopSearchPolicy.varietySlots
        )
        #expect(atMax == .reject)
    }

    @Test func nonVarietyStrictlyBetter() {
        #expect(HopSearchPolicy.considerRelax(
            newCost: 99, oldCost: 100, newEi: 2, oldEi: 1, node: 9,
            newIsDirt: false, oldIsDirt: false, seed: 0, variety: false, slotsUsed: 0
        ) == .acceptReset)

        #expect(HopSearchPolicy.considerRelax(
            newCost: 101, oldCost: 100, newEi: 2, oldEi: 1, node: 9,
            newIsDirt: false, oldIsDirt: false, seed: 0, variety: false, slotsUsed: 0
        ) == .reject)
    }

    // MARK: - Dirt bucket (hop-search.js dirtBucket)

    @Test func dirtBucketBoundaries() {
        #expect(HopSearchPolicy.dirtBucket(dirtMeters: 0, pathMeters: 1000) == 0)
        #expect(HopSearchPolicy.dirtBucket(dirtMeters: 1000, pathMeters: 1000) == 19)
        #expect(HopSearchPolicy.dirtBucket(dirtMeters: 500, pathMeters: 1000) == 10)
        #expect(HopSearchPolicy.dirtBucket(dirtMeters: 0, pathMeters: 0) == 0)
    }

    // MARK: - Wander scaling (hop-search.js)

    @Test func wanderCorridorScaling() {
        #expect(HopSearchPolicy.wanderCorridorScale(1.0) == 1.0)
        #expect(HopSearchPolicy.wanderCorridorScale(0.0) == 0.45)
        #expect(abs(HopSearchPolicy.wanderCorridorScale(0.5) - 0.725) < 0.001)
    }

    @Test func wanderAwayScaling() {
        #expect(HopSearchPolicy.wanderAwayScale(1.0) == 1.0)
        #expect(HopSearchPolicy.wanderAwayScale(0.0) == 2.15)
    }

    // MARK: - Balanced dirt band

    @Test func balancedDirtBand() {
        #expect(HopSearchPolicy.balancedDirtLo == 0.45)
        #expect(HopSearchPolicy.balancedDirtHi == 0.55)
    }

    // MARK: - Meaningful dirt meters

    @Test func insignificantDirtRunsExcluded() {
        let dip = OnDeviceRouter.meaningfulDirtMeters(in: [
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 2_000, surfaceName: "paved", edgeId: "p1"),
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 400, surfaceName: "gravel", edgeId: "g1"),
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 2_000, surfaceName: "paved", edgeId: "p2"),
        ])
        #expect(dip == 0, "400m gravel dip should not count")

        let earned = OnDeviceRouter.meaningfulDirtMeters(in: [
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 2_000, surfaceName: "paved", edgeId: "p1"),
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 1_200, surfaceName: "track", edgeId: "t1"),
            OnDeviceRouter.Leg(coordinates: [], distanceMeters: 2_000, surfaceName: "paved", edgeId: "p2"),
        ])
        #expect(earned == 1_200, "1200m track should count as meaningful dirt")
    }

    // MARK: - Helpers

    /// Replicate JS `profileSearchBudgetMs` exactly for comparison.
    private func jsProfileSearchBudgetMs(_ profile: RouteProfile, _ straightLineMeters: Double, _ nodeCount: Int) -> Double {
        if profile == .balanced {
            return jsBalancedSearchBudgetMs(straightLineMeters, nodeCount)
        }
        let gp = HopSearchPolicy.largeGraphPressure(nodeCount: nodeCount)
        if profile == .cleanest {
            return (HopSearchPolicy.cleanBaseSearchBudgetMs +
                    (HopSearchPolicy.cleanMaxSearchBudgetMs - HopSearchPolicy.cleanBaseSearchBudgetMs) * gp).rounded()
        }
        return (HopSearchPolicy.dirtBaseSearchBudgetMs +
                (HopSearchPolicy.dirtMaxSearchBudgetMs - HopSearchPolicy.dirtBaseSearchBudgetMs) * gp).rounded()
    }

    private func jsBalancedSearchBudgetMs(_ straightLineMeters: Double, _ nodeCount: Int) -> Double {
        let routeMeters = max(0, straightLineMeters)
        let gp = HopSearchPolicy.largeGraphPressure(nodeCount: nodeCount)
        if gp == 0 { return HopSearchPolicy.balancedBaseSearchBudgetMs }
        let graphFloor = HopSearchPolicy.balancedBaseSearchBudgetMs +
            (HopSearchPolicy.largeGraphBaseSearchBudgetMs - HopSearchPolicy.balancedBaseSearchBudgetMs) * gp
        if routeMeters <= HopSearchPolicy.balancedLongRouteMeters {
            return graphFloor.rounded()
        }
        let routePressure = min(1, (routeMeters - HopSearchPolicy.balancedLongRouteMeters) / 500_000)
        let pressure = min(routePressure, gp)
        let longRouteBudget = HopSearchPolicy.balancedBaseSearchBudgetMs +
            (HopSearchPolicy.balancedMaxSearchBudgetMs - HopSearchPolicy.balancedBaseSearchBudgetMs) * pressure
        return max(graphFloor, longRouteBudget).rounded()
    }

    private func loadFixturePack(_ name: String) throws -> GraphV2Pack {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
        return try GraphV2Pack(data: Data(contentsOf: url))
    }
}
