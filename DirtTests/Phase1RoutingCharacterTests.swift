import CoreLocation
import Foundation
import Testing
@testable import Dirt

struct Phase1RoutingCharacterTests {
    @Test func insignificantDirtRunsDoNotCountTowardDirtPercent() {
        let dip = OnDeviceRouter.meaningfulDirtMeters(in: [
            OnDeviceRouter.Leg(
                coordinates: [], distanceMeters: 2_000, surfaceName: "paved", edgeId: "p1"
            ),
            OnDeviceRouter.Leg(
                coordinates: [], distanceMeters: 400, surfaceName: "gravel", edgeId: "g1"
            ),
            OnDeviceRouter.Leg(
                coordinates: [], distanceMeters: 2_000, surfaceName: "paved", edgeId: "p2"
            )
        ])
        let earned = OnDeviceRouter.meaningfulDirtMeters(in: [
            OnDeviceRouter.Leg(
                coordinates: [], distanceMeters: 2_000, surfaceName: "paved", edgeId: "p1"
            ),
            OnDeviceRouter.Leg(
                coordinates: [], distanceMeters: 1_200, surfaceName: "track", edgeId: "t1"
            ),
            OnDeviceRouter.Leg(
                coordinates: [], distanceMeters: 2_000, surfaceName: "paved", edgeId: "p2"
            )
        ])
        #expect(dip == 0)
        #expect(earned == 1_200)
    }

    @Test func pavedBoundedSubKilometreDirtIsRepriced() {
        let edges = OnDeviceRouter.shortDirtExcursionEdgeIDs(in: [
            OnDeviceRouter.Leg(
                coordinates: [], distanceMeters: 2_000, surfaceName: "paved", edgeId: "paved-a"
            ),
            OnDeviceRouter.Leg(
                coordinates: [], distanceMeters: 400, surfaceName: "gravel", edgeId: "gravel-a"
            ),
            OnDeviceRouter.Leg(
                coordinates: [], distanceMeters: 2_000, surfaceName: "paved", edgeId: "paved-b"
            )
        ])
        #expect(edges.contains("gravel-a"))
    }

    @Test func wanderWidensTheCorridorAndSoftensAwayCost() {
        let full = HopSearchPolicy.corridorMeters(for: .dirt, wander: 1) ?? 0
        let tight = HopSearchPolicy.corridorMeters(for: .dirt, wander: 0) ?? 0
        #expect(full > tight)
        #expect(tight >= HopSearchPolicy.dirtCorridorMeters * 0.4)
        let awayFull = OnDeviceProfileCosts.approachAwayExtra(
            profile: .dirt, dFromMeters: 50_000, dToMeters: 60_000, abMeters: 80_000, wander: 1
        )
        let awayTight = OnDeviceProfileCosts.approachAwayExtra(
            profile: .dirt, dFromMeters: 50_000, dToMeters: 60_000, abMeters: 80_000, wander: 0
        )
        #expect(awayTight > awayFull)
        #expect(HopSearchPolicy.corridorMeters(for: .cleanest, wander: 1) == nil)
        #expect(HopSearchPolicy.balancedEnvelopeMultipliers.first == 2)
        #expect(HopSearchPolicy.balancedEnvelopeMultipliers.last == 1)
        #expect(HopSearchPolicy.balancedEnvelopeMultipliers.contains(1))
    }

    @Test func pinnedSeedVarietyIsDeterministicAndCanStealANearEqualPredecessor() {
        let same = HopSearchPolicy.considerRelax(
            newCost: 100, oldCost: 100, newEi: 2, oldEi: 1, node: 9,
            newIsDirt: true, oldIsDirt: false, seed: 42, variety: true, slotsUsed: 0
        )
        let sameAgain = HopSearchPolicy.considerRelax(
            newCost: 100, oldCost: 100, newEi: 2, oldEi: 1, node: 9,
            newIsDirt: true, oldIsDirt: false, seed: 42, variety: true, slotsUsed: 0
        )
        #expect(same == sameAgain)
        let strict = HopSearchPolicy.considerRelax(
            newCost: 101, oldCost: 100, newEi: 2, oldEi: 1, node: 9,
            newIsDirt: true, oldIsDirt: false, seed: 0, variety: false, slotsUsed: 0
        )
        #expect(strict == .reject)
    }

    @Test func sparseLabelsChargeOnlyTouchedPages() {
        var labels = SparseDefaultArray(count: 2_000_000, default: Double.infinity)
        labels[12] = 0
        labels[12 + 4_096] = 3
        #expect(labels[12] == 0)
        #expect(labels[13].isInfinite)
        #expect(labels.residentPageCount == 2)
        #expect(labels.chargedBytes < 2_000_000 * MemoryLayout<Double>.stride / 100)
    }

    @Test func fogNeighborhoodFollowsAWideCorridorAndGrowsWithTheRoute() {
        let start = CLLocationCoordinate2D(latitude: 44.74, longitude: -63.30)
        let end = CLLocationCoordinate2D(latitude: 45.26, longitude: -67.29)
        var fog = FogOfWarNeighborhood(
            start: start,
            end: end,
            workingRadiusMeters: 16_000,
            corridorMeters: 40_000
        )
        #expect(fog.contains(start))
        #expect(fog.contains(end))
        let midway = CLLocationCoordinate2D(latitude: 45.0, longitude: -65.3)
        #expect(fog.contains(midway))
        let farNorth = CLLocationCoordinate2D(latitude: 48.5, longitude: -65.3)
        #expect(!fog.contains(farNorth))
        let offAxis = CLLocationCoordinate2D(latitude: 45.15, longitude: -65.3)
        fog.noteVisited(offAxis)
        #expect(fog.contains(offAxis))
        #expect(fog.expansions >= 1)
    }

    @Test func routingSessionContextSuppliesAFreshSeed() async {
        let captured = await RoutingSessionContext.$seed.withValue(9_001) {
            RouteRequest(
                profile: .dirt,
                locations: [
                    RouteLocation(latitude: 44.7, longitude: -63.6, label: "A"),
                    RouteLocation(latitude: 45.2, longitude: -67.2, label: "B")
                ],
                allowUnknown: false
            )
        }
        #expect(captured.options?.sessionSeed == 9_001)
        let unseeded = RouteRequest(
            profile: .dirt,
            locations: [
                RouteLocation(latitude: 44.7, longitude: -63.6, label: "A"),
                RouteLocation(latitude: 45.2, longitude: -67.2, label: "B")
            ],
            allowUnknown: false
        )
        #expect(unseeded.options?.sessionSeed == nil)
    }
}
