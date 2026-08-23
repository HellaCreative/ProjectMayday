import Foundation
import Testing
@testable import Dirt

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
        #expect(dirtPlans.count == 1)
        #expect(dirtPlans.first?.fuel.requireFuelStopBeforeEnd == true)
        #expect(dirt.legs.filter { $0.endsAtFuelStop != nil }.count == 1)
        let dirtMeters = dirt.legs.reduce(0.0) { $0 + ($1.response.distanceMeters ?? 0) }
        let dirtShare = dirt.legs.reduce(0.0) {
            $0 + Double($1.response.dirtPercent) * ($1.response.distanceMeters ?? 0)
        } / dirtMeters
        #expect(abs(dirtShare - 80) <= 10)

        let cleanSource = FakeRoutingSource(name: "live")
        cleanSource.distances[key(points[0], points[1])] = 200_000
        cleanSource.fuelStops = [fuelStop("unused", at: stop)]
        let clean = await build(points, source: cleanSource, usable: 237_500, profile: .cleanest)

        #expect(cleanSource.fuelChainRequests.filter { $0.fuel.probeFirstReachableStation != true }.isEmpty)
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

        #expect(result.legs.count == 1)
        #expect(result.legs.first?.response.distanceMeters == 300_000)
        if case .fuelUnknown(let message) = result.riderLegStatus[itinerary.legs[0].id] {
            #expect(message.contains("timed out"))
        } else {
            Issue.record("Expected an honest unknown-fuel state")
        }
    }

    @Test func longRiderLegUsesThreeStopWindowsAndCommitsEveryHop() async throws {
        let points = [point(0), point(1)]
        let stops = [point(0.2), point(0.4), point(0.6), point(0.8)]
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 900_000
        let hopPoints = [points[0]] + stops + [points[1]]
        for index in 0..<(hopPoints.count - 1) {
            source.distances[key(hopPoints[index], hopPoints[index + 1])] = 180_000
        }
        source.fuelStopResponses = [
            Array(stops.prefix(3).enumerated()).map { fuelStop("fuel-\($0.offset + 1)", at: $0.element) },
            [fuelStop("fuel-4", at: stops[3])]
        ]
        source.fuelWindowCompleteResponses = [false, true]
        let itinerary = makeItinerary(points)
        var progressiveHopCounts: [Int] = []

        let result = await ItineraryBuilder().build(
            itinerary, from: 0, reuse: nil,
            fuel: FuelRangePrefs.Snapshot(
                tankMeters: 237_500,
                usableMeters: 237_500, reservePercent: 0
            ),
            source: .fixed(source)
        ) { progress in
            progressiveHopCounts.append(progress.legs.count)
        }

        let plans = source.fuelChainRequests.filter { $0.fuel.probeFirstReachableStation != true }
        #expect(plans.count == 2)
        #expect(plans.allSatisfy { $0.fuel.windowMaxStops == 3 })
        #expect(plans.allSatisfy { $0.fuel.allowPartialWindow == true })
        #expect(plans.allSatisfy { $0.fuel.windowTimeBudgetMs == 5_800 })
        #expect(plans[1].locations[0].longitude == stops[2].longitude)
        #expect(result.legs.count == 5)
        #expect(result.legs.compactMap(\.endsAtFuelStop?.stationID)
            == ["fuel-1", "fuel-2", "fuel-3", "fuel-4"])
        #expect(progressiveHopCounts.contains(1))
        #expect(progressiveHopCounts.contains(2))
        #expect(progressiveHopCounts.contains(3))
        #expect(progressiveHopCounts.contains(4))
    }

    @Test func fuelHopProfileReusesUpstreamAndReplansFromDepartureStation() async throws {
        let points = [point(0), point(1)]
        let pumps = [point(0.25), point(0.5), point(0.75)]
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 500_000
        let chainPoints = [points[0]] + pumps + [points[1]]
        for index in 0..<(chainPoints.count - 1) {
            source.distances[key(chainPoints[index], chainPoints[index + 1])] = 125_000
        }
        source.distances[key(pumps[0], points[1])] = 375_000
        source.fuelStops = pumps.enumerated().map {
            fuelStop("fuel-\($0.offset + 1)", at: $0.element)
        }
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
            .setHopProfile(legID: riderLeg.id, stationID: "fuel-1", .dirt)
        )
        source.routeRequests.removeAll()
        source.fuelStops = []
        source.fuelStopResponses = [
            [fuelStop("fuel-2", at: pumps[1])],
            [fuelStop("fuel-3", at: pumps[2])],
            []
        ]
        source.fuelWindowCompleteResponses = [false, false, true]

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
            onProgress: { _ in }
        )

        #expect(second.legs.count == 4)
        #expect(second.legs[0] == first.legs[0])
        #expect(second.legs[0].endsAtFuelStop?.stationID == "fuel-1")
        #expect(second.legs[1].routeProfile == .dirt)
        #expect(second.legs.dropFirst().allSatisfy { $0.fromCoordinate != points[0] })
        let plans = source.fuelChainRequests.filter { $0.fuel.probeFirstReachableStation != true }
        #expect(plans.suffix(3).allSatisfy { $0.fuel.windowMaxStops == 1 })
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

        #expect(source.fuelChainRequests.filter { $0.fuel.probeFirstReachableStation != true }.count == 1)
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
        #expect(request.fuel.requireFuelStopBeforeEnd)
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
        source.fuelStopResponses = [
            [fuelStop("fuel-before-2", at: stop1)],
            [fuelStop("fuel-before-3", at: stop2)]
        ]

        let result = await build(points, source: source, usable: 237_500)

        let plans = source.fuelChainRequests.filter { $0.fuel.probeFirstReachableStation != true }
        #expect(plans.count == 2)
        #expect(plans.allSatisfy { $0.fuel.requireFuelStopBeforeEnd })
        #expect(plans[0].fuel.destinationFuelUsedLimitMeters == 57_500)
        #expect(plans[1].fuel.destinationFuelUsedLimitMeters == 177_500)
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
        source.fuelStopResponses = [
            [fuelStop("late-180", at: late)],
            [fuelStop("next-120", at: next)]
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
        #expect(source.fuelChainRequests.filter { $0.fuel.probeFirstReachableStation != true }.isEmpty)
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
                priorEdgeIDs: [], arrivalEdgeID: nil, backtrackFactor: 4,
                sourceName: "live", packRevision: "test",
                cleanMetroMultiplier: nil
            )
            if index == 0 { firstKey = cacheKey }
            cache.insert(response(from: from, to: to, meters: Double(index + 1)), for: cacheKey)
        }
        #expect(cache.count == 64)
        #expect(firstKey.flatMap { cache.value(for: $0) } == nil)
    }
}

