import CoreLocation
import Foundation
import Testing
@testable import Dirt

struct UrbanCoreTests {
    @Test func recognizedCoreBlocksThroughTravelButNotNearbyRuralTravel() {
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

    @Test func relaxedCoreRemainsProhibitivelyExpensiveExceptForEndpointCore() {
        let downtown = CLLocationCoordinate2D(latitude: 49.282, longitude: -123.121)
        let squamish = CLLocationCoordinate2D(latitude: 49.701, longitude: -123.155)
        let kelowna = CLLocationCoordinate2D(latitude: 49.888, longitude: -119.496)
        #expect(UrbanCore.fallbackMultiplier(point: downtown, start: squamish, end: kelowna) == 120)
        #expect(UrbanCore.fallbackMultiplier(point: downtown, start: downtown, end: kelowna) == 1)
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

    @Test func pass2CapsAreTightEnoughForLongHaul() {
        #expect(HopSearchPolicy.pass2TimeCapSeconds == 18)
        #expect(HopSearchPolicy.pass2PopCap == 400_000)
        #expect(HopSearchPolicy.pass2PopCap < 8_000_000)
        #expect(HopSearchPolicy.fuelMaxTank == 1.0)
    }

    @Test func corridorWidthsMatchSpec() {
        #expect(HopSearchPolicy.corridorMeters(for: .direct) == 15_000)
        #expect(HopSearchPolicy.corridorMeters(for: .dirt) == 60_000)
        #expect(HopSearchPolicy.corridorMeters(for: .balanced) == 40_000)
        #expect(HopSearchPolicy.corridorMeters(for: .cleanest) == 25_000)
        #expect(HopSearchPolicy.cleanProgressRegressionMeters == 20_000)
        #expect(HopSearchPolicy.extraBudget(shortestMeters: 100_000, for: .direct) == 115_000)
        #expect(HopSearchPolicy.extraBudget(shortestMeters: 100_000, for: .cleanest) == 125_000)
    }

    @Test func ratioBucketsSplitTheTenPointBand() {
        let len = 200_000.0
        let b45 = HopSearchPolicy.dirtBucket(dirtMeters: 90_000, pathMeters: len)
        let b50 = HopSearchPolicy.dirtBucket(dirtMeters: 100_000, pathMeters: len)
        let b55 = HopSearchPolicy.dirtBucket(dirtMeters: 110_000, pathMeters: len)
        let b65 = HopSearchPolicy.dirtBucket(dirtMeters: 130_000, pathMeters: len)
        #expect(b50 == 10)
        #expect(b45 != b55)
        #expect(b50 != b65)
        #expect(b45 < b50 && b50 < b55)
    }

    @Test func pickBalancedEndPrefersInBandCloserToFifty() {
        let labels: [(lab: Int, len: Double, dirt: Double)] = [
            (1, 200_000, 130_000), // 65%
            (2, 210_000, 105_000), // 50%
            (3, 205_000, 80_000)   // 39%
        ]
        #expect(HopSearchPolicy.pickResourceEnd(labels: labels, profile: .balanced, seed: 1) == 2)
        #expect(HopSearchPolicy.pickResourceEnd(labels: labels, profile: .direct, seed: 1) == 1)
        #expect(HopSearchPolicy.pickResourceEnd(labels: labels, profile: .dirt, seed: 1) == 1)
    }

    @Test func everyProfileUsesTheUrbanCoreWallByDefault() {
        var ctx = HopSearchContext.forProfile(.cleanest, seed: 1)
        #expect(ctx.corridorMeters == nil)
        #expect(ctx.cityWall == true)
        #expect(ctx.pavedOnly == false)
        #expect(ctx.urbanCoreFallback == false)
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

    @Test func rankedSkipsExcludedAndOffersNextBest() {
        let start = RouteCoordinate(longitude: -123.2, latitude: 50.0)
        let end = RouteCoordinate(longitude: -119.7, latitude: 50.0)
        let farther = GeoMath.interpolate(start, end, fraction: 0.55)
        let nearer = GeoMath.interpolate(start, end, fraction: 0.35)
        let fuels = [
            poi("far", farther),
            poi("near", nearer)
        ]
        let reach = ["osm:far": 160_000.0, "osm:near": 100_000.0]
        let ranked = FuelItinerary.rankedProgressFuel(
            fuels: fuels, from: start, to: end, reachableMeters: reach,
            tankMeters: 200_000, sessionSeed: 1
        )
        #expect(ranked.map(\.id).first == "osm:far")
        let next = FuelItinerary.rankedProgressFuel(
            fuels: fuels, from: start, to: end, reachableMeters: reach,
            tankMeters: 200_000, sessionSeed: 1, excluding: ["osm:far"]
        )
        #expect(next.map(\.id) == ["osm:near"])
    }

    @Test func rankedKeepsShortRangeFallbackAndOffAxisPump() {
        let start = RouteCoordinate(longitude: -123.2, latitude: 50.0)
        let end = RouteCoordinate(longitude: -119.7, latitude: 50.0)
        let preferred = GeoMath.interpolate(start, end, fraction: 0.55)
        let mountainDetour = RouteCoordinate(longitude: -122.4, latitude: 51.0)
        let fuels = [poi("preferred", preferred), poi("detour", mountainDetour)]
        let reach = ["osm:preferred": 160_000.0, "osm:detour": 60_000.0]

        let ranked = FuelItinerary.rankedProgressFuel(
            fuels: fuels, from: start, to: end, reachableMeters: reach,
            tankMeters: 200_000, sessionSeed: 1
        )

        #expect(ranked.map(\.id) == ["osm:preferred", "osm:detour"])
    }

    @Test func rankedDoesNotPutRemoteLateralPumpAheadOfForwardPump() {
        let start = RouteCoordinate(longitude: -63.340271, latitude: 44.764823)
        let end = RouteCoordinate(longitude: -60.983077, latitude: 45.644252)
        let forward = RouteCoordinate(longitude: -62.1, latitude: 45.25)
        let lateral = RouteCoordinate(longitude: -63.2, latitude: 45.85)
        let ranked = FuelItinerary.rankedProgressFuel(
            fuels: [poi("lateral", lateral), poi("forward", forward)],
            from: start,
            to: end,
            reachableMeters: ["osm:lateral": 210_000, "osm:forward": 160_000],
            tankMeters: 218_500,
            sessionSeed: 1
        )
        #expect(ranked.first?.id == "osm:forward")
    }

    @Test func progressAlongABIsPositiveTowardB() {
        let a = RouteCoordinate(longitude: -123, latitude: 50)
        let b = RouteCoordinate(longitude: -120, latitude: 50)
        let mid = GeoMath.interpolate(a, b, fraction: 0.5)
        let behind = RouteCoordinate(longitude: -124, latitude: 50)
        #expect(GeoMath.progressAlongAB(from: a, to: b, point: mid) > 50_000)
        #expect(GeoMath.progressAlongAB(from: a, to: b, point: behind) < 0)
    }

    @Test func approximateReachRejectsAnythingBeyondTank() {
        let start = RouteCoordinate(longitude: -123, latitude: 50)
        let near = RouteCoordinate(longitude: -122, latitude: 50)
        let far = RouteCoordinate(longitude: -119, latitude: 50)
        let result = FuelItinerary.approximateReachableMeters(
            fuels: [poi("near", near), poi("far", far)],
            from: start,
            tankMeters: 200_000
        )
        #expect(result["osm:near"] != nil)
        #expect(result["osm:far"] == nil)
    }

    @Test func liveCorridorRankingUsesAlongRouteProgress() {
        let start = RouteCoordinate(longitude: -123, latitude: 50)
        let end = RouteCoordinate(longitude: -119, latitude: 50)
        let early = GeoMath.interpolate(start, end, fraction: 0.25)
        let preferred = GeoMath.interpolate(start, end, fraction: 0.55)
        let tooFarOff = RouteCoordinate(longitude: preferred.longitude, latitude: 51)
        let ranked = FuelItinerary.rankedRouteCorridorFuel(
            fuels: [poi("early", early), poi("preferred", preferred), poi("off", tooFarOff)],
            from: start,
            routeCoordinates: [start, end],
            tankMeters: 200_000,
            sessionSeed: 1
        )
        #expect(ranked.first?.id == "osm:preferred")
        #expect(!ranked.map(\.id).contains("osm:off"))
    }

    @Test func liveCandidateOrderKeepsProgressFallbackAfterBadCorridorPump() {
        let at = RouteCoordinate(longitude: -122, latitude: 50)
        let isolated = poi("isolated", at)
        let lillooet = poi("lillooet", RouteCoordinate(longitude: -121.93, latitude: 50.70))
        let merged = FuelItinerary.mergedCandidateOrder(
            primary: [isolated],
            fallback: [isolated, lillooet]
        )
        #expect(merged.map(\.id) == ["osm:isolated", "osm:lillooet"])
    }

    @Test func routeSuffixStartsNearCurrentPump() {
        let route = [
            RouteCoordinate(longitude: -123, latitude: 50),
            RouteCoordinate(longitude: -122, latitude: 50),
            RouteCoordinate(longitude: -121, latitude: 50),
            RouteCoordinate(longitude: -120, latitude: 50)
        ]
        let current = RouteCoordinate(longitude: -121.9, latitude: 50.01)
        let suffix = FuelItinerary.routeSuffix(from: current, routeCoordinates: route)
        #expect(suffix.first == current)
        #expect(suffix.last == route.last)
        #expect(suffix.count == 3)
    }

    @Test func packedFuelDecodesStations() {
        let json = """
        {"schema":"fuel.v1","regionId":"bc","stations":[
          {"id":"osm:n1","lat":49.7,"lon":-123.1,"name":"Chevron","brand":"Chevron"}
        ]}
        """
        let stations = PackedFuel.decode(Data(json.utf8))
        #expect(stations.count == 1)
        #expect(stations[0].id == "osm:n1")
        #expect(stations[0].category == "fuel")
        #expect(stations[0].name == "Chevron")
    }

    private func poi(_ id: String, _ at: RouteCoordinate) -> POIFeature {
        POIFeature(
            id: "osm:\(id)", category: "fuel", latitude: at.latitude,
            longitude: at.longitude, name: id, address: nil, brand: nil,
            openingHours: nil, phone: nil, website: nil
        )
    }
}
