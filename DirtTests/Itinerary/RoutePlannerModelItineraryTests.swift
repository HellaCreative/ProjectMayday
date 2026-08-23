import Foundation
import Testing
@testable import Dirt

@MainActor
@Suite(.serialized)
struct RoutePlannerModelItineraryTests {
    @Test func planModeUsesTheInstalledPackRegistry() async {
        let source = PlannerFakeRoutingSource()
        let registry = FakeInstalledPackRegistry(installedRegionIDs: ["ns"])
        var policyReports: [String] = []
        let policy = RoutingSourcePolicy(
            isOnline: { true },
            installedPacks: registry,
            live: source,
            pack: source,
            report: { policyReports.append($0) }
        )
        let model = makeModel(source: source, policy: policy)
        model.selectMode(.plan)
        model.apply(
            .replaceAll(
                waypoints: [
                    RouteCoordinate(longitude: -63.57, latitude: 44.65),
                    RouteCoordinate(longitude: -60.19, latitude: 46.14)
                ],
                profile: .dirt,
                allowUnknown: false
            ),
            source: "plan"
        )

        await model.waitForCanonicalBuildForTesting()

        #expect(policyReports.contains { report in
            report.contains("packsCover=true") && report.contains("installed=[ns]")
        })
        #expect(source.routeRequests.isEmpty == false)
    }

    @Test func fromHereFuelBuildSwitchesToPlanWithoutNetworkCalls() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 250
        FuelRangePrefs.reservePercent = 5

        let start = point(0)
        let stop = point(0.5)
        let end = point(1)
        let source = PlannerFakeRoutingSource()
        source.distanceOverrides[key(start, end)] = 475_000
        source.distanceOverrides[key(start, stop)] = 230_000
        source.distanceOverrides[key(stop, end)] = 230_000
        source.fuelStops = [fuelStop("fuel-1", at: stop)]
        let model = makeModel(source: source)

        model.apply(
            .replaceAll(waypoints: [start, end], profile: .dirt, allowUnknown: false),
            source: "fromHere"
        )
        await model.waitForCanonicalBuildForTesting()
        let callsBeforeConversion = source.routeRequests.count + source.fuelChainRequests.count
        let builtBeforeConversion = try #require(model.built)

        model.switchToPlanKeepingFromHere()

        #expect(model.itinerary.waypoints.count == 2)
        #expect(model.built?.legs.count == 2)
        #expect(model.built == builtBeforeConversion)
        #expect(source.routeRequests.count + source.fuelChainRequests.count == callsBeforeConversion)
    }

    @Test func insertAndDeleteMutateOnlyCanonicalWaypoints() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 250
        FuelRangePrefs.reservePercent = 5

        let start = point(0)
        let pump = point(0.2)
        let inserted = point(0.4)
        let end = point(1)
        let source = PlannerFakeRoutingSource()
        source.distanceOverrides[key(start, end)] = 100_000
        source.distanceOverrides[key(start, inserted)] = 300_000
        source.distanceOverrides[key(start, pump)] = 150_000
        source.distanceOverrides[key(pump, inserted)] = 150_000
        source.distanceOverrides[key(inserted, end)] = 50_000
        source.fuelStops = [fuelStop("fuel-after-insert", at: pump)]
        let model = makeModel(source: source)
        model.apply(
            .replaceAll(waypoints: [start, end], profile: .dirt, allowUnknown: false),
            source: "fromHere"
        )
        await model.waitForCanonicalBuildForTesting()
        let originalLeg = try #require(model.itinerary.legs.first)

        model.apply(.insert(afterLegID: originalLeg.id, coordinate: inserted), source: "tap")
        await model.waitForCanonicalBuildForTesting()

        #expect(model.itinerary.waypoints.map(\.coordinate) == [start, inserted, end])
        #expect(model.lastCanonicalBuildFromLegIndex == 0)
        #expect(model.built?.legs.first?.endsAtFuelStop?.stationID == "fuel-after-insert")
        #expect(model.built?.legs.first?.fuelUsedOnArrivalMeters == 0)

        let insertedID = model.itinerary.waypoints[1].id
        model.apply(.delete(waypointID: insertedID), source: "swipe")
        await model.waitForCanonicalBuildForTesting()

        #expect(model.itinerary.waypoints.map(\.coordinate) == [start, end])
        #expect(model.lastCanonicalBuildFromLegIndex == 0)
    }

    @Test func fiveRapidMovesCoalesceIntoOneBuild() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 0

        let source = PlannerFakeRoutingSource()
        let model = makeModel(source: source)
        model.apply(
            .replaceAll(waypoints: [point(0), point(0.5), point(1)], profile: .dirt, allowUnknown: false),
            source: "seed"
        )
        await model.waitForCanonicalBuildForTesting()
        let waypointID = model.itinerary.waypoints[1].id
        let buildsBeforeMoves = model.canonicalBuildStartCount

        for offset in 1...5 {
            model.apply(
                .move(waypointID: waypointID, to: point(0.5 + Double(offset) / 100)),
                source: "drag"
            )
        }
        try await Task.sleep(for: .milliseconds(500))
        await model.waitForCanonicalBuildForTesting()

        #expect(model.canonicalBuildStartCount == buildsBeforeMoves + 1)
        #expect(model.itinerary.waypoints[1].coordinate == point(0.55))
    }

    @Test func twoFuelStopsHaveDistinctStableIDsAndReplacingF1CascadesForward() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 250
        FuelRangePrefs.reservePercent = 5

        let start = point(0)
        let f1 = point(0.4)
        let f2 = point(0.7)
        let end = point(1)
        let f1Alt = point(0.42)
        let f2b = point(0.72)

        let source = PlannerFakeRoutingSource()
        source.distanceOverrides[key(start, end)] = 700_000
        source.distanceOverrides[key(start, f1)] = 200_000
        source.distanceOverrides[key(f1, f2)] = 230_000
        source.distanceOverrides[key(f2, end)] = 230_000
        source.distanceOverrides[key(start, f1Alt)] = 180_000
        source.distanceOverrides[key(f1Alt, f2b)] = 230_000
        source.distanceOverrides[key(f2b, end)] = 230_000
        source.distanceOverrides[key(f1Alt, end)] = 480_000
        source.fuelStops = [fuelStop("fuel-1", at: f1), fuelStop("fuel-2", at: f2)]
        source.fuelStopsByFrom[keyOrigin(start)] = [fuelStop("fuel-1", at: f1), fuelStop("fuel-2", at: f2)]
        source.fuelStopsByFrom[keyOrigin(f1Alt)] = [fuelStop("fuel-2b", at: f2b)]
        source.alternates = [
            FuelAlternate(
                stationID: "fuel-1-alt",
                coordinate: f1Alt,
                name: "Alt F1",
                isValid: true,
                fromPreviousMeters: 180_000,
                toNextMeters: 230_000
            ),
            FuelAlternate(
                stationID: "fuel-too-far",
                coordinate: point(0.9),
                name: "Out of range",
                isValid: false,
                fromPreviousMeters: 400_000,
                toNextMeters: 50_000
            )
        ]

        let model = makeModel(source: source)
        model.selectMode(.plan)
        model.apply(
            .replaceAll(waypoints: [start, end], profile: .dirt, allowUnknown: false),
            source: "fromHere"
        )
        await model.waitForCanonicalBuildForTesting()

        let builtBefore = try #require(model.built)
        let fuelBefore = builtBefore.legs.compactMap(\.endsAtFuelStop)
        #expect(fuelBefore.count == 2)
        #expect(fuelBefore[0].id != fuelBefore[1].id)
        #expect(fuelBefore[0].stationID == "fuel-1")
        #expect(fuelBefore[1].stationID == "fuel-2")
        let waypointIDs = model.itinerary.waypoints.map(\.id)
        let riderLegID = try #require(model.itinerary.legs.first?.id)

        let f1ID = fuelBefore[0].id
        await model.beginFuelReplacement(id: f1ID)
        #expect(model.replacingFuelStopID == f1ID)
        #expect(model.fuelReplacementCandidates.contains(where: { $0.stationID == "fuel-1-alt" && $0.isValid }))
        #expect(model.fuelReplacementCandidates.contains(where: { $0.stationID == "fuel-too-far" && !$0.isValid }))

        model.selectFuelAlternate(stationID: "fuel-1-alt")
        await model.waitForCanonicalBuildForTesting()

        let builtAfter = try #require(model.built)
        let fuelAfter = builtAfter.legs.compactMap(\.endsAtFuelStop)
        #expect(fuelAfter.count == 2)
        #expect(fuelAfter[0].id == f1ID)
        #expect(fuelAfter[0].stationID == "fuel-1-alt")
        #expect(fuelAfter[1].id != f1ID)
        #expect(fuelAfter[1].stationID == "fuel-2b")
        #expect(model.itinerary.waypoints.map(\.id) == waypointIDs)
        #expect(model.itinerary.waypoints.map(\.coordinate) == [start, end])
        #expect(model.itinerary.legs.first?.id == riderLegID)
        #expect(model.canDeleteFuelStop(f1ID) == false)
        model.moveWaypoint(markerID: "fuel:\(f1ID.uuidString)", to: point(0.5).locationCoordinate)
        #expect(model.built?.legs.compactMap(\.endsAtFuelStop).first?.stationID == "fuel-1-alt")
    }

    @Test func replacingF2LeavesF1AndUpstreamGeometryUnchanged() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 250
        FuelRangePrefs.reservePercent = 5

        let start = point(0)
        let f1 = point(0.4)
        let f2 = point(0.7)
        let end = point(1)
        let f2Alt = point(0.72)

        let source = PlannerFakeRoutingSource()
        source.distanceOverrides[key(start, end)] = 700_000
        source.distanceOverrides[key(start, f1)] = 200_000
        source.distanceOverrides[key(f1, f2)] = 230_000
        source.distanceOverrides[key(f2, end)] = 230_000
        source.distanceOverrides[key(f1, f2Alt)] = 210_000
        source.distanceOverrides[key(f2Alt, end)] = 230_000
        source.distanceOverrides[key(f1, end)] = 460_000
        source.fuelStops = [fuelStop("fuel-1", at: f1), fuelStop("fuel-2", at: f2)]
        source.fuelStopsByFrom[keyOrigin(start)] = [fuelStop("fuel-1", at: f1), fuelStop("fuel-2", at: f2)]
        source.fuelStopsByFrom[keyOrigin(f1)] = [fuelStop("fuel-2-alt", at: f2Alt)]
        source.alternates = [
            FuelAlternate(
                stationID: "fuel-2-alt",
                coordinate: f2Alt,
                name: "Alt F2",
                isValid: true,
                fromPreviousMeters: 210_000,
                toNextMeters: 230_000
            )
        ]

        let model = makeModel(source: source)
        model.selectMode(.plan)
        model.apply(
            .replaceAll(waypoints: [start, end], profile: .dirt, allowUnknown: false),
            source: "fromHere"
        )
        await model.waitForCanonicalBuildForTesting()

        let builtBefore = try #require(model.built)
        let fuelBefore = builtBefore.legs.compactMap(\.endsAtFuelStop)
        #expect(fuelBefore.count == 2)
        let f1Before = fuelBefore[0]
        let f2ID = fuelBefore[1].id
        let hopToF1 = try #require(builtBefore.legs.first)
        let startToF1Routes = source.routeRequests.filter { requestKey($0) == key(start, f1) }.count

        await model.beginFuelReplacement(id: f2ID)
        model.selectFuelAlternate(stationID: "fuel-2-alt")
        await model.waitForCanonicalBuildForTesting()

        let builtAfter = try #require(model.built)
        let fuelAfter = builtAfter.legs.compactMap(\.endsAtFuelStop)
        #expect(fuelAfter.count == 2)
        #expect(fuelAfter[0].id == f1Before.id)
        #expect(fuelAfter[0].stationID == "fuel-1")
        #expect(fuelAfter[0].coordinate == f1)
        #expect(builtAfter.legs.first == hopToF1)
        #expect(fuelAfter[1].id == f2ID)
        #expect(fuelAfter[1].stationID == "fuel-2-alt")
        #expect(source.routeRequests.filter { requestKey($0) == key(start, f1) }.count == startToF1Routes)
    }

    @Test func fromHereFuelHopsEditRideTypeAndAllowIndependently() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 250
        FuelRangePrefs.reservePercent = 5

        let start = point(0)
        let f1 = point(0.4)
        let f2 = point(0.7)
        let end = point(1)

        let source = PlannerFakeRoutingSource()
        source.distanceOverrides[key(start, end)] = 700_000
        source.distanceOverrides[key(start, f1)] = 200_000
        source.distanceOverrides[key(f1, f2)] = 230_000
        source.distanceOverrides[key(f2, end)] = 230_000
        source.fuelStops = [fuelStop("fuel-1", at: f1), fuelStop("fuel-2", at: f2)]
        source.fuelStopsByFrom[keyOrigin(start)] = [fuelStop("fuel-1", at: f1), fuelStop("fuel-2", at: f2)]

        let model = makeModel(source: source)
        model.selectMode(.fromHere)
        model.apply(
            .replaceAll(waypoints: [start, end], profile: .dirt, allowUnknown: false),
            source: "fromHere"
        )
        await model.waitForCanonicalBuildForTesting()

        #expect(model.stages.count == 3)
        #expect(model.stages.map(\.profile) == [.dirt, .dirt, .dirt])
        let hopToF1 = try #require(model.built?.legs.first)
        let startToF1Routes = source.routeRequests.filter { requestKey($0) == key(start, f1) }.count

        model.setStageProfile(.cleanest, at: 1)
        await model.waitForCanonicalBuildForTesting()
        model.setStageProfile(.dirt, at: 2)
        await model.waitForCanonicalBuildForTesting()

        #expect(model.stages.count == 3)
        #expect(model.stages.map(\.profile) == [.dirt, .cleanest, .dirt])
        #expect(model.built?.legs.first == hopToF1)
        #expect(source.routeRequests.filter { requestKey($0) == key(start, f1) }.count == startToF1Routes)

        let hopF1ToF2 = try #require(model.built?.legs[1])
        let f1ToF2Routes = source.routeRequests.filter { requestKey($0) == key(f1, f2) }.count
        model.setStageAllowUnknown(true, at: 2)
        await model.waitForCanonicalBuildForTesting()

        #expect(model.stages.map(\.profile) == [.dirt, .cleanest, .dirt])
        #expect(model.stages.map(\.allowUnknown) == [false, false, true])
        #expect(model.built?.legs.first == hopToF1)
        #expect(model.built?.legs[1] == hopF1ToF2)
        #expect(source.routeRequests.filter { requestKey($0) == key(start, f1) }.count == startToF1Routes)
        #expect(source.routeRequests.filter { requestKey($0) == key(f1, f2) }.count == f1ToF2Routes)
        #expect(source.routeRequests.filter { requestKey($0) == key(f1, f2) }.last?.profile == .cleanest)
        #expect(source.routeRequests.filter { requestKey($0) == key(f2, end) }.last?.profile == .dirt)
        #expect(source.routeRequests.filter { requestKey($0) == key(f2, end) }.last?.accessPolicy.motorizedUnknown == true)
    }

    @Test func fuelMarkerCannotMoveCanonicalIntent() async {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 0
        let source = PlannerFakeRoutingSource()
        let model = makeModel(source: source)
        model.apply(
            .replaceAll(waypoints: [point(0), point(1)], profile: .dirt, allowUnknown: false),
            source: "seed"
        )
        await model.waitForCanonicalBuildForTesting()
        let before = model.itinerary

        model.moveWaypoint(markerID: "fuel:\(model.itinerary.legs[0].id.uuidString):0", to: point(0.25).locationCoordinate)

        #expect(model.itinerary == before)
        #expect(model.canonicalBuildStartCount == 1)
    }

    @Test func legacyLegLabelsRemainByteIdentical() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 250
        FuelRangePrefs.reservePercent = 5

        let first = point(0)
        let pump = point(0.25)
        let second = point(0.5)
        let third = point(1)
        let source = PlannerFakeRoutingSource()
        source.distanceOverrides[key(first, second)] = 300_000
        source.distanceOverrides[key(first, pump)] = 150_000
        source.distanceOverrides[key(pump, second)] = 150_000
        source.distanceOverrides[key(second, third)] = 80_000
        source.fuelStops = [fuelStop("shell-antigonish", name: "Shell Antigonish", at: pump)]
        let model = makeModel(source: source)
        model.apply(
            .replaceAll(waypoints: [first, second, third], profile: .dirt, allowUnknown: false),
            source: "seed"
        )
        await model.waitForCanonicalBuildForTesting()

        #expect(model.stages.count == 3)
        #expect(model.stageEndpointTitle(at: 0) == "Point 1 → Shell Antigonish")
        #expect(model.stageEndpointTitle(at: 1) == "Shell Antigonish → Point 2")
        #expect(model.stageEndpointTitle(at: 2) == "Point 2 → Point 3")
    }
}

