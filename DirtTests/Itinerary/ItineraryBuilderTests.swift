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
        #expect(dirtPlans.isEmpty)
        #expect(dirt.legs.filter { $0.endsAtFuelStop != nil }.isEmpty)
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
        }.isEmpty)
        #expect(clean.legs.count == 1)
        #expect(clean.legs.first?.endsAtFuelStop == nil)
    }

    @Test func single475KmLegStaysOneBuiltLeg() async throws {
        let points = [point(0), point(1)]
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 475_000

        let result = await build(points, source: source, usable: 237_500)

        #expect(result.legs.count == 1)
        #expect(result.legs[0].endsAtFuelStop == nil)
        #expect((result.legs[0].response.distanceMeters ?? 0) == 475_000)
        #expect(source.fuelChainRequests.isEmpty)
    }

    @Test func fuelNotificationsOffBuildsTheRideWithoutFuelRequests() async throws {
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
                notificationsEnabled: false
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

    @Test func enabledFuelRangeDoesNotConsultFuelOrPlaceStops() async throws {
        let points = [point(0), point(1)]
        let source = FakeRoutingSource(name: "live")
        source.supportsCombinedFuelPlanning = true
        source.distances[key(points[0], points[1])] = 300_000
        source.fuelStops = [fuelStop("fuel-1", at: point(0.5))]

        let result = await build(points, source: source, usable: 150_000)

        #expect(result.legs.count == 1)
        #expect(result.legs.first?.endsAtFuelStop == nil)
        #expect(source.fuelChainRequests.isEmpty)
        #expect(source.routeRequests.count == 1)
        #expect(result.riderLegStatus.values.allSatisfy {
            if case .gap = $0 { return false }
            if case .fuelUnknown = $0 { return false }
            return $0 == .built
        })
    }

    @Test func multiLegBuildRoutesEachRiderLegWithoutFuel() async throws {
        let points = [point(0), point(1), point(2)]
        let source = FakeRoutingSource(name: "live")
        source.supportsCombinedFuelPlanning = true
        source.distances[key(points[0], points[1])] = 100_000
        source.distances[key(points[1], points[2])] = 100_000

        let result = await build(points, source: source, usable: 50_000)

        #expect(result.legs.count == 2)
        #expect(result.legs.allSatisfy { $0.endsAtFuelStop == nil })
        #expect(source.fuelChainRequests.isEmpty)
        #expect(source.routeRequests.count == 2)
        #expect(result.riderLegStatus.values.allSatisfy { $0 == .built })
    }

    @Test func fuelServiceErrorsDoNotProduceGapCards() async throws {
        let points = [point(0), point(1)]
        let source = FakeRoutingSource(name: "live")
        source.distances[key(points[0], points[1])] = 300_000
        source.fuelChainError = RoutingError.server("Fuel planning timed out")
        source.fuelUnknownNoStopMessage = "No fuel stop found"

        let result = await build(points, source: source, usable: 150_000)

        #expect(result.legs.count == 1)
        #expect(source.fuelChainRequests.isEmpty)
        #expect(result.riderLegStatus.values.allSatisfy {
            if case .gap = $0 { return false }
            if case .fuelUnknown = $0 { return false }
            return $0 == .built
        })
    }

    @Test func riderWaypointsDoNotSnapToStationsDuringBuild() async throws {
        let origin = point(0)
        let onStation = point(1)
        let destination = point(2)
        let source = FakeRoutingSource(name: "live")
        source.distances[key(origin, onStation)] = 200_000
        source.distances[key(onStation, destination)] = 200_000
        source.waypointFuelStations[key(onStation, onStation)] = fuelStop(
            "irving-antigonish", at: onStation
        )

        let result = await build([origin, onStation, destination], source: source, usable: 237_500)

        #expect(result.waypointFuelStops.isEmpty)
        #expect(result.legs.allSatisfy { $0.endsAtFuelStop == nil })
        #expect(source.fuelChainRequests.isEmpty)
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

    @Test func profileAndUnknownEditsRebuildOnlyOneLegOfFive() async throws {
        let points = (0...5).map { point(Double($0)) }
        let laterPump = point(4.5)
        let source = FakeRoutingSource(name: "live")
        source.supportsCombinedFuelPlanning = true
        for index in 0..<(points.count - 1) {
            source.distances[key(points[index], points[index + 1])] = 50_000
        }
        source.distances[key(points[4], laterPump)] = 25_000
        source.distances[key(laterPump, points[5])] = 25_000
        source.fuelStopResponses = [[], [], [], [], [
            fuelStop("untouched-later-pump", at: laterPump)
        ]]
        let fuel = FuelRangePrefs.Snapshot(
            tankMeters: 500_000,
            usableMeters: 500_000,
            reservePercent: 0
        )
        let initial = makeItinerary(points, profile: .balanced)
        let editedIndex = 2
        let editedLegID = initial.legs[editedIndex].id
        let builder = ItineraryBuilder()
        let first = await builder.build(
            initial, from: 0, reuse: nil, fuel: fuel,
            source: .fixed(source), onProgress: { _ in }
        )
        #expect(first.riderLegStatus.count == 5)
        #expect(first.legs.count == 5)
        #expect(first.legs.compactMap(\.endsAtFuelStop).isEmpty)
        #expect(source.fuelChainRequests.isEmpty)

        let profileChange = reduce(
            initial,
            .setProfile(legID: editedLegID, .dirt)
        )
        source.fuelChainRequests.removeAll()
        source.routeRequests.removeAll()
        let profiled = await builder.build(
            profileChange.itinerary,
            from: try #require(profileChange.rebuildFromLegIndex),
            through: profileChange.rebuildThroughLegIndex,
            reuse: first,
            fuel: fuel,
            source: .fixed(source),
            onProgress: { _ in }
        )

        #expect(source.fuelChainRequests.isEmpty)
        #expect(source.routeRequests.count == 1)
        #expect(source.routeRequests.first?.profile == .dirt)
        #expect(profiled.legs[editedIndex].routeProfile == .dirt)
        for index in profiled.legs.indices where index != editedIndex {
            #expect(profiled.legs[index] == first.legs[index])
        }

        let unknownChange = reduce(
            profileChange.itinerary,
            .setAllowUnknown(legID: editedLegID, true)
        )
        source.fuelChainRequests.removeAll()
        source.routeRequests.removeAll()
        let unknownAllowed = await builder.build(
            unknownChange.itinerary,
            from: try #require(unknownChange.rebuildFromLegIndex),
            through: unknownChange.rebuildThroughLegIndex,
            reuse: profiled,
            fuel: fuel,
            source: .fixed(source),
            onProgress: { _ in }
        )

        #expect(source.fuelChainRequests.isEmpty)
        #expect(source.routeRequests.count == 1)
        #expect(source.routeRequests.first?.accessPolicy.motorizedUnknown == true)
        #expect(unknownAllowed.legs.compactMap(\.endsAtFuelStop).isEmpty)
        for index in unknownAllowed.legs.indices where index != editedIndex {
            #expect(unknownAllowed.legs[index] == profiled.legs[index])
        }
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
                preferBackRoads: false,
                startEndpointKind: nil,
                endEndpointKind: nil
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
                preferBackRoads: false, startEndpointKind: nil,
                endEndpointKind: nil
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
        #expect(rebuilt.legs.compactMap(\.endsAtFuelStop).isEmpty)
        #expect(rebuilt.legs.count == first.legs.count + 1)
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
        #expect(first.legs.count == 3)

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
        #expect(rebuilt.legs.compactMap(\.endsAtFuelStop).isEmpty)
        #expect(rebuilt.legs.last?.toCoordinate == points[4])
        #expect(rebuilt.riderLegStatus.values.allSatisfy { $0 == .built })
        #expect(source.fuelChainRequests.isEmpty)
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
    var fuelFailureFoundation: RouteResponse?
    /// Script an unknown-status response whose message must still surface as a
    /// Fuel range gap card (no silent A→B).
    var fuelUnknownNoStopMessage: String?
    var fuelChainError: Error?
    var fuelChainErrorAfterPlanCount: Int?
    var fuelChainPlanCount = 0
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
        if let fuelFailureFoundation {
            return FuelChainResponse(status: "unknown", error: "window_time_budget",
                message: "Fuel proof timed out", regionIds: ["test"], stops: [], graphMeters: [],
                diagnostics: nil, foundationRoute: fuelFailureFoundation, windowComplete: false)
        }
        if let fuelUnknownNoStopMessage {
            return FuelChainResponse(
                status: "unknown", error: "fuel_not_proven",
                message: fuelUnknownNoStopMessage, regionIds: ["test"],
                stops: [], graphMeters: [], diagnostics: nil, windowComplete: false)
        }
        fuelChainPlanCount += 1
        if let limit = fuelChainErrorAfterPlanCount,
           fuelChainPlanCount > limit,
           let fuelChainError {
            throw fuelChainError
        }
        if fuelChainErrorAfterPlanCount == nil, let fuelChainError { throw fuelChainError }
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
            let comfort = ItineraryRangeArithmetic.comfortCapMeters(
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

@MainActor
struct FuelPlanningWindowPolicyTests {
    @Test func atlanticAndOfflineKeepExistingDeadline() {
        #expect(FuelPlanningWindowPolicy.milliseconds(regions: ["ns", "nb", "pe", "nl"], live: true) == 20_000)
        #expect(FuelPlanningWindowPolicy.milliseconds(regions: ["wa"], live: false) == 45_000)
        #expect(FuelPlanningWindowPolicy.milliseconds(regions: [], live: true) == 20_000)
        #expect(FuelPlanningWindowPolicy.transportSeconds(milliseconds: 20_000) == 23)
    }
    @Test func nationalAndMixedWindowsAllowColdPackPreparation() {
        #expect(FuelPlanningWindowPolicy.milliseconds(regions: ["wa"], live: true) == 90_000)
        #expect(FuelPlanningWindowPolicy.milliseconds(regions: ["nb", "me"], live: true) == 90_000)
        #expect(FuelPlanningWindowPolicy.transportSeconds(milliseconds: 90_000) == 100)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let watchdog = FuelPlanningProgressWatchdog(inactivityInterval: 105, now: start)
        #expect(!watchdog.isExpired(at: start.addingTimeInterval(100)))
        #expect(watchdog.isExpired(at: start.addingTimeInterval(105)))
    }
}
