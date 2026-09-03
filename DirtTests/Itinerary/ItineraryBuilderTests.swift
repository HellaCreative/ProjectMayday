import Foundation
import Testing
@testable import Dirt

@MainActor
struct FuelPlanningProgressWatchdogTests {
    @Test func regularForwardProgressRenewsTheInactivityWindow() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var watchdog = FuelPlanningProgressWatchdog(now: start)

        watchdog.recordProgress(at: start.addingTimeInterval(12))
        watchdog.recordProgress(at: start.addingTimeInterval(24))

        #expect(!watchdog.isExpired(at: start.addingTimeInterval(30)))
        #expect(watchdog.remainingMilliseconds(at: start.addingTimeInterval(30)) == 22_000)
    }

    @Test func twentyEightSecondsWithoutForwardProgressExpires() {
        let start = Date(timeIntervalSinceReferenceDate: 2_000)
        let watchdog = FuelPlanningProgressWatchdog(now: start)

        #expect(!watchdog.isExpired(at: start.addingTimeInterval(27.999)))
        #expect(watchdog.isExpired(at: start.addingTimeInterval(28)))
    }

    @Test func newRiderBuildReceivesAnIndependentWindow() {
        let start = Date(timeIntervalSinceReferenceDate: 3_000)
        let oldBuild = FuelPlanningProgressWatchdog(now: start)
        let newBuild = FuelPlanningProgressWatchdog(now: start.addingTimeInterval(25))

        #expect(!oldBuild.isExpired(at: start.addingTimeInterval(25)))
        #expect(oldBuild.isExpired(at: start.addingTimeInterval(28)))
        #expect(!newBuild.isExpired(at: start.addingTimeInterval(25)))
        #expect(newBuild.remainingMilliseconds(at: start.addingTimeInterval(25)) == 28_000)
    }
}

