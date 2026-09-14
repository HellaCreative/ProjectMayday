import Foundation
import SwiftData
import Testing
@testable import Dirt

@MainActor
@Suite(.serialized)
struct SavedRoutingPlanTests {
    @Test func canonicalSnapshotSurvivesSwiftDataReopenContinueAndStartWithoutRecalculation() async throws {
        let plan = fixture()
        let container = try ModelContainer(for: SavedRoute.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let writing = ModelContext(container)
        let record = saved(plan)
        record.routingPlanData = try JSONEncoder().encode(plan)
        writing.insert(record)
        try writing.save()
        let reading = ModelContext(container)
        let reopened = try #require(try reading.fetch(FetchDescriptor<SavedRoute>()).first)
        let decoded = try #require(SavedRoutingPlan.decode(reopened.routingPlanData))
        #expect(decoded.itinerary == plan.itinerary)
        #expect(decoded.built == plan.built)
        #expect(decoded.fuel == plan.fuel)
        #expect(decoded.itinerary.legs.map(\.routingSessionSeed) == plan.itinerary.legs.map(\.routingSessionSeed))
        let source = SavedPlanNoRoutingSource()
        let map = MapState()
        let model = makeModel(source, map: map)
        model.loadSavedRoute(reopened)
        #expect(model.mode == .saved)
        #expect(model.itinerary == plan.itinerary)
        #expect(model.built == plan.built)
        #expect(model.activeResponses.count == 3)
        #expect(model.stages.count == 3)
        #expect(map.markers.filter { $0.kind == .fuel }.count == 1)
        #expect(map.markers.filter { $0.id.hasPrefix("wp:") }.count == 3)
        #expect(model.fuelUsableRangeKm == 180)
        #expect(model.displayedFuelSnapshot == plan.fuel.snapshot)
        #expect(model.built?.legs.first?.endsAtFuelStop?.isInitialFillUp == true)
        let line = model.allCoordinates
        model.startNavigation()
        // Cancel before the navigation task yields into data acquisition. This
        // qualifies route preservation at Start, not physical navigation.
        model.cancelOfflineMapPrep()
        await Task.yield()
        #expect(model.allCoordinates == line)
        #expect(model.built == plan.built)
        #expect(source.calls == 0)
        #expect(model.continuePlanningFromSavedTrack())
        #expect(model.mode == .plan)
        #expect(model.itinerary == plan.itinerary)
        #expect(model.built == plan.built)
        #expect(model.allCoordinates == line)
        #expect(source.calls == 0)
        model.saveRoute(named: "Retained", context: reading)
        let resaved = try #require(SavedRoutingPlan.decode(reopened.routingPlanData))
        #expect(resaved.built == plan.built)
        #expect(resaved.fuel == plan.fuel)
    }

    @Test func limitedComparisonSurvivesSavedReopenWithoutBecomingFuelFailure() throws {
        let plan = fixture(limited: true)
        let record = saved(plan)
        record.routingPlanData = try JSONEncoder().encode(plan)
        let source = SavedPlanNoRoutingSource()
        let model = makeModel(source)
        model.loadSavedRoute(record)
        #expect(model.hasLimitedRouteSearch)
        #expect(model.routeSearchNotices.count == 3)
        #expect(model.routeSearchNotices.allSatisfy { $0.kind == .searchLimited })
        #expect(model.fuelCoverageNotices.isEmpty)
        #expect(model.activeResponses.allSatisfy { $0.status == "complete" })
        #expect(model.continuePlanningFromSavedTrack())
        #expect(model.routeSearchNotices.count == 3)
        #expect(source.calls == 0)
    }

    @Test func limitedCompletedBuildShowsPersistentNoticeWithoutSuccessToast() async throws {
        let keys = [FuelRangePrefs.key, FuelRangePrefs.reservePercentKey, FuelRangePrefs.automaticPlanningKey]
        let old = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, old) {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        } }
        FuelRangePrefs.automaticPlanningEnabled = false
        let source = SavedPlanNoRoutingSource()
        source.returnRoute = true
        source.limited = true
        let model = makeModel(source)
        model.apply(.replaceAll(waypoints: fixture().itinerary.waypoints.map(\.coordinate),
            profile: .balanced, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
            source: "limited-route-test")
        await model.waitForCanonicalBuildForTesting()
        #expect(model.hasRoute)
        #expect(model.routeSearchNotices.count == 2)
        #expect(model.fuelCoverageNotices.isEmpty)
        #expect(model.fuelPlanningStatus == nil)
        #expect(model.toast != RoutePlannerModel.routeReadyToast)
        #expect(model.activeResponses.allSatisfy { $0.status == "complete" })
    }