@MainActor
private final class FakeRoutingSource: RoutingSource {
    let name: String
    var distances: [String: Double] = [:]
    var fuelStops: [FuelChainStop] = []
    var fuelStopResponses: [[FuelChainStop]] = []
    var fuelWindowCompleteResponses: [Bool] = []
    var routeRequests: [RouteRequest] = []
    var fuelChainRequests: [FuelChainRequest] = []
    var waypointFuelStations: [String: FuelChainStop] = [:]
    var firstReachableStationMeters: [String: Double] = [:]
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
            return FuelChainResponse(
                status: "complete", error: nil, message: nil, regionIds: ["test"],
                stops: [], graphMeters: nil,
                diagnostics: FuelChainDiagnostics(
                    strategy: "fake-probe", states: 1, dijkstraPops: 1,
                    matchedFuel: 0, elapsedMs: 1
                ),
                firstReachableStationMeters: firstReachableStationMeters[key(pair.0, pair.1)]
            )
        }
        let selectedStops = fuelStopResponses.isEmpty ? fuelStops : fuelStopResponses.removeFirst()
        let windowComplete = fuelWindowCompleteResponses.isEmpty
            ? true
            : fuelWindowCompleteResponses.removeFirst()
        return FuelChainResponse(
            status: "complete", error: nil, message: nil, regionIds: ["test"],
            stops: selectedStops, graphMeters: nil,
            diagnostics: FuelChainDiagnostics(
                strategy: "fake", states: 1, dijkstraPops: 1,
                matchedFuel: selectedStops.count, elapsedMs: 1
            ),
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