@MainActor
struct ItineraryBuilderTests {
    @Test func dirtFuelNeedUsesUnconstrainedProfileRideWhileCleanNeedsNoStop() async throws {
        let points = [point(0), point(1)]
        let stop = point(0.5)
        let dirtSource = FakeRoutingSource(name: "live")
        dirtSource.distances[key(points[0], points[1])] = 300_000
        dirtSource.distances[key(points[0], stop)] = 150_000
        dirtSource.distances[key(stop, points[1])] = 150_000
        dirtSource.fuelStops = [fuelStop("fuel-1", at: stop)]

        let dirt = await build(points, source: dirtSource, usable: 237_500, profile: .dirt)

        let dirtPlans = dirtSource.fuelChainRequests.filter { $0.fuel.probeFirstReachableStation != true }
        #expect(dirtPlans.count == 2)
        #expect(dirtPlans.first?.fuel.requireFuelStopBeforeEnd == false)
        #expect(dirt.legs.filter { $0.endsAtFuelStop != nil }.count == 1)
        let dirtMeters = dirt.legs.reduce(0.0) { $0 + ($1.response.distanceMeters ?? 0) }
        let dirtShare = dirt.legs.reduce(0.0) {
            $0 + Double($1.response.dirtPercent) * ($1.response.distanceMeters ?? 0)
        } / dirtMeters
        #expect(abs(dirtShare - 80) <= 10)

        let cleanSource = FakeRoutingSource(name: "live")
        cleanSource.distances[key(points[0], points[1])] = 200_000
        let clean = await build(points, source: cleanSource, usable: 237_500, profile: .cleanest)

        #expect(cleanSource.fuelChainRequests.filter {
            $0.fuel.probeFirstReachableStation != true
        }.count == 1)
        #expect(clean.legs.count == 1)
        #expect(clean.legs.first?.endsAtFuelStop == nil)
    }

    @Test func single475KmLegBuildsOneFuelStopAndTwoInRangeLegs() async throws {
        let points = [point(0), point(1)]
        let stop = point(0.5)
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 475_000
        source.distances[key(points[0], stop)] = 237_500
        source.distances[key(stop, points[1])] = 237_500
        source.fuelStops = [fuelStop("fuel-1", at: stop)]

        let result = await build(points, source: source, usable: 237_500)

        #expect(result.legs.count == 2)
        #expect(result.legs[0].endsAtFuelStop?.stationID == "fuel-1")
        #expect(result.legs.allSatisfy { ($0.response.distanceMeters ?? .infinity) <= 237_500 })
        #expect(result.legs[0].fuelUsedOnArrivalMeters == 0)
        #expect(result.legs[1].fuelUsedOnArrivalMeters == 237_500)
    }

    @Test func automaticFuelPlanningOffBuildsTheRideWithoutFuelRequests() async throws {
        let points = [point(0), point(1)]
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 300_000
        source.fuelStops = [fuelStop("unused", at: point(0.5))]
        var fuelMilestones: [String] = []

        let result = await ItineraryBuilder().build(
            makeItinerary(points), from: 0, reuse: nil,
            fuel: FuelRangePrefs.Snapshot(
                tankMeters: 150_000,
                usableMeters: 135_000,
                reservePercent: 10,
                automaticPlanningEnabled: false
            ),
            source: .fixed(source),
            onFuelStatus: { fuelMilestones.append($0) },
            onProgress: { _ in }
        )

        #expect(result.legs.count == 1)
        #expect(result.legs.first?.endsAtFuelStop == nil)
        #expect(source.fuelChainRequests.isEmpty)
        #expect(fuelMilestones.isEmpty)
    }

    @Test func combinedLivePlanConsumesItsDirectRouteWithoutASecondRouteRequest() async throws {
        let points = [point(0), point(1)]
        let source = FakeRoutingSource(name: "live")
        source.supportsCombinedFuelPlanning = true
        source.distances[key(points[0], points[1])] = 100_000

        let result = await build(points, source: source, usable: 300_000)

        #expect(result.legs.count == 1)
        #expect(source.routeRequests.isEmpty)
        #expect(source.fuelChainRequests.count == 1)
        #expect(source.fuelChainRequests[0].fuel.routeFirstPlan == true)
        #expect(source.fuelChainRequests[0].fuel.ensureDestinationFuelEscape == true)
    }

    @Test func combinedLivePlanCommitsACompleteMultiStopWindowOnce() async throws {
        let points = [point(0), point(1)]
        let pump1 = point(0.33)
        let pump2 = point(0.66)
        let source = FakeRoutingSource(name: "live")
        source.supportsCombinedFuelPlanning = true
        source.distances[key(points[0], points[1])] = 360_000
        source.distances[key(points[0], pump1)] = 120_000
        source.distances[key(pump1, pump2)] = 120_000
        source.distances[key(pump2, points[1])] = 120_000
        source.fuelStopResponses = [[
            fuelStop("fuel-1", at: pump1),
            fuelStop("fuel-2", at: pump2)
        ]]
        source.stationCandidates = [
            FuelStationCandidate(
                id: "fuel-1", meters: 120_000, dirtPct: 70,
                departureId: "start", latitude: pump1.latitude,
                longitude: pump1.longitude, validForward: true
            ),
            FuelStationCandidate(
                id: "fuel-2", meters: 120_000, dirtPct: 70,
                departureId: "fuel-1", latitude: pump2.latitude,
                longitude: pump2.longitude, validForward: true
            )
        ]

        let result = await build(points, source: source, usable: 150_000)

        #expect(source.fuelChainRequests.count == 1)
        #expect(source.routeRequests.isEmpty)
        #expect(result.legs.count == 3)
        #expect(result.legs.compactMap(\.endsAtFuelStop?.stationID) == ["fuel-1", "fuel-2"])
        #expect(result.legs[0].validFuelTargets.map(\.id) == ["fuel-1"])
        #expect(result.legs[1].validFuelTargets.map(\.id) == ["fuel-2"])
        #expect(result.riderLegStatus.values.allSatisfy { $0 == .built })
    }

    @Test func combinedFuelReplacementPreservesTheUpstreamPumpAndRebuildsTheSuffix() async throws {
        let points = [point(0), point(1)]
        let pump1 = point(0.30)
        let originalPump2 = point(0.65)
        let replacementPump2 = point(0.72)
        let source = FakeRoutingSource(name: "live")
        source.supportsCombinedFuelPlanning = true
        source.distances[key(points[0], points[1])] = 360_000
        source.distances[key(points[0], pump1)] = 100_000
        source.distances[key(pump1, originalPump2)] = 120_000
        source.distances[key(originalPump2, points[1])] = 100_000
        source.distances[key(pump1, replacementPump2)] = 125_000
        source.distances[key(replacementPump2, points[1])] = 95_000
        source.fuelStopResponses = [[
            fuelStop("fuel-1", at: pump1),
            fuelStop("fuel-2", at: originalPump2)
        ]]
        source.stationCandidates = [
            FuelStationCandidate(
                id: "fuel-2-alt", meters: 125_000, dirtPct: 65,
                departureId: "fuel-1", latitude: replacementPump2.latitude,
                longitude: replacementPump2.longitude, validForward: true
            )
        ]
        let itinerary = makeItinerary(points)
        let builder = ItineraryBuilder()
        let fuel = FuelRangePrefs.Snapshot(
            tankMeters: 150_000, usableMeters: 150_000, reservePercent: 0
        )
        let first = await builder.build(
            itinerary, from: 0, reuse: nil, fuel: fuel,
            source: .fixed(source), onProgress: { _ in }
        )
        let riderLeg = try #require(itinerary.legs.first)
        let change = reduce(
            itinerary,
            .setFuelStopOverride(
                legID: riderLeg.id,
                departureAnchorID: "fuel-1",
                stationID: "fuel-2-alt"
            )
        )
        source.fuelChainRequests.removeAll()
        source.fuelStopResponses = []
        source.fuelStops = [fuelStop("fuel-2-alt", at: replacementPump2)]

        let rebuilt = await builder.build(
            change.itinerary,
            from: try #require(change.rebuildFromLegIndex),
            reuse: first,
            fuel: fuel,
            source: .fixed(source),
            replanFromStationID: change.replanFromStationID,
            onProgress: { _ in }
        )

        #expect(rebuilt.legs.first == first.legs.first)
        #expect(rebuilt.legs.compactMap(\.endsAtFuelStop?.stationID) == ["fuel-1", "fuel-2-alt"])
        #expect(source.fuelChainRequests.first?.fuel.requiredFirstStationId == "fuel-2-alt")
        #expect(source.routeRequests.isEmpty)
    }

    @Test func reachableDestinationGoesDirectWhenTheEscapePumpFitsRemainingFuel() async throws {
        let points = [point(0), point(1)]
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 233_400
        source.firstReachableStationMeters[key(points[1], points[1])] = 10_000

        let result = await build(points, source: source, usable: 247_000)

        #expect(result.legs.count == 1)
        #expect(result.legs.first?.endsAtFuelStop == nil)
        #expect(result.legs.first?.fuelUsedOnArrivalMeters == 233_400)
    }

    @Test func reachableDestinationRefuelsWhenTheEscapePumpWouldNotFit() async throws {
        let points = [point(0), point(1)]
        let stop = point(0.8)
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 233_400
        source.distances[key(points[0], stop)] = 200_000
        source.distances[key(stop, points[1])] = 33_400
        source.firstReachableStationMeters[key(points[1], points[1])] = 30_000
        source.fuelStops = [fuelStop("safe-before-destination", at: stop)]

        let result = await build(points, source: source, usable: 247_000)

        #expect(result.legs.compactMap(\.endsAtFuelStop?.stationID)
            == ["safe-before-destination"])
        #expect(result.legs.last?.fuelUsedOnArrivalMeters == 33_400)
        let firstPlan = try #require(source.fuelChainRequests.first {
            $0.fuel.probeFirstReachableStation != true
        })
        #expect(firstPlan.fuel.destinationFuelUsedLimitMeters == 217_000)
    }

    @Test func finalRiderWaypointOnPumpResetsWithoutDestinationEscapeStop() async throws {
        let points = [point(0), point(1)]
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 233_400
        source.waypointFuelStations[key(points[1], points[1])] = fuelStop(
            "destination-pump", at: points[1]
        )

        let result = await build(points, source: source, usable: 247_000)

        #expect(result.legs.count == 1)
        #expect(result.legs.first?.endsAtFuelStop == nil)
        #expect(result.legs.first?.fuelUsedOnArrivalMeters == 0)
        #expect(source.fuelChainRequests.allSatisfy {
            $0.fuel.riderLegId != "destination-escape"
        })
    }

    @Test func fuelServiceFailureKeepsRouteWithoutFabricatingGap() async throws {
        let points = [point(0), point(1)]
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 300_000
        source.fuelChainError = RoutingError.server("timed out")
        let itinerary = makeItinerary(points)

        let result = await ItineraryBuilder().build(
            itinerary, from: 0, reuse: nil,
            fuel: FuelRangePrefs.Snapshot(
                tankMeters: 150_000,
                usableMeters: 150_000, reservePercent: 0
            ),
            source: .fixed(source), onProgress: { _ in }
        )

        #expect(result.legs.isEmpty)
        if case .fuelUnknown(let message) = result.riderLegStatus[itinerary.legs[0].id] {
            #expect(message.contains("timed out"))
        } else {
            Issue.record("Expected an honest unknown-fuel state")
        }
    }

    @Test func threeStopRouteUsesResumableOnePumpWindowsAndCommitsEveryHop() async throws {
        let points = [point(0), point(1)]
        let stops = [point(0.25), point(0.5), point(0.75)]
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 450_000
        let hopPoints = [points[0]] + stops + [points[1]]
        for index in 0..<(hopPoints.count - 1) {
            source.distances[key(hopPoints[index], hopPoints[index + 1])] = 112_500
        }
        source.fuelStopResponses = [
            [fuelStop("fuel-1", at: stops[0])],
            [fuelStop("fuel-2", at: stops[1])],
            [fuelStop("fuel-3", at: stops[2])],
            []
        ]
        source.fuelWindowCompleteResponses = [false, false, false, true]
        let itinerary = makeItinerary(points)
        var progressiveHopCounts: [Int] = []
        var fuelMilestones: [String] = []

        let result = await ItineraryBuilder().build(
            itinerary, from: 0, reuse: nil,
            fuel: FuelRangePrefs.Snapshot(
                tankMeters: 150_000,
                usableMeters: 135_000, reservePercent: 10
            ),
            source: .fixed(source),
            onFuelStatus: { fuelMilestones.append($0) },
            onProgress: { progress in
                progressiveHopCounts.append(progress.legs.count)
            }
        )

        let plans = source.fuelChainRequests.filter { $0.fuel.probeFirstReachableStation != true }
        #expect(plans.count == 4)
        #expect(plans.allSatisfy {
            ($0.fuel.windowMaxStops ?? 0) >= 1 && ($0.fuel.windowMaxStops ?? 0) <= 4
        })
        #expect((plans.first?.fuel.windowMaxStops ?? 0) >= (plans.last?.fuel.windowMaxStops ?? 0))
        #expect(plans.allSatisfy { $0.fuel.allowPartialWindow == true })
        #expect(plans.allSatisfy { $0.fuel.forwardFeeler != true })
        #expect(plans.allSatisfy { $0.fuel.windowTimeBudgetMs == 20_000 })
        #expect(plans[1].locations[0].longitude == stops[0].longitude)
        #expect(plans[2].locations[0].longitude == stops[1].longitude)
        #expect(plans[3].locations[0].longitude == stops[2].longitude)
        #expect(Set(plans[1].fuel.excludedStationIds ?? []) == ["fuel-1"])
        #expect(Set(plans[2].fuel.excludedStationIds ?? []) == ["fuel-1", "fuel-2"])
        #expect(Set(plans[3].fuel.excludedStationIds ?? []) == ["fuel-1", "fuel-2", "fuel-3"])
        #expect(result.legs.count == 4)
        #expect(result.legs.compactMap(\.endsAtFuelStop?.stationID)
            == ["fuel-1", "fuel-2", "fuel-3"])
        #expect(progressiveHopCounts.contains(1))
        #expect(progressiveHopCounts.contains(2))
        #expect(progressiveHopCounts.contains(3))
        #expect(progressiveHopCounts.contains(4))
        #expect(fuelMilestones.contains("Creating fuel stop 1"))
        #expect(fuelMilestones.contains("Fuel stop 1 added"))
        #expect(fuelMilestones.contains("Creating fuel stop 2"))
        #expect(fuelMilestones.contains("Fuel stop 2 added"))
        #expect(fuelMilestones.contains("Creating fuel stop 3"))
        #expect(fuelMilestones.contains("Fuel stop 3 added"))
        #expect(fuelMilestones.contains("Checking range after fuel stop 3"))
    }

    @Test func finalFuelLegReceivesRegionalGraphMinimaForSeamBudgeting() async throws {
        let points = [point(0), point(1)]
        let stop = point(0.5)
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], stop)] = 230_000
        source.distances[key(stop, points[1])] = 45_000
        source.fuelStopResponses = [[fuelStop("fuel-1", at: stop)], []]
        source.fuelGraphMeterResponses = [
            [218_046, 45_300],
            [45_000]
        ]

        let result = await build(points, source: source, usable: 279_000)

        #expect(result.legs.count == 2)
        #expect(source.routeRequests.first?.options?.regionalHopMinimumMeters == [218_046, 45_300])
        #expect(source.routeRequests.last?.options?.regionalHopMinimumMeters == [45_000])
    }

    @Test func changingFourthFuelHopProfilePreservesFirstThreeAndRebuildsOnlyFourth() async throws {
        let points = [point(0), point(1)]
        let pumps = [point(0.25), point(0.5), point(0.75)]
        let source = FakeRoutingSource(name: "live")
        let chainPoints = [points[0]] + pumps + [points[1]]
        for index in 0..<(chainPoints.count - 1) {
            source.distances[key(chainPoints[index], chainPoints[index + 1])] = 125_000
        }
        source.fuelStopResponses = [
            [fuelStop("fuel-1", at: pumps[0])],
            [fuelStop("fuel-2", at: pumps[1])],
            [fuelStop("fuel-3", at: pumps[2])],
            []
        ]
        source.fuelWindowCompleteResponses = [false, false, false, true]
        let initial = makeItinerary(points)
        let builder = ItineraryBuilder()
        let first = await builder.build(
            initial, from: 0, reuse: nil,
            fuel: FuelRangePrefs.Snapshot(
                tankMeters: 150_000,
                usableMeters: 150_000, reservePercent: 0
            ),
            source: .fixed(source), onProgress: { _ in }
        )
        let riderLeg = try #require(initial.legs.first)
        let change = reduce(
            initial,
            .setHopProfile(legID: riderLeg.id, stationID: "fuel-3", .cleanest)
        )
        source.routeRequests.removeAll()
        source.fuelChainRequests.removeAll()
        source.fuelStopResponses = [[]]
        source.fuelWindowCompleteResponses = [true]
        var progressResults: [BuiltItinerary] = []

        let second = await builder.build(
            change.itinerary,
            from: try #require(change.rebuildFromLegIndex),
            reuse: first,
            fuel: FuelRangePrefs.Snapshot(
                tankMeters: 150_000,
                usableMeters: 150_000, reservePercent: 0
            ),
            source: .fixed(source),
            replanFromStationID: change.replanFromStationID,
            onProgress: { progressResults.append($0) }
        )

        #expect(second.legs.count == 4)
        #expect(Array(second.legs.prefix(3)) == Array(first.legs.prefix(3)))
        #expect(second.legs[3].routeProfile == .cleanest)
        #expect(second.legs[3].fromCoordinate == pumps[2])
        #expect(change.replanFromStationID == "fuel-3")
        #expect(source.routeRequests.count == 1)
        #expect(source.routeRequests.first?.profile == .cleanest)
        #expect(source.routeRequests.first?.locations.first?.longitude == pumps[2].longitude)
        let plans = source.fuelChainRequests.filter { $0.fuel.probeFirstReachableStation != true }
        #expect(plans.count == 1)
        #expect(plans.first?.locations.first?.longitude == pumps[2].longitude)
        #expect(progressResults.allSatisfy {
            Array($0.legs.prefix(3)) == Array(first.legs.prefix(3))
        })
    }

    @Test func fuelStopOverrideIsSeparateFromProfileAndForcesDepartureStation() async throws {
        let points = [point(0), point(1)]
        let chosen = point(0.5)
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 300_000
        source.distances[key(points[0], chosen)] = 150_000
        source.distances[key(chosen, points[1])] = 150_000
        source.fuelStops = [fuelStop("chosen-pump", at: chosen)]
        let initial = makeItinerary(points)
        let riderLeg = try #require(initial.legs.first)
        let departure = riderLeg.from.uuidString
        let change = reduce(
            initial,
            .setFuelStopOverride(
                legID: riderLeg.id,
                departureAnchorID: departure,
                stationID: "chosen-pump"
            )
        )

        #expect(change.itinerary.legs[0].fuelStopOverrides[departure] == "chosen-pump")
        #expect(change.itinerary.legs[0].hopOverrides.isEmpty)
        #expect(change.itinerary.legs[0].profile == riderLeg.profile)

        _ = await ItineraryBuilder().build(
            change.itinerary, from: 0, reuse: nil,
            fuel: FuelRangePrefs.Snapshot(
                tankMeters: 150_000,
                usableMeters: 150_000, reservePercent: 0
            ),
            source: .fixed(source), onProgress: { _ in }
        )
        let request = try #require(source.fuelChainRequests.first {
            $0.fuel.probeFirstReachableStation != true
        })
        #expect(request.fuel.requiredFirstStationId == "chosen-pump")
    }

    @Test func fuelCarriesAcrossOrdinaryWaypointWithoutExtraStop() async throws {
        let points = [point(0), point(1), point(2)]
        let stop = point(0.75)
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 300_000
        source.distances[key(points[1], points[2])] = 150_000
        source.distances[key(points[0], stop)] = 170_000
        source.distances[key(stop, points[1])] = 20_000
        source.fuelStops = [fuelStop("fuel-1", at: stop)]

        let result = await build(points, source: source, usable: 180_000)

        #expect(source.fuelChainRequests.filter {
            $0.fuel.probeFirstReachableStation != true
        }.count >= 2)
        #expect(result.legs.filter { $0.endsAtFuelStop != nil }.count == 1)
        let firstLegID = try #require(result.legs.first?.riderLegID)
        let firstRiderLeg = result.legs.filter { $0.riderLegID == firstLegID }
        #expect(firstRiderLeg.last?.fuelUsedOnArrivalMeters == 20_000)
        let secondRiderLeg = result.legs.first { $0.riderLegID != firstLegID }
        #expect(secondRiderLeg?.fuelUsedOnArrivalMeters == 170_000)
    }

    @Test func regression195931RefuelsBeforeWaypointUsingKnownNextDistance() async throws {
        let points = [point(0), point(1), point(2)]
        let stop = point(0.9)
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 229_000
        source.distances[key(points[1], points[2])] = 200_000
        source.distances[key(points[0], stop)] = 220_000
        source.distances[key(stop, points[1])] = 9_000
        source.fuelStops = [fuelStop("fuel-before-point-2", at: stop)]

        let result = await build(points, source: source, usable: 237_500)

        let request = try #require(source.fuelChainRequests.first { $0.fuel.probeFirstReachableStation != true })
        #expect(request.fuel.destinationFuelUsedLimitMeters != nil)
        #expect(result.legs.filter { $0.endsAtFuelStop != nil }.count == 1)
        let firstLegID = try #require(result.legs.first?.riderLegID)
        let second = try #require(result.legs.first { $0.riderLegID != firstLegID })
        #expect(second.fuelUsedOnArrivalMeters == 209_000)
        #expect(result.riderLegStatus.values.allSatisfy { $0 == .built })
    }

    @Test func refuelsBeforeWaypointsAcrossThreeKnownRiderLegs() async throws {
        let points = [point(0), point(1), point(2), point(3)]
        let stop1 = point(0.9)
        let stop2 = point(1.9)
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 200_000
        source.distances[key(points[1], points[2])] = 200_000
        source.distances[key(points[2], points[3])] = 60_000
        source.distances[key(points[0], stop1)] = 180_000
        source.distances[key(stop1, points[1])] = 20_000
        source.distances[key(points[1], stop2)] = 180_000
        source.distances[key(stop2, points[2])] = 20_000
        source.firstReachableStationMeters[key(points[1], points[2])] = 180_000
        source.firstReachableStationMeters[key(points[2], points[3])] = 60_000
        source.fuelStopResponses = [
            [fuelStop("fuel-before-2", at: stop1)],
            [],
            [fuelStop("fuel-before-3", at: stop2)],
            [],
            []
        ]

        let result = await build(points, source: source, usable: 237_500)

        let plans = source.fuelChainRequests.filter { $0.fuel.probeFirstReachableStation != true }
        #expect(plans.count == 5)
        #expect(plans[0].fuel.destinationFuelUsedLimitMeters == 57_500)
        #expect(plans[2].fuel.destinationFuelUsedLimitMeters == 177_500)
        #expect(result.legs.compactMap(\.endsAtFuelStop?.stationID) == ["fuel-before-2", "fuel-before-3"])
        #expect(result.legs.last?.fuelUsedOnArrivalMeters == 80_000)
        #expect(result.riderLegStatus.values.allSatisfy { $0 == .built })
    }

    @Test func itineraryLookaheadChoosesLatePumpAndCompletesAllThreeLegs() async throws {
        let points = [point(0), point(1), point(2), point(3)]
        let early = point(0.2)
        let late = point(0.8)
        let next = point(1.6)
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 230_000
        source.distances[key(points[1], points[2])] = 190_000
        source.distances[key(points[2], points[3])] = 150_000
        source.distances[key(points[0], late)] = 180_000
        source.distances[key(late, points[1])] = 50_000
        source.distances[key(points[1], next)] = 120_000
        source.distances[key(next, points[2])] = 70_000
        source.firstReachableStationMeters[key(points[0], points[1])] = 44_000
        source.firstReachableStationMeters[key(points[1], points[2])] = 120_000
        source.firstReachableStationMeters[key(points[2], points[3])] = 150_000
        source.fuelStopResponses = [
            [fuelStop("late-180", at: late)],
            [],
            [fuelStop("next-120", at: next)],
            [],
            []
        ]
        _ = early

        let result = await build(points, source: source, usable: 237_500)

        #expect(result.legs.compactMap(\.endsAtFuelStop?.stationID) == ["late-180", "next-120"])
        #expect(result.riderLegStatus.values.allSatisfy { $0 == .built })
        #expect(result.legs.last?.fuelUsedOnArrivalMeters == 220_000)
        let plans = source.fuelChainRequests.filter { $0.fuel.probeFirstReachableStation != true }
        #expect(plans.first?.fuel.destinationFuelUsedLimitMeters == 117_500)
    }

    @Test func riderWaypointOnStationResetsTankWithoutGeneratedStop() async throws {
        let points = [point(0), point(1), point(2)]
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 200_000
        source.distances[key(points[1], points[2])] = 200_000
        source.waypointFuelStations[key(points[1], points[1])] = fuelStop(
            "irving-antigonish", at: points[1]
        )

        let result = await build(points, source: source, usable: 237_500)

        #expect(result.legs.compactMap(\.endsAtFuelStop).isEmpty)
        #expect(result.legs.first?.fuelUsedOnArrivalMeters == 0)
        #expect(result.legs.last?.fuelUsedOnArrivalMeters == 200_000)
        #expect(result.waypointFuelStops.values.first?.name == "irving-antigonish")
        #expect(source.fuelChainRequests.filter {
            $0.fuel.probeFirstReachableStation != true
        }.count == 1)
    }

    @Test func appendingPointThreeKeepsAutomaticFuelContinuityWithoutUnneededProbes() async throws {
        let point1 = point(0)
        let point2 = point(1)
        let point3 = point(2)
        let automaticFuel = point(0.72)
        let source = FakeRoutingSource(name: "live")
        source.distances[key(point1, point2)] = 220_000
        source.distances[key(point1, automaticFuel)] = 150_000
        source.distances[key(automaticFuel, point2)] = 70_000
        source.distances[key(point2, point3)] = 100_000
        source.fuelStopResponses = [
            [fuelStop("automatic-f1", at: automaticFuel)],
            []
        ]
        let builder = ItineraryBuilder()
        let fuel = FuelRangePrefs.Snapshot(
            tankMeters: 200_000, usableMeters: 190_000, reservePercent: 5
        )

        let initial = makeItinerary([point1, point2], profile: .balanced)
        let first = await builder.build(
            initial, from: 0, reuse: nil, fuel: fuel,
            source: .fixed(source), onProgress: { _ in }
        )
        #expect(first.legs.compactMap(\.endsAtFuelStop?.stationID) == ["automatic-f1"])

        source.fuelChainRequests.removeAll()
        source.fuelStopResponses = [[]]
        let change = reduce(initial, .append(coordinate: point3))
        let rebuildIndex = try #require(change.rebuildFromLegIndex)
        let rebuilt = await builder.build(
            change.itinerary, from: rebuildIndex, reuse: first, fuel: fuel,
            source: .fixed(source), onProgress: { _ in }
        )

        #expect(rebuilt.legs.compactMap(\.endsAtFuelStop?.stationID) == ["automatic-f1"])
        #expect(rebuilt.riderLegStatus.values.allSatisfy { $0 == .built })
        #expect(rebuilt.legs.last?.fuelUsedOnArrivalMeters == 170_000)
        let safetyProbes = source.fuelChainRequests.filter {
            $0.fuel.probeFirstReachableStation == true
        }
        #expect(safetyProbes.count == 1)
        #expect(safetyProbes.first?.fuel.riderLegId == "destination-escape")
    }

    @Test func ordinaryWaypointNeverResetsFuel() async throws {
        let points = [point(0), point(1), point(2)]
        let stop = point(0.5)
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 200_000
        source.distances[key(points[1], points[2])] = 200_000
        source.distances[key(points[0], stop)] = 150_000
        source.distances[key(stop, points[1])] = 50_000
        source.fuelStops = [fuelStop("auto-1", at: stop)]

        let result = await build(points, source: source, usable: 237_500)

        #expect(result.waypointFuelStops.isEmpty)
        #expect(result.legs.contains { $0.endsAtFuelStop != nil })
    }

    @Test func draggingWaypointOffStationRemovesResetAndReplansFuel() async throws {
        let origin = point(0)
        let onStation = point(1)
        let destination = point(2)
        let dragged = point(1.2)
        let auto = point(0.5)
        let source = FakeRoutingSource(name: "live")
        source.distances[key(origin, onStation)] = 200_000
        source.distances[key(onStation, destination)] = 200_000
        source.distances[key(origin, dragged)] = 210_000
        source.distances[key(dragged, destination)] = 190_000
        source.distances[key(origin, auto)] = 150_000
        source.distances[key(auto, dragged)] = 60_000
        source.distances[key(auto, destination)] = 250_000
        source.waypointFuelStations[key(onStation, onStation)] = fuelStop(
            "irving-antigonish", at: onStation
        )
        source.fuelStops = [fuelStop("auto-1", at: auto)]

        let on = await build([origin, onStation, destination], source: source, usable: 237_500)
        #expect(on.waypointFuelStops.values.first?.name == "irving-antigonish")
        #expect(on.legs.compactMap(\.endsAtFuelStop).isEmpty)
        #expect(source.fuelChainRequests.filter {
            $0.fuel.probeFirstReachableStation != true
        }.count == 1)

        source.fuelChainRequests.removeAll()
        let off = await build([origin, dragged, destination], source: source, usable: 237_500)
        #expect(off.waypointFuelStops.isEmpty)
        #expect(off.legs.contains { $0.endsAtFuelStop?.stationID == "auto-1" })
    }

    @Test func staleResultIsDroppedAfterGenerationChangesMidAwait() async {
        let points = [point(0), point(1)]
        let itinerary = makeItinerary(points)
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 100_000
        source.suspendNextRoute = true
        let builder = ItineraryBuilder()
        var progress = 0

        let task = Task { @MainActor in
            await builder.build(
                itinerary, from: 0, reuse: nil, fuel: .routeOnly,
                source: .fixed(source)
            ) { _ in progress += 1 }
        }
        while source.pendingRouteContinuation == nil { await Task.yield() }
        builder.setCurrentGeneration(itinerary.generation + 1)
        source.resumeRoute()
        let result = await task.value

        #expect(progress == 0)
        #expect(result.legs.isEmpty)
    }

    @Test func rebuildFromSecondLegReusesFirstBuiltLeg() async throws {
        let points = [point(0), point(1), point(2)]
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 100_000
        source.distances[key(points[1], points[2])] = 120_000
        let firstItinerary = makeItinerary(points)
        let builder = ItineraryBuilder()
        let first = await builder.build(
            firstItinerary, from: 0, reuse: nil, fuel: .routeOnly,
            source: .fixed(source), onProgress: { _ in }
        )
        let change = reduce(
            firstItinerary,
            .move(waypointID: firstItinerary.waypoints[2].id, to: point(2.1))
        )
        source.distances[key(points[1], point(2.1))] = 125_000
        source.routeRequests.removeAll()

        let second = await builder.build(
            change.itinerary, from: 1, reuse: first, fuel: .routeOnly,
            source: .fixed(source), onProgress: { _ in }
        )

        #expect(second.legs.first == first.legs.first)
        #expect(source.routeRequests.count == 1)
    }

    @Test func changingSecondLegProfileReusesFirstBuiltLegExactly() async throws {
        let points = [point(0), point(1), point(2)]
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 100_000
        source.distances[key(points[1], points[2])] = 120_000
        let firstItinerary = makeItinerary(points)
        let builder = ItineraryBuilder()
        let first = await builder.build(
            firstItinerary, from: 0, reuse: nil, fuel: .routeOnly,
            source: .fixed(source), onProgress: { _ in }
        )
        let secondLegID = try #require(firstItinerary.legs.last?.id)
        let change = reduce(
            firstItinerary,
            .setProfile(legID: secondLegID, .cleanest)
        )
        let rebuildIndex = try #require(change.rebuildFromLegIndex)
        source.routeRequests.removeAll()

        let second = await builder.build(
            change.itinerary, from: rebuildIndex, reuse: first, fuel: .routeOnly,
            source: .fixed(source), onProgress: { _ in }
        )

        #expect(rebuildIndex == 1)
        #expect(second.legs.first == first.legs.first)
        #expect(source.routeRequests.count == 1)
        #expect(source.routeRequests.first?.profile == .cleanest)
        #expect(source.routeRequests.first?.accessPolicy.motorizedUnknown == false)
    }

    @Test func failureKeepsEarlierBuiltLegAndLeavesLaterPending() async {
        let points = [point(0), point(1), point(2), point(3)]
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 100_000
        source.failKey = key(points[1], points[2])
        let itinerary = makeItinerary(points)

        let result = await ItineraryBuilder().build(
            itinerary, from: 0, reuse: nil, fuel: .routeOnly,
            source: .fixed(source), onProgress: { _ in }
        )

        #expect(result.legs.count == 1)
        #expect(result.riderLegStatus[itinerary.legs[0].id] == .built)
        if case .failed = result.riderLegStatus[itinerary.legs[1].id] {
            #expect(true)
        } else {
            Issue.record("Expected failed middle leg")
        }
        #expect(result.riderLegStatus[itinerary.legs[2].id] == .pending)
    }

    @Test func builderOutputIsIndependentOfSelectedSourceName() async {
        let points = [point(0), point(1)]
        let live = FakeRoutingSource(name: "live")
        let pack = FakeRoutingSource(name: "pack")
        live.distances[key(points[0], points[1])] = 90_000
        pack.distances = live.distances

        let liveResult = await build(points, source: live, usable: nil)
        let packResult = await build(points, source: pack, usable: nil)

        #expect(liveResult.legs.map { $0.response.distanceMeters } == packResult.legs.map { $0.response.distanceMeters })
        #expect(liveResult.legs.map { $0.fuelUsedOnArrivalMeters } == packResult.legs.map { $0.fuelUsedOnArrivalMeters })
        #expect(liveResult.riderLegStatus.values.map(String.init(describing:)).sorted()
            == packResult.riderLegStatus.values.map(String.init(describing:)).sorted())
        #expect(pack.routeRequests.count == 1)
    }

    @Test func routeCacheIsLRUAndNeverExceeds64Entries() {
        let cache = RouteResponseCache(capacity: 100)
        var firstKey: RouteResponseCache.Key?
        for index in 0..<65 {
            let from = point(Double(index))
            let to = point(Double(index) + 0.1)
            let cacheKey = RouteResponseCache.Key(
                from: from, to: to, profile: .dirt, allowUnknown: false,
                avoidEdgeIDs: [], priorEdgeIDs: [], arrivalEdgeID: nil, backtrackFactor: 4,
                sessionSeed: nil, directExtraBudgetMeters: nil,
                regionalHopMinimumMeters: [],
                sourceName: "live", packRevision: "test",
                cleanMetroMultiplier: nil,
                avoidMotorways: false,
                preferBackRoads: false
            )
            if index == 0 { firstKey = cacheKey }
            cache.insert(response(from: from, to: to, meters: Double(index + 1)), for: cacheKey)
        }
        #expect(cache.count == 64)
        #expect(firstKey.flatMap { cache.value(for: $0) } == nil)
    }

    @Test func routeCacheNeverReusesGeometryAcrossRoutingConstraints() {
        func cacheKey(avoid: [String], seed: UInt64?) -> RouteResponseCache.Key {
            RouteResponseCache.Key(
                from: point(0), to: point(1), profile: .dirt, allowUnknown: false,
                avoidEdgeIDs: avoid, priorEdgeIDs: [], arrivalEdgeID: nil,
                backtrackFactor: 4, sessionSeed: seed,
                directExtraBudgetMeters: nil, regionalHopMinimumMeters: [],
                sourceName: "live", packRevision: "test",
                cleanMetroMultiplier: nil, avoidMotorways: false,
                preferBackRoads: false
            )
        }
        #expect(cacheKey(avoid: [], seed: 1) != cacheKey(avoid: ["blocked-edge"], seed: 1))
        #expect(cacheKey(avoid: [], seed: 1) != cacheKey(avoid: [], seed: 2))
    }
}