    @Test func legacyAndUnsupportedSnapshotsKeepGeometryWithoutInventingCanonicalProof() throws {
        let plan = fixture()
        let source = SavedPlanNoRoutingSource()
        let model = makeModel(source)
        let canonical = saved(plan)
        canonical.routingPlanData = try JSONEncoder().encode(plan)
        model.loadSavedRoute(canonical)
        for blob in [nil, Data("{\"version\":999}".utf8)] as [Data?] {
            let legacy = saved(plan)
            legacy.routingPlanData = blob
            model.loadSavedRoute(legacy)
            #expect(model.mode == .saved)
            #expect(model.allCoordinates == legacy.coordinates)
            #expect(model.itinerary.waypoints.isEmpty)
            #expect(model.built == nil)
            #expect(source.calls == 0)
            if blob != nil { #expect(model.toast?.contains("unavailable") == true) }
        }
    }

    @Test func saveUsesFuelSettingsCapturedByActualBuild() async throws {
        let keys = [FuelRangePrefs.key, FuelRangePrefs.reservePercentKey, FuelRangePrefs.automaticPlanningKey]
        let old = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, old) {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        } }
        FuelRangePrefs.kilometers = 200
        FuelRangePrefs.reservePercent = 10
        FuelRangePrefs.automaticPlanningEnabled = false
        let fuel = FuelRangePrefs.snapshot
        let source = SavedPlanNoRoutingSource()
        source.returnRoute = true
        let model = makeModel(source)
        let points = fixture().itinerary.waypoints.map(\.coordinate)
        model.apply(.replaceAll(waypoints: points, profile: .dirt, allowUnknown: false,
            avoidMotorways: false, preferBackRoads: false), source: "saved-plan-test")
        await model.waitForCanonicalBuildForTesting()
        #expect(model.hasRoute)
        #expect(source.calls > 0)
        FuelRangePrefs.kilometers = 400
        FuelRangePrefs.reservePercent = 5
        let container = try ModelContainer(for: SavedRoute.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        model.saveRoute(named: "Built ride", context: context)
        let record = try #require(try context.fetch(FetchDescriptor<SavedRoute>()).first)
        let plan = try #require(SavedRoutingPlan.decode(record.routingPlanData))
        #expect(plan.fuel.snapshot == fuel)
        #expect(plan.fuel.automaticPlanningEnabled == false)
        #expect(plan.itinerary == model.itinerary)
    }

    @Test func loopSnapshotKeepsOriginalAnchorDirectionAndGeneration() throws {
        let plan = fixture(loop: true)
        let record = saved(plan)
        record.routingPlanData = try JSONEncoder().encode(plan)
        let model = makeModel(SavedPlanNoRoutingSource())
        model.loadSavedRoute(record)
        #expect(model.mode == .saved)
        #expect(model.loopDistanceKM == 175)
        #expect(model.loopDirection == .southwest)
        #expect(SavedRoutingPlan.decode(record.routingPlanData)?.loopAnchor == plan.itinerary.waypoints.first?.coordinate)
        #expect(model.continuePlanningFromSavedTrack())
        #expect(model.itinerary.generation == 7)
        #expect(model.itinerary.waypoints.first == plan.itinerary.waypoints.first)
    }