@MainActor
private func makeModel(
    source: PlannerFakeRoutingSource,
    policy: RoutingSourcePolicy? = nil
) -> RoutePlannerModel {
    RoutePlannerModel(
        routing: RoutingClient(),
        locationService: LocationService(),
        mapState: MapState(),
        navigation: NavigationSession(),
        offline: OfflineTileManager(),
        graphPacks: GraphPackStore(),
        network: NetworkPathMonitor(),
        routingSourcePolicy: policy ?? .fixed(source),
        itineraryBuilder: ItineraryBuilder()
    )
}

@MainActor
private final class FakeInstalledPackRegistry: RoutingInstalledPackRegistry {
    let installedRegionIDs: Set<String>
    let routingManifestVersion = "test-manifest"

    init(installedRegionIDs: Set<String>) {
        self.installedRegionIDs = installedRegionIDs
    }

    func isRoutingPackInstalled(_ regionID: String) -> Bool {
        installedRegionIDs.contains(regionID)
    }

    func installedRoutingGraphPath(regionID: String) -> String? {
        isRoutingPackInstalled(regionID) ? "/fake/\(regionID)/graph.v2.bin" : nil
    }
}

@MainActor
private final class PlannerFakeRoutingSource: RoutingSource {
    let name = "live"
    var routeRequests: [RouteRequest] = []
    var fuelChainRequests: [FuelChainRequest] = []
    var distanceOverrides: [String: Double] = [:]
    var fuelStops: [FuelChainStop] = []
    var fuelStopsByFrom: [String: [FuelChainStop]] = [:]
    var alternates: [FuelAlternate] = []