@MainActor
struct IncrementalItineraryRebuildTests {
    @Test func completedFuelPrefixRemainsVisibleAndCarriesRangeIntoAppendedLeg() async throws {
        let point1 = point(0)
        let point2 = point(1)
        let point3 = point(2)
        let automaticFuel = point(0.72)
        let source = FakeRoutingSource(name: "live")
        source.distances[key(point1, point2)] = 220_000
        source.distances[key(point1, automaticFuel)] = 150_000
        source.distances[key(automaticFuel, point2)] = 70_000
        source.distances[key(point2, point3)] = 100_000
        source.fuelStopResponses = [
            [fuelStop("automatic-f1", at: automaticFuel)],
            []
        ]
        let builder = ItineraryBuilder()
        let fuel = FuelRangePrefs.Snapshot(
            tankMeters: 200_000, usableMeters: 190_000, reservePercent: 5
        )

        let initial = makeItinerary([point1, point2], profile: .balanced)
        let first = await builder.build(
            initial, from: 0, reuse: nil, fuel: fuel,
            source: .fixed(source), onProgress: { _ in }
        )
        let change = reduce(initial, .append(coordinate: point3))
        let rebuildIndex = try #require(change.rebuildFromLegIndex)
        source.fuelStopResponses = [[]]

        let rebuilt = await builder.build(
            change.itinerary, from: rebuildIndex, reuse: first, fuel: fuel,
            source: .fixed(source), onProgress: { _ in }
        )

        #expect(rebuilt.legs.prefix(first.legs.count).elementsEqual(first.legs))
        #expect(rebuilt.legs.compactMap(\.endsAtFuelStop?.stationID) == ["automatic-f1"])
        #expect(rebuilt.legs.last?.fuelUsedOnArrivalMeters == 170_000)
        #expect(rebuilt.riderLegStatus.values.allSatisfy { $0 == .built })
    }