    @Test func editedReopenedLoopSavesAsPlanWithoutLoopAnchor() async throws {
        let original = fixture(loop: true, automaticFuel: false)
        let container = try ModelContainer(for: SavedRoute.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let record = saved(original)
        record.routingPlanData = try JSONEncoder().encode(original)
        context.insert(record)
        try context.save()
        let source = SavedPlanNoRoutingSource()
        source.returnRoute = true
        let model = makeModel(source)
        model.loadSavedRoute(record)
        #expect(model.continuePlanningFromSavedTrack())
        model.saveRoute(named: "Unchanged loop", context: context)
        #expect(SavedRoutingPlan.decode(record.routingPlanData)?.sourceMode == "loop")
        model.apply(.append(coordinate: .init(longitude: -63.2, latitude: 45)), source: "saved-loop-edit")
        await model.waitForCanonicalBuildForTesting()
        model.saveRoute(named: "Open plan", context: context)
        let edited = try #require(SavedRoutingPlan.decode(record.routingPlanData))
        #expect(edited.sourceMode == "Plan a route")
        #expect(edited.loopAnchor == nil)
        #expect(edited.itinerary.waypoints.count == original.itinerary.waypoints.count + 1)
    }

    private func fixture(loop: Bool = false, automaticFuel: Bool = true, limited: Bool = false) -> SavedRoutingPlan {
        let points = [RouteCoordinate(longitude: -63.5, latitude: 44.7),
                      RouteCoordinate(longitude: -63.4, latitude: 44.8),
                      RouteCoordinate(longitude: -63.3, latitude: 44.9)].map { RiderWaypoint(coordinate: $0) }
        let legs = zip(points, points.dropFirst()).map {
            RiderLeg(from: $0.id, to: $1.id, profile: .dirt, allowUnknown: false,
                fuelStopOverrides: ["station:old": "station:chosen"])
        }
        let itinerary = RiderItinerary(waypoints: points, legs: legs, generation: 7, impassableEdgeIDs: ["blocked-edge"])
        let pump = RouteCoordinate(longitude: -63.499, latitude: 44.701)
        let stop = FuelStop(coordinate: pump, stationID: "mapped-pump", name: "Initial fill",
            afterRiderLegID: legs[0].id, isInitialFillUp: true)
        func hop(_ from: RouteCoordinate, _ to: RouteCoordinate, _ leg: RiderLeg,
                 _ meters: Double, _ stop: FuelStop? = nil) -> BuiltLeg {
            var response = RouteResponse(status: "complete", error: nil, message: nil,
                distanceMeters: meters, estimatedMovingSeconds: nil, estimatedElapsedSeconds: nil,
                geometry: [from, to], segments: nil,
                stats: RouteStats(dirtPercent: 80, pavedPercent: 20, unknownAccessPercent: 0),
                maneuvers: nil, warnings: limited ? [RouteWarning(code: "route_search_limited", message: RouteResponse.searchLimitedMessage)] : nil, dirtPercentValue: nil, pavedPercentValue: nil)
            response.terminalContinuation = NativeRoutingContinuation(version: 1, sourceEpoch: "fixture-epoch",
                incoming: .init(wayID: 19, fromNodeID: 20, toNodeID: 21), location: .edge(fraction: 0.6),
                restrictionContext: [], activeRestrictions: [])
            return BuiltLeg(riderLegID: leg.id, fromCoordinate: from, toCoordinate: to,
                endsAtFuelStop: stop, response: response, fuelUsedOnArrivalMeters: meters,
                routeProfile: stop == nil ? .dirt : .cleanest)
        }
        let builtLegs = [hop(points[0].coordinate, pump, legs[0], 500, stop),
                         hop(pump, points[1].coordinate, legs[0], 15_000),
                         hop(points[1].coordinate, points[2].coordinate, legs[1], 16_000)]
        let built = BuiltItinerary(generation: 7, legs: builtLegs,
            riderLegStatus: Dictionary(uniqueKeysWithValues: legs.map { ($0.id, .built) }),
            riderRoutes: [legs[0].id: builtLegs[1].response, legs[1].id: builtLegs[2].response])
        return SavedRoutingPlan(itinerary: itinerary, built: built, ridePreferences: nil,
            fuel: .init(tankMeters: 200_000, usableMeters: 180_000, reservePercent: 10, automaticPlanningEnabled: automaticFuel),
            profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false,
            sourceMode: loop ? "loop" : "Plan a route", loopDistanceKM: 175,
            loopDirection: "Southwest", loopSummary: "Stored loop")
    }

    private func saved(_ plan: SavedRoutingPlan) -> SavedRoute {
        SavedRoute(name: "Chosen ride", profile: .dirt,
            coordinates: plan.built.legs.flatMap { $0.response.coordinates }.reduce(into: []) { values, point in
                if values.last != point { values.append(point) }
            },
            distanceMeters: 31_500, dirtPercent: 80, pavedPercent: 20)
    }

    private func makeModel(_ source: SavedPlanNoRoutingSource, map: MapState = MapState()) -> RoutePlannerModel {
        RoutePlannerModel(routing: RoutingClient(), locationService: LocationService(),
            mapState: map, navigation: NavigationSession(), offline: OfflineTileManager(),
            graphPacks: GraphPackStore(cacheRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("saved-plan-\(UUID().uuidString)"), refreshCatalogOnInit: false),
            network: NetworkPathMonitor(), routingSourcePolicy: .fixed(source),
            itineraryBuilder: ItineraryBuilder(), requiresInstalledRoutingPacks: false)
    }
}

@MainActor
private final class SavedPlanNoRoutingSource: RoutingSource {
    let name = "saved-plan-no-routing"
    var calls = 0
    var returnRoute = false
    var limited = false
    func route(_ request: RouteRequest) async throws -> RouteResponse {
        calls += 1
        guard returnRoute else { throw CancellationError() }
        return RouteResponse(status: "complete", error: nil, message: nil,
            distanceMeters: 15_000, estimatedMovingSeconds: nil, estimatedElapsedSeconds: nil,
            geometry: request.locations.map { RouteCoordinate(longitude: $0.longitude, latitude: $0.latitude) },
            segments: nil, stats: RouteStats(dirtPercent: 80, pavedPercent: 20, unknownAccessPercent: 0),
            maneuvers: nil, warnings: limited ? [RouteWarning(code: "route_search_limited", message: RouteResponse.searchLimitedMessage)] : nil, dirtPercentValue: nil, pavedPercentValue: nil)
    }
    func fuelChain(_ request: FuelChainRequest) async throws -> FuelChainResponse { calls += 1; throw CancellationError() }
    func fuelStation(near point: RouteCoordinate, within meters: Double) async throws -> FuelChainStop? { calls += 1; throw CancellationError() }
}