    func route(_ req: RouteRequest) async throws -> RouteResponse {
        routeRequests.append(req)
        let endpoints = try requestEndpoints(req)
        let meters = distanceOverrides[key(endpoints.0, endpoints.1)] ?? 100_000
        return RouteResponse(
            status: "complete", error: nil, message: nil,
            distanceMeters: meters,
            estimatedMovingSeconds: nil, estimatedElapsedSeconds: nil,
            geometry: [endpoints.0, endpoints.1], segments: nil,
            stats: RouteStats(dirtPercent: 80, pavedPercent: 20),
            maneuvers: nil, warnings: nil,
            dirtPercentValue: nil, pavedPercentValue: nil
        )
    }

    func fuelChain(_ req: FuelChainRequest) async throws -> FuelChainResponse {
        fuelChainRequests.append(req)
        let from = RouteCoordinate(
            longitude: req.locations[0].longitude,
            latitude: req.locations[0].latitude
        )
        let stops = fuelStopsByFrom[keyOrigin(from)] ?? fuelStops
        return FuelChainResponse(
            status: "complete", error: nil, message: nil, regionIds: ["test"],
            stops: stops, graphMeters: nil,
            diagnostics: FuelChainDiagnostics(
                strategy: "fake", states: 1, dijkstraPops: 1,
                matchedFuel: stops.count, elapsedMs: 1
            )
        )
    }