    @Test func appendedWaypointCanMoveFuelDecisionIntoPriorLegWithoutRebuildingUpstream() async throws {
        let points = [point(0), point(1), point(2), point(3), point(4)]
        let latePump = point(2.8)
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 100_000
        source.distances[key(points[1], points[2])] = 100_000
        source.distances[key(points[2], points[3])] = 154_000
        source.distances[key(points[3], points[4])] = 77_000
        source.distances[key(points[2], latePump)] = 120_000
        source.distances[key(latePump, points[3])] = 34_000
        let fuel = FuelRangePrefs.Snapshot(
            tankMeters: 450_000, usableMeters: 382_500, reservePercent: 15
        )
        let builder = ItineraryBuilder()
        let initial = makeItinerary(Array(points.prefix(4)), profile: .dirt)
        let first = await builder.build(
            initial,
            from: 0,
            reuse: nil,
            fuel: fuel,
            source: .fixed(source),
            onProgress: { _ in }
        )
        #expect(first.legs.compactMap(\.endsAtFuelStop).isEmpty)
        #expect(first.legs.last?.fuelUsedOnArrivalMeters == 354_000)

        source.fuelStops = [fuelStop("late-before-point-4", at: latePump)]
        source.gapWhenFirstLegMaxBelow[key(points[3], points[4])] = 30_000
        let change = reduce(initial, .append(coordinate: points[4]))
        let rebuildIndex = try #require(change.rebuildFromLegIndex)

        let rebuilt = await builder.build(
            change.itinerary,
            from: rebuildIndex,
            reuse: first,
            fuel: fuel,
            source: .fixed(source),
            onProgress: { _ in }
        )

        #expect(Array(rebuilt.legs.prefix(2)) == Array(first.legs.prefix(2)))
        #expect(rebuilt.legs.compactMap(\.endsAtFuelStop?.stationID) == ["late-before-point-4"])
        #expect(rebuilt.legs.last?.toCoordinate == points[4])
        #expect(rebuilt.legs.last?.fuelUsedOnArrivalMeters == 111_000)
        #expect(rebuilt.riderLegStatus.values.allSatisfy { $0 == .built })
        #expect(source.fuelChainRequests.contains {
            $0.fuel.requireFuelStopBeforeEnd
                && $0.fuel.riderLegId == change.itinerary.legs[2].id.uuidString
        })
    }

    @Test func appendDuringAnIncompleteBuildRestartsAtFirstMissingRiderLeg() async throws {
        let points = [point(0), point(1), point(2), point(3)]
        let itinerary = makeItinerary(points, profile: .cleanest)
        let firstResponse = response(from: points[0], to: points[1], meters: 100_000)
        let firstBuilt = BuiltLeg(
            riderLegID: itinerary.legs[0].id,
            fromCoordinate: points[0],
            toCoordinate: points[1],
            endsAtFuelStop: nil,
            response: firstResponse,
            fuelUsedOnArrivalMeters: 100_000,
            routeProfile: .cleanest
        )
        let partial = BuiltItinerary(
            generation: itinerary.generation - 1,
            legs: [firstBuilt],
            riderLegStatus: [
                itinerary.legs[0].id: .built,
                itinerary.legs[1].id: .pending,
                itinerary.legs[2].id: .pending
            ],
            riderRoutes: [itinerary.legs[0].id: firstResponse]
        )
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[1], points[2])] = 100_000
        source.distances[key(points[2], points[3])] = 100_000

        let rebuilt = await ItineraryBuilder().build(
            itinerary,
            from: 2,
            reuse: partial,
            fuel: FuelRangePrefs.Snapshot(
                tankMeters: 500_000, usableMeters: 500_000, reservePercent: 0
            ),
            source: .fixed(source),
            onProgress: { _ in }
        )

        #expect(rebuilt.legs.count == 3)
        #expect(rebuilt.legs.first == firstBuilt)
        #expect(rebuilt.legs.last?.fuelUsedOnArrivalMeters == 300_000)
        #expect(rebuilt.riderLegStatus.values.allSatisfy { $0 == .built })
        #expect(source.routeRequests.count == 2)
        #expect(source.routeRequests.first?.locations.first?.longitude == points[1].longitude)
    }
}

