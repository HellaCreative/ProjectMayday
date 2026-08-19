import CoreLocation
import Foundation
import Testing
@testable import Dirt

struct UrbanCoreTests {
    @Test func vancouverMetroBlocksDowntownNotSquamish() {
        let downtown = CLLocationCoordinate2D(latitude: 49.282, longitude: -123.121)
        let squamish = CLLocationCoordinate2D(latitude: 49.701, longitude: -123.155)
        let kelowna = CLLocationCoordinate2D(latitude: 49.888, longitude: -119.496)
        #expect(UrbanCore.contains(downtown))
        #expect(!UrbanCore.contains(squamish))
        #expect(UrbanCore.blocks(point: downtown, start: squamish, end: kelowna))
        #expect(!UrbanCore.blocks(point: squamish, start: squamish, end: kelowna))
    }

    @Test func pinInsideCoreAllowsThatCore() {
        let downtown = CLLocationCoordinate2D(latitude: 49.282, longitude: -123.121)
        let kelowna = CLLocationCoordinate2D(latitude: 49.888, longitude: -119.496)
        #expect(!UrbanCore.blocks(point: downtown, start: downtown, end: kelowna))
        #expect(UrbanCore.blocks(point: downtown, start: kelowna, end: kelowna))
    }
}

struct HopSearchPolicyTests {
    @Test func varietyHashIsStablePerSeed() {
        let a = HopSearchPolicy.hash(42, 100, 7)
        let b = HopSearchPolicy.hash(42, 100, 7)
        let c = HopSearchPolicy.hash(43, 100, 7)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func clearlyBetterCostAlwaysRelaxes() {
        #expect(
            HopSearchPolicy.considerRelax(
                newCost: 80, oldCost: 100, newEi: 1, oldEi: 2, node: 9,
                newIsDirt: false, oldIsDirt: true, seed: 1, variety: true, slotsUsed: 3
            ) == .acceptReset
        )
    }