    func fuelAlternates(_ req: FuelAlternateRequest) async throws -> [FuelAlternate] {
        alternates
    }
}

private struct FuelPrefsRestore {
    let enabled = FuelRangePrefs.isEnabled
    let kilometers = FuelRangePrefs.kilometers
    let reserve = FuelRangePrefs.reservePercent

    func restore() {
        FuelRangePrefs.kilometers = enabled ? kilometers : 0
        FuelRangePrefs.reservePercent = reserve
    }
}

private func point(_ value: Double) -> RouteCoordinate {
    RouteCoordinate(longitude: -63 + value, latitude: 45 + value / 10)
}

private func key(_ from: RouteCoordinate, _ to: RouteCoordinate) -> String {
    "\(from.latitude),\(from.longitude)>\(to.latitude),\(to.longitude)"
}

private func keyOrigin(_ from: RouteCoordinate) -> String {
    "\(from.latitude),\(from.longitude)"
}

private func requestKey(_ req: RouteRequest) -> String {
    key(
        RouteCoordinate(longitude: req.locations[0].longitude, latitude: req.locations[0].latitude),
        RouteCoordinate(longitude: req.locations[1].longitude, latitude: req.locations[1].latitude)
    )
}

private func requestEndpoints(_ req: RouteRequest) throws -> (RouteCoordinate, RouteCoordinate) {
    guard req.locations.count == 2 else { throw RoutingError.invalidEndpoints }
    return (
        RouteCoordinate(longitude: req.locations[0].longitude, latitude: req.locations[0].latitude),
        RouteCoordinate(longitude: req.locations[1].longitude, latitude: req.locations[1].latitude)
    )
}

private func fuelStop(
    _ id: String,
    name: String? = nil,
    at point: RouteCoordinate
) -> FuelChainStop {
    FuelChainStop(
        id: id, latitude: point.latitude, longitude: point.longitude,
        name: name ?? id, brand: nil, address: nil, graphMeters: nil
    )
}