@MainActor
private final class FakeRoutingSource: RoutingSource {
    let name: String
    var supportsCombinedFuelPlanning = false
    var distances: [String: Double] = [:]
    var fuelStops: [FuelChainStop] = []
    var fuelStopResponses: [[FuelChainStop]] = []
    var fuelGraphMeterResponses: [[Double]] = []
    var fuelWindowCompleteResponses: [Bool] = []
    var stationCandidates: [FuelStationCandidate] = []
    var routeRequests: [RouteRequest] = []
    var fuelChainRequests: [FuelChainRequest] = []
    var waypointFuelStations: [String: FuelChainStop] = [:]
    var firstReachableStationMeters: [String: Double] = [:]
    var gapWhenFirstLegMaxBelow: [String: Double] = [:]
    var failKey: String?
    var fuelChainError: Error?
    var suspendNextRoute = false
    var pendingRouteContinuation: CheckedContinuation<Void, Never>?

    init(name: String) { self.name = name }

    func route(_ req: RouteRequest) async throws -> RouteResponse {
        routeRequests.append(req)
        if suspendNextRoute {
            suspendNextRoute = false
            await withCheckedContinuation { pendingRouteContinuation = $0 }
        }
        let pair = try endpoints(req)
        let routeKey = key(pair.0, pair.1)
        if routeKey == failKey { throw RoutingError.server("scripted failure") }
        guard let meters = distances[routeKey] else {
            throw RoutingError.server("missing scripted route \(routeKey)")
        }
        return response(from: pair.0, to: pair.1, meters: meters)
    }

