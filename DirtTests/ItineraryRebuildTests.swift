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

    @Test func cleanMetroMultiplierOverrideAppliesOnlyToCleanest() {
        #expect(UrbanCore.resolveCleanMetroPenalty(profile: .cleanest, override: nil, avoidMajorHighways: true) == 10)
        #expect(UrbanCore.resolveCleanMetroPenalty(profile: .cleanest, override: nil, avoidMajorHighways: false) == 2)
        #expect(UrbanCore.resolveCleanMetroPenalty(profile: .cleanest, override: 7, avoidMajorHighways: true) == 7)
        #expect(UrbanCore.resolveCleanMetroPenalty(profile: .balanced, override: 5, avoidMajorHighways: true) == 120)
        #expect(UrbanCore.resolveCleanMetroPenalty(profile: .dirt, override: 5, avoidMajorHighways: true) == 120)
        #expect(UrbanCore.resolveSettlementPenalty(profile: .cleanest, override: nil, avoidMajorHighways: true) == 10)
        #expect(UrbanCore.resolveSettlementPenalty(profile: .cleanest, override: nil, avoidMajorHighways: false) == 2)
        #expect(UrbanCore.resolveSettlementPenalty(profile: .cleanest, override: 99, avoidMajorHighways: true) == 20)
        #expect(UrbanCore.resolveSettlementPenalty(profile: .balanced, override: 20, avoidMajorHighways: true) == 5)
    }

    @Test func packTownPenaltyIsFiniteAndKeepsEndpointExemption() {
        let town = UrbanCore.Box(
            minLat: 45.3, maxLat: 45.4,
            minLon: -63.4, maxLon: -63.2,
            name: "test-town"
        )
        let centre = CLLocationCoordinate2D(latitude: 45.35, longitude: -63.3)
        let west = CLLocationCoordinate2D(latitude: 45.35, longitude: -63.6)
        let east = CLLocationCoordinate2D(latitude: 45.35, longitude: -63.0)
        #expect(UrbanCore.settlementFallbackMultiplier(
            point: centre, start: west, end: east, boxes: [town], penalty: 10
        ) == 10)
        #expect(UrbanCore.settlementFallbackMultiplier(
            point: centre, start: west, end: east, boxes: [town], penalty: 99
        ) == 20)
        #expect(UrbanCore.settlementFallbackMultiplier(
            point: centre, start: centre, end: east, boxes: [town], penalty: 10
        ) == 1)
    }

    @Test func emptyV3PackUsesNovaScotiaTownCompatibilityData() {
        let fallback = UrbanCore.settlementBoxes(embedded: [], regionId: "NS", profile: .cleanest)
        #expect(fallback.count > 1)
        #expect(fallback.contains { $0.name == "Truro" })
        let embedded = [UrbanCore.Box(
            minLat: 1, maxLat: 2, minLon: 3, maxLon: 4, name: "pack-authoritative"
        )]
        #expect(UrbanCore.settlementBoxes(
            embedded: embedded, regionId: "ns", profile: .balanced
        ).first?.name == "pack-authoritative")
        #expect(UrbanCore.settlementBoxes(
            embedded: [], regionId: "ns", profile: .balanced
        ).isEmpty)
        #expect(UrbanCore.settlementBoxes(
            embedded: [], regionId: "ns", profile: .dirt
        ).isEmpty)
        #expect(UrbanCore.settlementBoxes(
            embedded: [], regionId: "nb", profile: .cleanest
        ).isEmpty)
    }
}

