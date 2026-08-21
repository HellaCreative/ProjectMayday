import Foundation
import Testing
@testable import Dirt

@MainActor
struct ItineraryBuilderTests {
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

        #expect(source.fuelChainRequests.count == 1)
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

        let request = try #require(source.fuelChainRequests.first)
        #expect(request.fuel.requireFuelStopBeforeEnd)
        #expect(result.legs.filter { $0.endsAtFuelStop != nil }.count == 1)
        let firstLegID = try #require(result.legs.first?.riderLegID)
        let second = try #require(result.legs.first { $0.riderLegID != firstLegID })
        #expect(second.fuelUsedOnArrivalMeters == 209_000)
        #expect(result.riderLegStatus.values.allSatisfy { $0 == .built })
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
                itinerary, from: 0, reuse: nil, fuel: .disabled,
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
            firstItinerary, from: 0, reuse: nil, fuel: .disabled,
            source: .fixed(source), onProgress: { _ in }
        )
        let change = reduce(
            firstItinerary,
            .move(waypointID: firstItinerary.waypoints[2].id, to: point(2.1))
        )
        source.distances[key(points[1], point(2.1))] = 125_000
        source.routeRequests.removeAll()

        let second = await builder.build(
            change.itinerary, from: 1, reuse: first, fuel: .disabled,
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
            firstItinerary, from: 0, reuse: nil, fuel: .disabled,
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
            change.itinerary, from: rebuildIndex, reuse: first, fuel: .disabled,
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
            itinerary, from: 0, reuse: nil, fuel: .disabled,
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
                sourceName: "live", packRevision: "test"
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
    var routeRequests: [RouteRequest] = []
    var fuelChainRequests: [FuelChainRequest] = []
    var failKey: String?
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
        return FuelChainResponse(
            status: "complete", error: nil, message: nil, regionIds: ["test"],
            stops: fuelStops, graphMeters: nil,
            diagnostics: FuelChainDiagnostics(
                strategy: "fake", states: 1, dijkstraPops: 1,
                matchedFuel: fuelStops.count, elapsedMs: 1
            )
        )
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
    usable: Double?
) async -> BuiltItinerary {
    let fuel = usable.map {
        FuelRangePrefs.Snapshot(
            isEnabled: true, tankMeters: $0, usableMeters: $0, reservePercent: 0
        )
    } ?? .disabled
    return await ItineraryBuilder().build(
        makeItinerary(points), from: 0, reuse: nil, fuel: fuel,
        source: .fixed(source), onProgress: { _ in }
    )
}

private func makeItinerary(_ points: [RouteCoordinate]) -> RiderItinerary {
    reduce(
        RiderItinerary(),
        .replaceAll(waypoints: points, profile: .dirt, allowUnknown: false)
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