    func fuelChain(_ req: FuelChainRequest) async throws -> FuelChainResponse {
        fuelChainRequests.append(req)
        if let fuelChainError { throw fuelChainError }
        let pair = (
            RouteCoordinate(longitude: req.locations[0].longitude, latitude: req.locations[0].latitude),
            RouteCoordinate(longitude: req.locations[1].longitude, latitude: req.locations[1].latitude)
        )
        if req.fuel.probeFirstReachableStation == true {
            let scripted = firstReachableStationMeters[key(pair.0, pair.1)]
            let defaultDestinationEscape = pair.0 == pair.1 ? 10_000.0 : nil
            return FuelChainResponse(
                status: "complete", error: nil, message: nil, regionIds: ["test"],
                stops: [], graphMeters: nil,
                diagnostics: FuelChainDiagnostics(
                    strategy: "fake-probe", states: 1, dijkstraPops: 1,
                    matchedFuel: 0, elapsedMs: 1
                ),
                firstReachableStationMeters: scripted ?? defaultDestinationEscape
            )
        }
        if let threshold = gapWhenFirstLegMaxBelow[key(pair.0, pair.1)],
           req.fuel.firstLegMaxMeters < threshold {
            return FuelChainResponse(
                status: "gap",
                error: "no_forward_fuel_chain",
                message: "No forward, route-connected fuel chain fits the usable range.",
                regionIds: ["test"],
                stops: [],
                graphMeters: nil,
                diagnostics: FuelChainDiagnostics(
                    strategy: "fake-gap", states: 1, dijkstraPops: 1,
                    matchedFuel: fuelStops.count, elapsedMs: 1
                ),
                gapMeters: distances[key(pair.0, pair.1)]
            )
        }
        let selectedStops: [FuelChainStop]
        if !fuelStopResponses.isEmpty {
            selectedStops = fuelStopResponses.removeFirst()
        } else {
            let directMeters = distances[key(pair.0, pair.1)]
            let comfort = FuelItinerary.comfortCapMeters(
                firstLegMaxMeters: req.fuel.firstLegMaxMeters,
                usableRangeMeters: req.fuel.usableRangeMeters
            )
            let destinationLimit = req.fuel.destinationFuelUsedLimitMeters ?? .infinity
            if let directMeters,
               directMeters <= req.fuel.firstLegMaxMeters + 1,
               directMeters <= comfort + 1,
               directMeters <= destinationLimit + 1,
               req.fuel.requireFuelStopBeforeEnd == false,
               req.fuel.minimumFuelStops == 0 {
                selectedStops = []
            } else {
                let excluded = Set(req.fuel.excludedStationIds ?? [])
                if let required = req.fuel.requiredFirstStationId {
                    selectedStops = fuelStops.first(where: {
                        $0.id == required && !excluded.contains($0.id) && $0.coordinate != pair.0
                    }).map { [$0] } ?? []
                } else {
                    selectedStops = fuelStops.first(where: {
                        !excluded.contains($0.id) && $0.coordinate != pair.0
                    }).map { [$0] } ?? []
                }
            }
        }
        let windowComplete = fuelWindowCompleteResponses.isEmpty
            ? true
            : fuelWindowCompleteResponses.removeFirst()
        let graphMeters = fuelGraphMeterResponses.isEmpty
            ? nil
            : fuelGraphMeterResponses.removeFirst()
        let routePoints = [pair.0] + selectedStops.map(\.coordinate)
            + (windowComplete ? [pair.1] : [])
        let plannedRoutes: [RouteResponse]? = supportsCombinedFuelPlanning
            ? zip(routePoints, routePoints.dropFirst()).compactMap { endpoints in
                distances[key(endpoints.0, endpoints.1)].map {
                    response(from: endpoints.0, to: endpoints.1, meters: $0)
                }
            }
            : nil
        return FuelChainResponse(
            status: "complete", error: nil, message: nil, regionIds: ["test"],
            stops: selectedStops, graphMeters: graphMeters,
            diagnostics: FuelChainDiagnostics(
                strategy: "fake", states: 1, dijkstraPops: 1,
                matchedFuel: selectedStops.count, elapsedMs: 1
            ),
            routes: plannedRoutes,
            stationCandidates: stationCandidates,
            windowComplete: windowComplete
        )
    }