struct CrossPackFuelBudgetTests {
    @Test func currentHopReservesTheMinimumForEveryLaterProvince() {
        let minima = [218_046.0, 45_300.0]
        #expect(GraphPackStore.reservedChainHopCap(
            totalCapMeters: 279_000,
            completedMeters: 0,
            hopIndex: 0,
            hopCount: 2,
            minimumHopMeters: minima
        ) == 233_700)
        #expect(GraphPackStore.reservedChainHopCap(
            totalCapMeters: 279_000,
            completedMeters: 230_000,
            hopIndex: 1,
            hopCount: 2,
            minimumHopMeters: minima
        ) == 49_000)
        #expect(GraphPackStore.reservedChainHopCap(
            totalCapMeters: 279_000,
            completedMeters: 0,
            hopIndex: 0,
            hopCount: 2,
            minimumHopMeters: []
        ) == 279_000)
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
        #expect(HopSearchPolicy.fuelWaypointSnapMeters == 150)
        #expect(HopSearchPolicy.fuelMinTank == 0.50)
        #expect(HopSearchPolicy.fuelPreferTank == 0.65)
        #expect(HopSearchPolicy.fuelComfortLo == 0.50)
        #expect(HopSearchPolicy.fuelComfortHi == 0.80)
        #expect(HopSearchPolicy.tankCommitBand(graphMeters: 280_000, tankMeters: 450_000) == 0)
        #expect(HopSearchPolicy.tankCommitBand(graphMeters: 200_000, tankMeters: 450_000) == 1)
        #expect(HopSearchPolicy.tankCommitBand(graphMeters: 449_800, tankMeters: 450_000) == 2)
    }

    @Test func corridorWidthsMatchSpec() {
        #expect(HopSearchPolicy.corridorMeters(for: .dirt) == 60_000)
        #expect(HopSearchPolicy.corridorMeters(for: .balanced) == 40_000)
        #expect(HopSearchPolicy.corridorMeters(for: .cleanest) == nil)
        #expect(HopSearchPolicy.extraBudget(shortestMeters: 100_000, for: .balanced) == 140_000)
        #expect(HopSearchPolicy.extraBudget(shortestMeters: 100_000, for: .cleanest) == nil)
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
        #expect(HopSearchPolicy.pickResourceEnd(labels: labels, profile: .dirt, seed: 1) == 1)
    }

    @Test func everyProfileUsesTheUrbanCoreWallByDefault() {
        var ctx = HopSearchContext.forProfile(.cleanest, seed: 1)
        #expect(ctx.corridorMeters == nil)
        #expect(ctx.cityWall == true)
        #expect(ctx.pavedOnly == false)
        #expect(ctx.urbanCoreFallback == false)
        ctx = HopSearchContext.forProfile(.balanced, seed: 1)
        #expect(ctx.corridorMeters == 40_000)
        #expect(ctx.cityWall == true)
    }

    @Test func unknownProfileDecodesAsBalanced() throws {
        #expect(RouteProfile(rawValue: "scenic") == nil)
        #expect(RouteProfile.allCases == [.cleanest, .balanced, .dirt])
        let data = Data(#""scenic""#.utf8)
        let decoded = try JSONDecoder().decode(RouteProfile.self, from: data)
        #expect(decoded == .balanced)
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

    @Test func rankedLeavesTheFinalFiveKilometresForTheDestination() {
        let start = RouteCoordinate(longitude: -63.20, latitude: 45)
        let end = RouteCoordinate(longitude: -63.00, latitude: 45)
        let tooClose = GeoMath.interpolate(start, end, fraction: 0.80)
        let ranked = FuelItinerary.rankedProgressFuel(
            fuels: [poi("city-hop", tooClose)],
            from: start,
            to: end,
            reachableMeters: ["osm:city-hop": 20_000],
            tankMeters: 100_000,
            sessionSeed: 1
        )

        #expect(ranked.isEmpty)
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

    @Test func rankedPrefersComfortWindowOverTankWall() {
        let start = RouteCoordinate(longitude: -63.5752, latitude: 44.6488)
        let end = RouteCoordinate(longitude: -60.1942, latitude: 46.1368)
        let windowStop = GeoMath.interpolate(start, end, fraction: 0.52)
        let wallStop = GeoMath.interpolate(start, end, fraction: 0.82)
        let ranked = FuelItinerary.rankedProgressFuel(
            fuels: [poi("wall", wallStop), poi("window", windowStop)],
            from: start,
            to: end,
            reachableMeters: ["osm:wall": 449_800, "osm:window": 280_000],
            tankMeters: 450_000,
            sessionSeed: 1
        )
        #expect(ranked.first?.id == "osm:window")
        #expect(ranked.map(\.id) == ["osm:window", "osm:wall"])
    }

    @Test func routedFuelCandidatesPutProfileQualityBeforeTankComfort() {
        let point = RouteCoordinate(longitude: -63, latitude: 45)
        let quality = poi("quality", point)
        let comfort = poi("comfort", point)
        func candidate(
            _ fuel: POIFeature,
            meters: Double,
            dirt: Double,
            fallback: Int = 0,
            major: Double = 0,
            backtrack: Double = 0,
            stops: Int = 1,
            rank: Int
        ) -> FuelItinerary.ProfileFuelCandidate {
            FuelItinerary.ProfileFuelCandidate(
                fuel: fuel,
                routedMeters: meters,
                chainDirtPercent: dirt,
                validForward: true,
                cleanFallbackCount: fallback,
                cleanMajorRoadMeters: major,
                cleanRoutedMeters: meters,
                chainBacktrackMeters: backtrack,
                chainStopCount: stops,
                progressMeters: meters,
                discoveryRank: rank
            )
        }
        let earlyDirt = candidate(quality, meters: 40_000, dirt: 92, rank: 0)
        let comfortablePaved = candidate(comfort, meters: 80_000, dirt: 8, rank: 1)
        #expect(FuelItinerary.prefersProfileFuelCandidate(
            earlyDirt, over: comfortablePaved, profile: .dirt, tankMeters: 130_000
        ))

        let earlyBalanced = candidate(quality, meters: 40_000, dirt: 50, rank: 0)
        let comfortableDirt = candidate(comfort, meters: 80_000, dirt: 95, rank: 1)
        #expect(FuelItinerary.prefersProfileFuelCandidate(
            earlyBalanced, over: comfortableDirt, profile: .balanced, tankMeters: 130_000
        ))

        let earlyRural = candidate(quality, meters: 40_000, dirt: 0, rank: 0)
        let comfortableTown = candidate(
            comfort, meters: 80_000, dirt: 0, fallback: 1, major: 60_000, rank: 1
        )
        #expect(FuelItinerary.prefersProfileFuelCandidate(
            earlyRural, over: comfortableTown, profile: .cleanest, tankMeters: 130_000
        ))

        let ruralArc = candidate(
            quality, meters: 180_000, dirt: 60, backtrack: 0, stops: 3, rank: 0
        )
        let lollipop = candidate(
            comfort, meters: 160_000, dirt: 70, backtrack: 32_000, stops: 1, rank: 1
        )
        #expect(FuelItinerary.prefersProfileFuelCandidate(
            ruralArc, over: lollipop, profile: .dirt, tankMeters: 130_000
        ))
    }


    @Test func nearWallLegRequestsComfortFuelWhileShortLegDoesNot() {
        #expect(FuelItinerary.fuelStopCountNeeded(
            profileMeters: 152_000,
            firstLegMaxMeters: 153_000,
            usableRangeMeters: 153_000
        ) == 1)
        #expect(FuelItinerary.fuelStopCountNeeded(
            profileMeters: 100_000,
            firstLegMaxMeters: 153_000,
            usableRangeMeters: 153_000
        ) == 0)
    }

    @Test func numberedWaypointOnStationIsALiveRefuelUntilDraggedOff() {
        let on = RouteCoordinate(longitude: -61.998, latitude: 45.616)
        let off = RouteCoordinate(longitude: -61.980, latitude: 45.630)
        let origin = RouteCoordinate(longitude: -63.58, latitude: 44.65)
        let dest = RouteCoordinate(longitude: -60.19, latitude: 46.14)
        let pump = poi("irving", on)
        #expect(FuelItinerary.nearestFuelStation(to: on, stations: [pump])?.station.id == "osm:irving")
        #expect(FuelItinerary.nearestFuelStation(to: off, stations: [pump]) == nil)
        let onRoute = FuelItinerary.deriveWaypointRefuels(
            waypoints: [origin, on, dest], stations: [pump]
        )
        #expect(onRoute.map(\.locationIndex) == [1])
        let offRoute = FuelItinerary.deriveWaypointRefuels(
            waypoints: [origin, off, dest], stations: [pump]
        )
        #expect(offRoute.isEmpty)
        let ordinary = FuelItinerary.deriveWaypointRefuels(
            waypoints: [origin, dest], stations: [pump]
        )
        #expect(ordinary.isEmpty)
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