    @Test func nearEqualWorseUsesSlotsUntilCap() {
        let seed: UInt64 = 1
        let node = 9
        var preferredNew = 1
        var preferredOld = 2
        var found = false
        for a in 1..<40 where !found {
            for b in 1..<40 where a != b {
                if HopSearchPolicy.hash(seed, node, a) < HopSearchPolicy.hash(seed, node, b) {
                    preferredNew = a
                    preferredOld = b
                    found = true
                    break
                }
            }
        }
        #expect(found)
        #expect(
            HopSearchPolicy.considerRelax(
                newCost: 108, oldCost: 100, newEi: preferredNew, oldEi: preferredOld,
                node: node, newIsDirt: false, oldIsDirt: false, seed: seed,
                variety: true, slotsUsed: 1
            ) == .stealPred
        )
        #expect(
            !HopSearchPolicy.shouldPush(.stealPred)
        )
        #expect(
            HopSearchPolicy.considerRelax(
                newCost: 108, oldCost: 100, newEi: preferredNew, oldEi: preferredOld,
                node: node, newIsDirt: false, oldIsDirt: false, seed: seed,
                variety: true, slotsUsed: HopSearchPolicy.varietySlots
            ) == .reject
        )
        #expect(
            HopSearchPolicy.considerRelax(
                newCost: 108, oldCost: 100, newEi: preferredOld, oldEi: preferredNew,
                node: node, newIsDirt: false, oldIsDirt: false, seed: seed,
                variety: true, slotsUsed: 1
            ) == .reject
        )
    }

    @Test func stealPredCycleIsDetected() {
        var prev = [Int](repeating: -1, count: 4)
        prev[1] = 0
        prev[2] = 1
        #expect(HopSearchPolicy.createsCycle(prev: prev, from: 2, through: 0))
        #expect(!HopSearchPolicy.createsCycle(prev: prev, from: 0, through: 2))
    }

    @Test func varietyOffNeverAcceptsWorse() {
        #expect(
            HopSearchPolicy.considerRelax(
                newCost: 108, oldCost: 100, newEi: 1, oldEi: 2, node: 9,
                newIsDirt: true, oldIsDirt: false, seed: 1, variety: false, slotsUsed: 0
            ) == .reject
        )
    }

    @Test func corridorWidthsMatchSpec() {
        #expect(HopSearchPolicy.corridorMeters(for: .direct) == 15_000)
        #expect(HopSearchPolicy.corridorMeters(for: .dirt) == 50_000)
        #expect(HopSearchPolicy.corridorMeters(for: .balanced) == 40_000)
        #expect(HopSearchPolicy.corridorMeters(for: .cleanest) == nil)
    }

    @Test func directCorridorRejects16kmOffAnEastWestLine() {
        let a = CLLocationCoordinate2D(latitude: 50, longitude: -123)
        let b = CLLocationCoordinate2D(latitude: 50, longitude: -120)
        let midLon = -121.5
        // Latitude metres ≠ cross-track: A→B at constant lat is not a great circle.
        let inside = CLLocationCoordinate2D(latitude: 50 + 12_000 / 111_320, longitude: midLon)
        let outside = CLLocationCoordinate2D(latitude: 50 + 20_000 / 111_320, longitude: midLon)
        #expect(abs(GeoMath.crossTrackMeters(point: inside, lineFrom: a, to: b)) < 15_000)
        #expect(abs(GeoMath.crossTrackMeters(point: outside, lineFrom: a, to: b)) > 15_000)
        #expect(!HopSearchPolicy.outsideCorridor(point: inside, start: a, end: b, widthMeters: 15_000))
        #expect(HopSearchPolicy.outsideCorridor(point: outside, start: a, end: b, widthMeters: 15_000))
        #expect(!HopSearchPolicy.outsideCorridor(point: outside, start: a, end: b, widthMeters: 50_000))
        #expect(!HopSearchPolicy.outsideCorridor(point: a, start: a, end: b, widthMeters: 15_000))
    }

    @Test func cleanHasNoCorridorConstraint() {
        var ctx = HopSearchContext.forProfile(.cleanest, seed: 1)
        #expect(ctx.corridorMeters == nil)
        #expect(ctx.cityWall == false)
        ctx = HopSearchContext.forProfile(.direct, seed: 1)
        #expect(ctx.corridorMeters == 15_000)
        #expect(ctx.cityWall == true)
    }
}

struct FuelItineraryTests {
    @Test func progressPickPrefersTowardBNotASidewaysSpur() {
        let start = RouteCoordinate(longitude: -123.2, latitude: 50.0)
        let end = RouteCoordinate(longitude: -119.7, latitude: 50.0)
        let along = GeoMath.interpolate(start, end, fraction: 0.45)
        let spur = RouteCoordinate(longitude: along.longitude, latitude: 50.45)
        let fuels = [
            POIFeature(
                id: "osm:spur", category: "fuel", latitude: spur.latitude,
                longitude: spur.longitude, name: "spur", address: nil, brand: nil,
                openingHours: nil, phone: nil, website: nil
            ),
            POIFeature(
                id: "osm:along", category: "fuel", latitude: along.latitude,
                longitude: along.longitude, name: "along", address: nil, brand: nil,
                openingHours: nil, phone: nil, website: nil
            )
        ]
        let reach = ["osm:spur": 90_000.0, "osm:along": 95_000.0]
        let pick = FuelItinerary.pickProgressFuel(
            fuels: fuels, from: start, to: end, reachableMeters: reach,
            tankMeters: 200_000, sessionSeed: 1
        )
        #expect(pick?.id == "osm:along")
    }

    @Test func progressAlongABIsPositiveTowardB() {
        let a = RouteCoordinate(longitude: -123, latitude: 50)
        let b = RouteCoordinate(longitude: -120, latitude: 50)
        let mid = GeoMath.interpolate(a, b, fraction: 0.5)
        let behind = RouteCoordinate(longitude: -124, latitude: 50)
        #expect(GeoMath.progressAlongAB(from: a, to: b, point: mid) > 50_000)
        #expect(GeoMath.progressAlongAB(from: a, to: b, point: behind) < 0)
    }
}