    func fuelStation(near point: RouteCoordinate, within meters: Double) async throws -> FuelChainStop? {
        waypointFuelStations[key(point, point)]
    }

    func resumeRoute() {
        let continuation = pendingRouteContinuation
        pendingRouteContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private func build(
    _ points: [RouteCoordinate],
    source: FakeRoutingSource,
    usable: Double?,
    profile: RouteProfile = .dirt
) async -> BuiltItinerary {
    let fuel = usable.map {
        FuelRangePrefs.Snapshot(
            tankMeters: $0, usableMeters: $0, reservePercent: 0
        )
    } ?? .routeOnly
    return await ItineraryBuilder().build(
        makeItinerary(points, profile: profile), from: 0, reuse: nil, fuel: fuel,
        source: .fixed(source), onProgress: { _ in }
    )
}

private func makeItinerary(
    _ points: [RouteCoordinate],
    profile: RouteProfile = .dirt
) -> RiderItinerary {
    reduce(
        RiderItinerary(),
        .replaceAll(waypoints: points, profile: profile, allowUnknown: false, avoidMotorways: false, preferBackRoads: false)
    ).itinerary
}

private func point(_ value: Double) -> RouteCoordinate {
    RouteCoordinate(longitude: -63 + value, latitude: 45 + value / 10)
}

private func key(_ from: RouteCoordinate, _ to: RouteCoordinate) -> String {
    "\(from.latitude),\(from.longitude)>\(to.latitude),\(to.longitude)"
}

private func endpoints(_ req: RouteRequest) throws -> (RouteCoordinate, RouteCoordinate) {
    guard req.locations.count == 2 else { throw RoutingError.invalidEndpoints }
    return (
        RouteCoordinate(longitude: req.locations[0].longitude, latitude: req.locations[0].latitude),
        RouteCoordinate(longitude: req.locations[1].longitude, latitude: req.locations[1].latitude)
    )
}

private func response(
    from: RouteCoordinate,
    to: RouteCoordinate,
    meters: Double
) -> RouteResponse {
    RouteResponse(
        status: "complete", error: nil, message: nil,
        distanceMeters: meters,
        estimatedMovingSeconds: nil, estimatedElapsedSeconds: nil,
        geometry: [from, to], segments: nil,
        stats: RouteStats(dirtPercent: 80, pavedPercent: 20),
        maneuvers: nil, warnings: nil,
        dirtPercentValue: nil, pavedPercentValue: nil
    )
}

private func fuelStop(_ id: String, at point: RouteCoordinate) -> FuelChainStop {
    FuelChainStop(
        id: id, latitude: point.latitude, longitude: point.longitude,
        name: id, brand: nil, address: nil, graphMeters: nil
    )
}
