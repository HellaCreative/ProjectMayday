import Foundation
import CoreLocation
import SwiftUI
import Testing
import DirtRoutingEngine
@testable import Dirt

@MainActor
@Suite(.serialized)
struct RoutePlannerModelItineraryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRT_QUALIFY_LONG_PLANNER"] == "1"),
          .timeLimit(.minutes(15)))
    func actualHalifaxSquamishPlannerBuildsAndFramesEachLongRideLeg() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.notificationsEnabled = false
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DIRT_QUALIFY_PACK_ROOT"]))
        let catalogData = try Data(contentsOf: root.deletingLastPathComponent().appendingPathComponent("manifest.json"))
        let catalog = try #require(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let catalogRows = try #require(catalog["regions"] as? [[String: Any]])
        let published = Set(catalogRows.compactMap { $0["id"] as? String })
        let roadNeighbors = try #require(catalog["roadNeighbors"] as? [String: [String]])
            .mapValues { Set($0) }
        func directories(for request: RouteRequest) throws -> [String: URL] {
            let ids = GraphPackStore.requiredCatalogRoutingRegions(
                for: request.locations.map { .init(latitude: $0.latitude, longitude: $0.longitude) },
                published: published, roadNeighbors: roadNeighbors)
            try #require(!ids.isEmpty)
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, root.appendingPathComponent($0)) })
        }
        var session: NativeRoutingSession? = NativeRoutingSession()
        let source = PlannerFakeRoutingSource(name: "pack")
        defer { source.routeHandler = nil }
        let map = MapState()
        let model = makeModel(source: source, mapState: map)
        let initialCelebration = model.routeCompletionID
        var requests = 0
        let started = ContinuousClock.now
        var legTimes: [Duration] = []
        source.progressRouteHandler = { request, progress in
            requests += 1
            let native = try NativeRoutingAdapter.request(request)
            #expect(native.profile.style == .dirt && native.profile.wander == 1)
            #expect(native.options.cityWall && native.profile.avoidMajorHighways && native.access.avoidFerries)
            let routingSession = try #require(session)
            let response = try await NativeRouteProgressBridge.route(request, session: routingSession,
                directories: directories(for: request)) { event in
                #expect(model.routeCompletionID == initialCelebration)
                progress(event)
                if case .leg(let index, let leg) = event {
                    legTimes.append(started.duration(to: .now))
                    #expect(model.activeRouteProgressMessage == "Building leg \(index + 2)")
                    #expect(map.routeBuildCameraSequence?.steps.count == index + 2)
                    #expect(model.activeResponses.last?.coordinates == leg.coordinates)
                    print("CANDIDATE streamed-leg number=\(index + 1) meters=\(leg.distanceMeters ?? 0) elapsed=\(started.duration(to: .now))")
                }
            }
            #expect(ProcessMemory.megabytes().peak < 1_300)
            return response
        }
        defer { source.progressRouteHandler = nil }

        let start = RouteCoordinate(longitude: -63.5752, latitude: 44.6488)
        let end = RouteCoordinate(longitude: -123.1558, latitude: 49.7016)
        model.selectMode(.fromHere)
        model.applyDefaultRideSettings(profile: .dirt, allowUnknown: false,
            ridePreferences: .init(wander: 1, avoidCities: true, avoidHighways: true, avoidFerries: true))
        model.apply(.replaceAll(waypoints: [start, end], profile: .dirt, allowUnknown: false,
            avoidMotorways: true, preferBackRoads: true), source: "fromHere")
        model.setPlanningSessionSeedForTesting(8026290980254235)
        await model.waitForCanonicalBuildForTesting()
        try #require(model.errorMessage == nil)
        #expect(model.mode == .plan)
        #expect(model.itinerary.legs.count > 2)
        #expect(requests == 1)
        #expect(legTimes.count == model.itinerary.legs.count)
        #expect(model.built?.legs.count == model.itinerary.legs.count)
        #expect(map.routeBuildCameraSequence?.steps.count == model.itinerary.legs.count + 1)
        #expect(model.routeCompletionID != initialCelebration)
        #expect(model.activeRouteProgressMessage == nil)
        let last = try #require(model.activeResponses.last?.coordinates.last)
        #expect(GeoMath.meters(last, end) <= 250)
        let plannerDuration = started.duration(to: .now)
        #expect(try #require(legTimes.first) < plannerDuration - .seconds(5))
        #expect(plannerDuration < .seconds(180))
        print("CANDIDATE planner-800km-complete legs=\(model.itinerary.legs.count) elapsed=\(plannerDuration)")
        if ProcessInfo.processInfo.environment["DIRT_QUALIFY_COMPARE_LONG_PLANNER"] == "1" {
            // Compare identical pins, seed, preferences, catalog and adapter.
            // A fresh session prevents the direct baseline borrowing prepared
            // graphs from the planner. Both runs use already-installed packs.
            source.progressRouteHandler = nil
            session = nil
            let directRequest = RidePreferenceContext.$current.withValue(
                RidePreferences(wander: 1, avoidCities: true, avoidHighways: true, avoidFerries: true)) {
                RouteRequest(profile: .dirt, locations: [
                    .init(latitude: start.latitude, longitude: start.longitude, label: "Halifax"),
                    .init(latitude: end.latitude, longitude: end.longitude, label: "Squamish")
                ], allowUnknown: false, sessionSeed: model.planningSessionSeed,
                    avoidMotorways: true, preferBackRoads: true, mapZoom: 3.5)
            }
            let directNative = try NativeRoutingAdapter.request(directRequest)
            let directStarted = ContinuousClock.now
            let direct = try await NativeRoutingSession().route(directNative, directories: directories(for: directRequest))
            let directDuration = directStarted.duration(to: .now)
            #expect(plannerDuration < directDuration * 1.35 + .seconds(10))
            #expect(direct.limit == nil)
            #expect(direct.end.coordinate.distance(to: directNative.end) <= 250)
            #expect(direct.segments.allSatisfy { ![2, 5].contains($0.access) && $0.structure != "ferry" })
            print("CANDIDATE planner-efficiency-comparison seed=\(model.planningSessionSeed) planner=\(plannerDuration) direct=\(directDuration) plannerMeters=\(model.activeResponses.reduce(0) { $0 + ($1.distanceMeters ?? 0) }) directMeters=\(direct.distanceMeters)")
        }
    }

    @Test func everyLoopWaypointCanBeMovedWithoutRegeneratingLoop() async throws {
        let source = PlannerFakeRoutingSource()
        let map = MapState()
        let model = makeModel(source: source, mapState: map)
        model.mode = .plan
        model.showingLoop = true
        model.generateLoop(start: point(0), far: point(1))
        await model.waitForCanonicalBuildForTesting()
        let ids = model.itinerary.waypoints.map(\.id)
        #expect(map.plannerMarkers.filter { $0.id.hasPrefix("wp:") }.allSatisfy { !$0.isLocked })
        for (index, id) in ids.enumerated() {
            let moved = point(Double(index) * 0.2 + 0.1)
            let marker = "wp:\(id.uuidString)"
            let before = model.itinerary.waypoints.map(\.coordinate)
            model.moveWaypoint(markerID: marker, to: moved.locationCoordinate)
            #expect(model.itinerary.waypoints.map(\.coordinate) == before)
            #expect(!model.showsWaypointPlacementConfirmation)
            model.requestWaypointPlacementConfirmation(markerID: marker, snappedCoordinate: moved.locationCoordinate)
            model.confirmWaypointPlacement()
            await model.waitForCanonicalBuildForTesting()
            #expect(model.itinerary.waypoints[index].coordinate == moved)
            #expect(model.itinerary.waypoints.map(\.id) == ids)
        }
        #expect(source.loopRequestCount == 1)
    }

    @Test func failedFromHereDestinationAndStartRemainEditable() async throws {
        let source = PlannerFakeRoutingSource()
        let map = MapState()
        let model = makeModel(source: source, mapState: map)
        model.mode = .fromHere
        source.routeError = RoutingError.server("No legal connection")
        model.apply(.replaceAll(waypoints: [point(0), point(1)], profile: .dirt,
            allowUnknown: false, avoidMotorways: true, preferBackRoads: true), source: "fromHere")
        await model.waitForCanonicalBuildForTesting()
        #expect(model.errorMessage != nil)
        let ids = model.itinerary.waypoints.map(\.id)
        #expect(map.plannerMarkers.filter { $0.id.hasPrefix("wp:") }.allSatisfy { !$0.isLocked })
        source.routeError = nil
        for index in [1, 0] {
            let moved = point(index == 1 ? 0.8 : 0.2)
            let marker = "wp:\(ids[index].uuidString)"
            model.moveWaypoint(markerID: marker, to: moved.locationCoordinate)
            #expect(!model.showsWaypointPlacementConfirmation)
            model.requestWaypointPlacementConfirmation(markerID: marker, snappedCoordinate: moved.locationCoordinate)
            model.keepMovingWaypoint()
            #expect(model.itinerary.waypoints[index].coordinate != moved)
            model.requestWaypointPlacementConfirmation(markerID: marker, snappedCoordinate: moved.locationCoordinate)
            model.confirmWaypointPlacement()
            await model.waitForCanonicalBuildForTesting()
            #expect(model.itinerary.waypoints[index].coordinate == moved)
            #expect(model.itinerary.waypoints.map(\.id) == ids)
            #expect(model.mode == .fromHere)
        }
        #expect(model.fromHereStartOverride == point(0.2))
        #expect(model.destination == point(0.8))
        #expect(model.errorMessage == nil)
    }

    @Test func searchedWaypointAppendsToExistingPlanWithoutReplacingPins() async {
        let source = PlannerFakeRoutingSource()
        let model = makeModel(source: source)
        model.addPlanWaypoint(latitude: point(0).latitude, longitude: point(0).longitude)
        model.addPlanWaypoint(latitude: point(0.1).latitude, longitude: point(0.1).longitude)
        await model.waitForCanonicalBuildForTesting()
        let previousIDs = model.itinerary.waypoints.map(\.id)
        model.addPlanWaypoint(latitude: point(0.2).latitude, longitude: point(0.2).longitude)
        await model.waitForCanonicalBuildForTesting()
        #expect(model.mode == .plan)
        #expect(model.itinerary.waypoints.count == 3)
        #expect(Array(model.itinerary.waypoints.prefix(2).map(\.id)) == previousIDs)
        #expect(model.itinerary.waypoints.last?.coordinate == point(0.2))
        #expect(model.stages.count == 2)
    }

    @Test func completedLoopSignalsOverviewIndependentlyOfToast() async throws {
        let source = PlannerFakeRoutingSource()
        let map = MapState()
        let model = makeModel(source: source, mapState: map)
        model.showingLoop = true
        model.generateLoop(start: point(0), far: point(1))
        await model.waitForCanonicalBuildForTesting()
        let firstCompletion = try #require(model.routeCompletionID)
        #expect(model.stages.count == 2)
        #expect(!model.isRouting)
        #expect(model.toast == RoutePlannerModel.routeReadyToast)
        model.toast = nil
        #expect(model.routeCompletionID == firstCompletion)
        #expect(model.frameCompletedRouteForCelebration())
        guard let camera = map.camera, case let .fit(coordinates) = camera.command else {
            Issue.record("Completed loop must request a full-route overview")
            return
        }
        #expect(coordinates.contains(point(0)))
        #expect(coordinates.contains(point(1)))
        #expect(coordinates.first == coordinates.last)
        #expect(map.completedRouteOverviewID == nil)
        map.completeRouteOverview(cameraID: camera.id)
        #expect(map.completedRouteOverviewID == camera.id)

        model.generateLoop(start: point(0), far: point(1))
        await model.waitForCanonicalBuildForTesting()
        #expect(model.routeCompletionID != firstCompletion)
    }

    @Test func completedLoopReturnWaypointCanBeInsertedMovedAndDeleted() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.notificationsEnabled = false
        let source = PlannerFakeRoutingSource()
        let map = MapState()
        let model = makeModel(source: source, mapState: map)
        model.mode = .plan
        model.showingLoop = true
        let start = point(0), far = point(1), added = point(0.4), moved = point(0.6)
        model.generateLoop(start: start, far: far)
        await model.waitForCanonicalBuildForTesting()
        let originalIDs = model.itinerary.waypoints.map(\.id)
        let outbound = try #require(model.built?.legs.first)
        let inboundID = try #require(model.itinerary.legs.last?.id)
        source.routeRequests.removeAll()

        model.handleRouteTap(point(0.5).locationCoordinate, riderLegID: inboundID, source: "longPress")
        model.moveWaypoint(markerID: "waypoint-draft", to: added.locationCoordinate)
        #expect(!model.showsWaypointPlacementConfirmation)
        model.requestWaypointPlacementConfirmation(markerID: "waypoint-draft", snappedCoordinate: added.locationCoordinate)
        model.confirmWaypointPlacement()
        model.confirmWaypointPlacement()
        await model.waitForCanonicalBuildForTesting()
        #expect(model.showingLoop)
        #expect(model.itinerary.waypoints.map(\.coordinate) == [start, far, added, start])
        #expect(model.stages.count == 3)
        #expect(model.built?.legs.first == outbound)
        #expect(model.itinerary.waypoints.first?.id == originalIDs.first)
        #expect(model.itinerary.waypoints.last?.id == originalIDs.last)
        #expect(source.loopRequestCount == 1)
        let pinID = try #require(model.itinerary.waypoints.dropFirst(2).first?.id)
        let markerID = "wp:\(pinID.uuidString)"
        #expect(map.plannerMarkers.first { $0.id == markerID }?.isLocked == false)
        #expect(map.plannerMarkers.count == 4)
        #expect(model.allCoordinates.contains(added))

        model.moveWaypoint(markerID: markerID, to: moved.locationCoordinate)
        #expect(!model.showsWaypointPlacementConfirmation)
        model.requestWaypointPlacementConfirmation(markerID: markerID, snappedCoordinate: moved.locationCoordinate)
        model.confirmWaypointPlacement()
        await model.waitForCanonicalBuildForTesting()
        #expect(model.itinerary.waypoints.map(\.coordinate) == [start, far, moved, start])
        #expect(model.itinerary.waypoints[2].id == pinID)
        #expect(model.allCoordinates.contains(moved))
        #expect(model.built?.legs.first == outbound)
        model.apply(.delete(waypointID: pinID), source: "test")
        await model.waitForCanonicalBuildForTesting()
        #expect(model.itinerary.waypoints.map(\.coordinate) == [start, far, start])
        #expect(model.stages.count == 2)
        #expect(source.loopRequestCount == 1)
    }

    @Test func completedLoopLegSettingsRebuildOnlySelectedLeg() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.notificationsEnabled = false
        let source = PlannerFakeRoutingSource()
        let model = makeModel(source: source)
        model.mode = .plan
        model.showingLoop = true
        model.generateLoop(start: point(0), far: point(1))
        await model.waitForCanonicalBuildForTesting()
        let outbound = try #require(model.built?.legs.first)
        let ids = model.itinerary.waypoints.map(\.id)
        source.routeRequests.removeAll()
        let preferences = RidePreferences(wander: 0.95, avoidCities: false, avoidHighways: false)
        model.applyLegRideSettings(at: 1, profile: .dirt, allowUnknown: true, ridePreferences: preferences)
        await model.waitForCanonicalBuildForTesting()
        #expect(source.loopRequestCount == 1)
        #expect(model.itinerary.waypoints.map(\.id) == ids)
        #expect(model.built?.legs.first == outbound)
        #expect(model.itinerary.legs[1].ridePreferences == preferences)
        #expect(model.itinerary.legs[1].allowUnknown)
        #expect(!source.routeRequests.isEmpty)
        #expect(source.routeRequests.allSatisfy { $0.options?.ridePreferences == preferences && $0.accessPolicy.motorizedUnknown })
    }

    @Test func loopOutboundInsertionKeepsFarPinIdentityAndFailureDoesNotCelebrate() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.notificationsEnabled = false
        let source = PlannerFakeRoutingSource()
        let map = MapState()
        let model = makeModel(source: source, mapState: map)
        model.mode = .plan
        model.showingLoop = true
        let start = point(0), far = point(1), added = point(0.4), movedFar = point(0.9)
        model.generateLoop(start: start, far: far)
        await model.waitForCanonicalBuildForTesting()
        let originalFarID = model.itinerary.waypoints[1].id
        #expect(model.routeCompletionID != nil)
        source.routeError = RoutingError.server("Cannot reach requested pin")
        model.apply(.insert(afterLegID: model.itinerary.legs[0].id, coordinate: added), source: "test")
        await model.waitForCanonicalBuildForTesting()
        #expect(model.itinerary.waypoints.map(\.coordinate) == [start, added, far, start])
        #expect(model.routeCompletionID == nil)
        #expect(model.errorMessage != nil)
        #expect(map.plannerMarkers.count == 4)
        source.routeError = nil
        model.handleMapLongPress(movedFar.locationCoordinate)
        await model.waitForCanonicalBuildForTesting()
        #expect(model.itinerary.waypoints.map(\.coordinate) == [start, added, movedFar, start])
        #expect(model.itinerary.waypoints[2].id == originalFarID)
        #expect(model.loopFar == movedFar)
        #expect(source.loopRequestCount == 1)
    }

    @Test func failedLoopDoesNotSignalCompletion() async {
        let source = PlannerFakeRoutingSource()
        source.routeError = RoutingError.server("Test failure")
        let model = makeModel(source: source)
        model.showingLoop = true
        model.generateLoop(start: point(0), far: point(1))
        await model.waitForCanonicalBuildForTesting()
        #expect(model.routeCompletionID == nil)
        #expect(!model.frameCompletedRouteForCelebration())
    }

    @Test func reportRoutesFromRiderAndPreservesLaterLegAndShowsOverview() async throws {
        let defaults = UserDefaults.standard
        let reports = defaults.object(forKey: "dirt_reports_v1")
        defer {
            if let reports { defaults.set(reports, forKey: "dirt_reports_v1") }
            else { defaults.removeObject(forKey: "dirt_reports_v1") }
        }
        let source = PlannerFakeRoutingSource()
        let location = LocationService()
        let map = MapState()
        let model = makeModel(source: source, mapState: map, locationService: location)
        source.routeHandler = { request in
            let (from, to) = try requestEndpoints(request)
            return recoveryFixture([from, to], edge: "reported-road")
        }
        model.apply(.replaceAll(waypoints: [point(0), point(0.1), point(0.2)], profile: .dirt,
            allowUnknown: false, avoidMotorways: true, preferBackRoads: false), source: "plan")
        await model.waitForCanonicalBuildForTesting()
        let later = try #require(model.stages.last?.response)
        let active = try #require(model.stages.first)
        model.navigation.activate(coordinates: model.allCoordinates, maneuvers: [], stages: [
            NavigationStage(id: active.id, title: "Point 2", detail: nil, kind: .waypoint, endMeters: 10_000)
        ])
        map.beginNavigationCamera()
        let rider = point(0.05)
        let fix = CLLocation(coordinate: rider.locationCoordinate, altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: -1, timestamp: Date())
        location.locationManager(CLLocationManager(), didUpdateLocations: [fix])
        for _ in 0..<100 where location.lastLocation?.timestamp != fix.timestamp {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.edgeIdNear(rider) == "reported-road") // Mid-segment, kilometres from vertices.
        source.routeHandler = { request in
            let (from, to) = try requestEndpoints(request)
            return recoveryFixture([from, point(0), .init(longitude: -63, latitude: 45.02), to], edge: "alternate-road")
        }
        let incidents = IncidentRecoveryModel(planner: model, locationService: location, network: NetworkPathMonitor())
        incidents.open()
        incidents.submitReport(.flooded)
        incidents.choose(.around)
        await incidents.waitForRecoveryForTesting()
        #expect(incidents.step == .hidden)
        let request = try #require(source.routeRequests.last)
        #expect(request.locations.first?.longitude == rider.longitude)
        #expect(request.locations.last?.longitude == point(0.1).longitude)
        #expect(request.options?.avoidEdgeIds?.contains("reported-road") == true)
        #expect(request.options?.blockedStartEscapeToward == point(0))
        #expect(model.stages.last?.response?.coordinates == later.coordinates)
        #expect(map.navigationCameraMode == .overview)
        #expect(!model.navigation.recoverySuspended)
    }

    @Test func navigationRecoveryKeepsActiveStageAtOverlappingLegs() async throws {
        let source = PlannerFakeRoutingSource()
        let model = makeModel(source: source)
        model.apply(.replaceAll(waypoints: [point(0), point(0.1), point(0)], profile: .dirt,
            allowUnknown: false, avoidMotorways: true, preferBackRoads: false), source: "plan")
        await model.waitForCanonicalBuildForTesting()
        let stage = try #require(model.stages.last)
        model.navigation.activate(coordinates: [point(0.1), point(0)], maneuvers: [], stages: [
            NavigationStage(id: stage.id, title: "Point 3", detail: nil, kind: .destination, endMeters: 10_000)
        ])
        #expect(model.activeStageIndex(near: point(0.05)) == 1)
        #expect(model.preservedDestination == point(0))
        model.apply(.markImpassable(edgeIDs: ["blocked-edge"]), source: "reroute")
        _ = try await model.routeWhileNavigating(from: point(0.05), to: point(0))
        #expect(source.routeRequests.last?.options?.avoidEdgeIds?.contains("blocked-edge") == true)
    }

    @Test func navigationRecoveryRetainsExplicitFerryPermission() async throws {
        let source = PlannerFakeRoutingSource()
        let model = makeModel(source: source)
        model.ridePreferences = RidePreferences(wander: 0.75, avoidFerries: false)
        _ = try await model.routeWhileNavigating(from: point(0), to: point(1))
        #expect(source.routeRequests.last?.options?.ridePreferences == model.displayedRidePreferences)
        #expect(source.routeRequests.last?.options?.ridePreferences?.avoidFerries == false)
    }

    @Test func ferryRetryPreservesPinsAndOnlyChangesFerryPreference() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.notificationsEnabled = false
        let source = PlannerFakeRoutingSource()
        source.routeError = RoutingError.server(NativeRoutingAdapter.ferriesAvoidedMessage)
        let model = makeModel(source: source)
        model.ridePreferences = RidePreferences(wander: 0.75, avoidCities: true, avoidHighways: true)
        model.apply(.replaceAll(waypoints: [point(0), point(0.5), point(1)], profile: .dirt,
            allowUnknown: false, avoidMotorways: true, preferBackRoads: false), source: "fromHere")
        await model.waitForCanonicalBuildForTesting()
        let before = model.itinerary.waypoints
        #expect(model.canAllowFerries)
        source.routeError = nil
        model.allowFerriesAndRetry()
        await model.waitForCanonicalBuildForTesting()
        #expect(model.itinerary.waypoints == before)
        #expect(model.errorMessage == nil)
        #expect(model.displayedRidePreferences.avoidFerries)
        #expect(model.itinerary.legs.first?.ridePreferences.avoidFerries == false)
        #expect(model.itinerary.legs.dropFirst().allSatisfy { $0.ridePreferences.avoidFerries })
        #expect(model.displayedRidePreferences.wander == 0.75)
        #expect(model.displayedRidePreferences.avoidHighways && model.displayedRidePreferences.avoidCities)
        #expect(source.routeRequests.last?.options?.ridePreferences?.avoidFerries == false)
    }

    @Test func profileRebuildReplacesDisplayedGeometryAtTheSameEndpoints() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.notificationsEnabled = false
        let source = PlannerFakeRoutingSource()
        let map = MapState()
        let model = makeModel(source: source, mapState: map)
        source.profileGeometry = [.dirt: [point(0), point(0.7), point(1)],
                                  .balanced: [point(0), point(0.4), point(1)],
                                  .cleanest: [point(0), point(1)]]
        for profile: RouteProfile in [.dirt, .balanced, .cleanest] {
            let priorGeneration = map.routeGeneration
            model.apply(.replaceAll(waypoints: [point(0), point(1)], profile: profile,
                allowUnknown: false, avoidMotorways: false, preferBackRoads: false), source: "fromHere")
            await model.waitForCanonicalBuildForTesting()
            #expect(source.routeRequests.last?.profile == profile)
            #expect(model.activeResponses.first?.coordinates == source.profileGeometry[profile])
            #expect(map.routeSegments.flatMap(\.coordinates) == source.profileGeometry[profile])
            #expect(map.routeGeneration > priorGeneration)
        }
    }

    @Test func progressNotificationUsesCraftHypeCopy() {
        let fuelOn = FuelRangePrefs.Snapshot(
            tankMeters: 260_000,
            usableMeters: 247_000,
            reservePercent: 5,
            notificationsEnabled: true
        )
        let fuelOff = FuelRangePrefs.Snapshot(
            tankMeters: 260_000,
            usableMeters: 247_000,
            reservePercent: 5,
            notificationsEnabled: false
        )

        #expect(RoutePlannerModel.initialBuildProgressToast(for: fuelOn)
            == RoutePlannerModel.craftingRouteToast)
        #expect(RoutePlannerModel.initialBuildProgressToast(for: fuelOff)
            == RoutePlannerModel.craftingRouteToast)
        #expect(RoutePlannerModel.progressToastContent(
            for: RoutePlannerModel.craftingRouteToast
        ) == RoutePlannerModel.routeBuildHypeLines[0])
        #expect(RoutePlannerModel.usesRotatingBuildHype(for: RoutePlannerModel.craftingRouteToast))
        #expect(!RoutePlannerModel.routeBuildHypeLines.contains(where: {
            $0.title.localizedCaseInsensitiveContains("fuel")
                || $0.detail.localizedCaseInsensitiveContains("fuel")
                || $0.title.localizedCaseInsensitiveContains("automatic")
                || $0.detail.localizedCaseInsensitiveContains("planning")
        }))
    }

    @Test func progressNotificationKeepsFuelInternalsOffRiderToastCopy() {
        #expect(RoutePlannerModel.progressToastContent(for: "Creating fuel stop 1")
            == RoutePlannerModel.routeBuildHypeLines[0])
        #expect(RoutePlannerModel.progressToastContent(for: "Fuel stop 2 added")
            == RoutePlannerModel.routeBuildHypeLines[0])
        #expect(RoutePlannerModel.isPersistentProgressToast("Checking range after fuel stop 2"))
        #expect(RoutePlannerModel.progressToastContent(for: "Checking range after fuel stop 2")
            == RoutePlannerModel.routeBuildHypeLines[0])
    }

    @Test func loopSearchUsesPersistentAnimatedProgressContent() {
        #expect(RoutePlannerModel.isPersistentProgressToast("Finding loop"))
        #expect(RoutePlannerModel.progressToastContent(for: "Finding loop")?.title == "Finding loop")
        #expect(RoutePlannerModel.progressToastContent(for: "Finding loop")?.detail == "Comparing roads for your round trip")
        #expect(!RoutePlannerModel.isPersistentProgressToast("Route overview"))
    }

    @Test func activeRouteProgressSurvivesUnrelatedTapFeedback() {
        #expect(RoutePlannerModel.activeRouteProgressMessage(
            fuelPlanningStatus: RoutePlannerModel.craftingRouteToast,
            isRouting: false,
            toast: nil
        ) == nil)
        #expect(RoutePlannerModel.activeRouteProgressMessage(
            fuelPlanningStatus: "Creating fuel stop 4",
            isRouting: true,
            toast: "Route overview"
        ) == "Creating fuel stop 4")
        #expect(RoutePlannerModel.activeRouteProgressMessage(
            fuelPlanningStatus: nil,
            isRouting: true,
            toast: "Waypoint selected"
        ) == RoutePlannerModel.calculatingRouteToast)
        #expect(RoutePlannerModel.activeRouteProgressMessage(
            fuelPlanningStatus: nil,
            isRouting: false,
            toast: "Route overview"
        ) == nil)
    }

    @Test func planModeSelectsLocalRoutingWhileOnline() async {
        let live = PlannerFakeRoutingSource(name: "live")
        let pack = PlannerFakeRoutingSource(name: "pack")
        let registry = FakeInstalledPackRegistry(installedRegionIDs: ["ns"])
        var policyReports: [String] = []
        let policy = RoutingSourcePolicy(
            isOnline: { true },
            installedPacks: registry,
            live: live,
            pack: pack,
            report: { policyReports.append($0) }
        )
        let model = makeModel(source: pack, policy: policy)
        model.selectMode(.plan)
        model.apply(
            .replaceAll(
                waypoints: [
                    RouteCoordinate(longitude: -63.57, latitude: 44.65),
                    RouteCoordinate(longitude: -60.19, latitude: 46.14)
                ],
                profile: .dirt,
                allowUnknown: false,
                avoidMotorways: false,
                preferBackRoads: false
            ),
            source: "plan"
        )

        await model.waitForCanonicalBuildForTesting()

        #expect(policyReports.contains { $0.contains("source=pack") })
        #expect(live.routeRequests.isEmpty)
        #expect(!pack.routeRequests.isEmpty)
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
            .replaceAll(waypoints: [start, end], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
            source: "fromHere"
        )
        await model.waitForCanonicalBuildForTesting()
        let callsBeforeConversion = source.routeRequests.count + source.fuelChainRequests.count
        let builtBeforeConversion = try #require(model.built)

        model.switchToPlanKeepingFromHere()

        #expect(model.itinerary.waypoints.count == 2)
        #expect(model.built?.legs.count == 1)
        #expect(model.built == builtBeforeConversion)
        #expect(source.routeRequests.count + source.fuelChainRequests.count == callsBeforeConversion)
    }

    @Test func longFromHereRidePromotesLegalGeometryIntoEditableLegsWithoutRerouting() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.notificationsEnabled = false

        let start = point(0)
        let middle = point(0.5)
        let end = point(1)
        let source = PlannerFakeRoutingSource()
        source.distanceOverrides[key(start, end)] = 1_700_000
        source.profileGeometry[.dirt] = [start, middle, end]
        let model = makeModel(source: source)
        model.selectMode(.fromHere)

        model.apply(
            .replaceAll(
                waypoints: [start, end], profile: .dirt, allowUnknown: false,
                avoidMotorways: true, preferBackRoads: false
            ),
            source: "fromHere"
        )
        await model.waitForCanonicalBuildForTesting()

        #expect(source.routeRequests.count == 1)
        #expect(model.mode == .plan)
        #expect(model.itinerary.waypoints.count == 4)
        #expect(model.built?.legs.count == 3)
        #expect(model.built?.legs.map { Int(($0.response.distanceMeters ?? 0).rounded()) }
            == [800_000, 450_000, 450_000])
        #expect(model.itinerary.waypoints.first?.coordinate == start)
        #expect(model.itinerary.waypoints.last?.coordinate == end)
        #expect(model.activeResponses.flatMap(\.coordinates).first == start)
        #expect(model.activeResponses.flatMap(\.coordinates).last == end)
    }

    @Test func continentalFromHereStreamsOneStyledSolveAndEditsOnlyAdjacentLegs() async throws {
        let start = point(0), middle = point(0.5), end = point(1)
        let source = PlannerFakeRoutingSource()
        let map = MapState()
        let model = makeModel(source: source, mapState: map)
        let initialCelebration = model.routeCompletionID
        var requests = 0
        let first = plannerRoadResponse(from: start, to: middle)
        let second = plannerRoadResponse(from: middle, to: end)
        source.progressRouteHandler = { request, progress in
            requests += 1
            #expect(request.profile == .dirt)
            progress(.started(regions: ["ns"]))
            progress(.leg(index: 0, response: first))
            #expect(model.activeRouteProgressMessage == "Building leg 2")
            #expect(model.activeResponses.map(\.coordinates) == [first.coordinates])
            #expect(map.routeBuildCameraSequence?.steps.count == 2)
            #expect(model.routeCompletionID == initialCelebration)
            await Task.yield()
            progress(.leg(index: 1, response: second))
            let full = plannerRoadResponse(from: start, to: end)
            progress(.completed(response: full))
            #expect(model.routeCompletionID == initialCelebration)
            return full
        }
        model.selectMode(.fromHere)
        model.apply(.replaceAll(waypoints: [start, end], profile: .dirt, allowUnknown: false,
            avoidMotorways: true, preferBackRoads: false), source: "fromHere")
        await model.waitForCanonicalBuildForTesting()
        #expect(requests == 1)
        #expect(model.mode == .plan)
        #expect(model.itinerary.waypoints.map(\.coordinate) == [start, middle, end])
        #expect(model.activeResponses.map(\.coordinates) == [first.coordinates, second.coordinates])
        #expect(map.routeBuildCameraSequence?.steps.count == 3)
        #expect(model.routeCompletionID != initialCelebration)
        #expect(model.activeRouteProgressMessage == nil)
        source.progressRouteHandler = nil
        source.routeRequests = []
        let pin = model.itinerary.waypoints[1].id
        model.apply(.move(waypointID: pin, to: point(0.6)), source: "test")
        await model.waitForCanonicalBuildForTesting()
        #expect(source.routeRequests.count == 2)
        #expect(model.itinerary.waypoints[1].id == pin)
        #expect(model.itinerary.waypoints[1].coordinate == point(0.6))
    }

    @Test func failedStreamingChainDiscardsItsGeometryAndCameraBeforeRetry() async throws {
        let source = PlannerFakeRoutingSource()
        let map = MapState()
        let model = makeModel(source: source, mapState: map)
        source.progressRouteHandler = { _, progress in
            progress(.started(regions: ["a"]))
            progress(.leg(index: 0, response: plannerRoadResponse(from: point(0), to: point(0.4))))
            progress(.discarded)
            #expect(model.activeResponses.isEmpty)
            #expect(map.routeBuildCameraSequence?.steps.count == 1)
            progress(.started(regions: ["b"]))
            let result = plannerRoadResponse(from: point(0), to: point(1))
            progress(.completed(response: result))
            return result
        }
        model.selectMode(.fromHere)
        model.apply(.replaceAll(waypoints: [point(0), point(1)], profile: .dirt, allowUnknown: false,
            avoidMotorways: true, preferBackRoads: false), source: "fromHere")
        await model.waitForCanonicalBuildForTesting()
        #expect(model.itinerary.waypoints.count == 2)
        #expect(model.errorMessage == nil)
    }

    @Test func longRouteSplitUsesRouteDistanceAndLeavesShortRoutesAlone() throws {
        let geometry = [point(0), point(0.25), point(0.5), point(0.75), point(1)]
        let long = RouteResponse(
            status: "complete", error: nil, message: nil,
            distanceMeters: 2_100_000,
            estimatedMovingSeconds: 21_000,
            estimatedElapsedSeconds: 22_000,
            geometry: geometry,
            segments: nil,
            stats: RouteStats(dirtPercent: 70, pavedPercent: 30),
            maneuvers: nil,
            warnings: nil,
            dirtPercentValue: nil,
            pavedPercentValue: nil
        )
        let split = try #require(RoutePlannerModel.longRouteSplitPlan(response: long))
        #expect(split.waypoints.count == 4)
        #expect(split.responses.map { Int(($0.distanceMeters ?? 0).rounded()) }
            == [800_000, 800_000, 500_000])
        #expect(split.responses.reduce(0) { $0 + ($1.distanceMeters ?? 0) } == 2_100_000)
        #expect(split.responses.allSatisfy { ($0.distanceMeters ?? .infinity) <= 800_000 })

        var short = long
        short = RouteResponse(
            status: short.status, error: nil, message: nil,
            distanceMeters: 999_999,
            estimatedMovingSeconds: nil,
            estimatedElapsedSeconds: nil,
            geometry: geometry,
            segments: nil,
            stats: short.stats,
            maneuvers: nil,
            warnings: nil,
            dirtPercentValue: nil,
            pavedPercentValue: nil
        )
        #expect(RoutePlannerModel.longRouteSplitPlan(response: short) == nil)
    }

    @Test func planModePromotesTwoPinContinentalRideIntoEditableLegs() async throws {
        let source = PlannerFakeRoutingSource()
        let start = point(0)
        let end = point(1)
        let geometry = [start, point(0.25), point(0.5), point(0.75), end]
        let response = RouteResponse(
                status: "complete", error: nil, message: nil,
                distanceMeters: 2_100_000,
                estimatedMovingSeconds: nil, estimatedElapsedSeconds: nil,
                geometry: geometry, segments: nil,
                stats: RouteStats(dirtPercent: 70, pavedPercent: 30),
                maneuvers: nil, warnings: nil,
                dirtPercentValue: nil, pavedPercentValue: nil
        )
        source.progressRouteHandler = { _, progress in
            progress(.started(regions: []))
            let split = try #require(RoutePlannerModel.longRouteSplitPlan(response: response))
            for (index, leg) in split.responses.enumerated() { progress(.leg(index: index, response: leg)) }
            progress(.completed(response: response))
            return response
        }
        let model = makeModel(source: source)
        model.selectMode(.plan)
        model.apply(.replaceAll(waypoints: [start, end], profile: .dirt,
            allowUnknown: false, avoidMotorways: true, preferBackRoads: true), source: "plan")
        await model.waitForCanonicalBuildForTesting()

        #expect(model.errorMessage == nil)
        #expect(model.mode == .plan)
        #expect(model.itinerary.legs.count == 3)
        #expect(model.itinerary.waypoints.count == 4)
        #expect(model.built?.legs.count == 3)
        #expect(source.routeRequests.count == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRT_QUALIFY_APPEND"] == "1"), .timeLimit(.minutes(10)))
    func actualMaineTennesseeAppendStreamsBeforeCompletion() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DIRT_QUALIFY_PACK_ROOT"]))
        let source = PlannerFakeRoutingSource(name: "pack")
        let map = MapState()
        let model = makeModel(source: source, mapState: map)
        let start = RouteCoordinate(longitude: -63.339801, latitude: 44.765471)
        let maine = RouteCoordinate(longitude: -69.87048722902045, latitude: 44.50814567765103)
        let end = RouteCoordinate(longitude: -85.20936944525984, latitude: 35.25982918763956)
        model.selectMode(.plan)
        model.setPlanningSessionSeedForTesting(234465671932795)
        let session = NativeRoutingSession()
        source.progressRouteHandler = { request, progress in
            let directories = Dictionary(uniqueKeysWithValues: ["ns", "nb", "me"].map {
                ($0, root.appendingPathComponent($0))
            })
            return try await NativeRouteProgressBridge.route(request, session: session, directories: directories, onProgress: progress)
        }
        model.apply(.replaceAll(waypoints: [start, maine], profile: .dirt,
            allowUnknown: false, avoidMotorways: true, preferBackRoads: true), source: "plan")
        model.setPlanningSessionSeedForTesting(234465671932795)
        await model.waitForCanonicalBuildForTesting()
        let prefix = try #require(model.built).legs
        let pins = model.itinerary.waypoints
        let began = ContinuousClock.now
        var times: [Duration] = []
        source.progressRouteHandler = { request, progress in
            let directories = Dictionary(uniqueKeysWithValues: ["me", "qc-s", "ny", "pa", "md", "va", "tn"].map {
                ($0, root.appendingPathComponent($0))
            })
            return try await NativeRouteProgressBridge.route(request, session: session, directories: directories) { event in
                progress(event)
                if case .leg(_, let response) = event {
                    times.append(began.duration(to: .now))
                    #expect(model.activeResponses.first?.coordinates == prefix[0].response.coordinates)
                    #expect(model.activeResponses.last?.coordinates == response.coordinates)
                    #expect(model.routeCompletionID == nil)
                    print("APPEND leg meters=\(response.distanceMeters ?? 0) elapsed=\(times.last!)")
                }
            }
        }
        model.setPlanningSessionSeedForTesting(234465671932795)
        model.apply(.append(coordinate: end), source: "longPress")
        await model.waitForCanonicalBuildForTesting()
        #expect(model.errorMessage == nil)
        #expect(model.built?.legs.first == prefix.first)
        #expect(model.itinerary.waypoints.prefix(pins.count).map(\.id) == pins.map(\.id))
        #expect(times.count >= 2)
        #expect(try #require(times.first) < began.duration(to: .now) - .seconds(1))
        #expect(model.itinerary.legs.count == times.count + prefix.count)
        print("APPEND complete elapsed=\(began.duration(to: .now)) legs=\(model.itinerary.legs.count)")
    }

    @Test func appendedLongLegStreamsWhilePreservingExistingPinsAndRoads() async throws {
        let source = PlannerFakeRoutingSource()
        let map = MapState()
        let model = makeModel(source: source, mapState: map)
        model.selectMode(.plan)
        model.apply(.replaceAll(waypoints: [point(0), point(0.2)], profile: .dirt,
            allowUnknown: false, avoidMotorways: true, preferBackRoads: false), source: "plan")
        await model.waitForCanonicalBuildForTesting()
        let prior = try #require(model.built).legs
        let pins = model.itinerary.waypoints
        source.routeRequests = []
        let first = plannerRoadResponse(from: point(0.2), to: point(0.6))
        let last = plannerRoadResponse(from: point(0.6), to: point(1))
        source.progressRouteHandler = { _, progress in
            progress(.started(regions: ["me", "tn"]))
            progress(.leg(index: 0, response: first))
            #expect(model.activeResponses.first?.coordinates == prior[0].response.coordinates)
            #expect(model.activeResponses.last?.coordinates == first.coordinates)
            #expect(model.activeRouteProgressMessage == "Building leg 3")
            #expect(model.routeCompletionID == nil)
            progress(.discarded)
            #expect(model.activeResponses.map(\.coordinates) == prior.map { $0.response.coordinates })
            progress(.started(regions: ["me", "tn"]))
            progress(.leg(index: 0, response: first))
            progress(.leg(index: 1, response: last))
            return plannerRoadResponse(from: point(0.2), to: point(1))
        }
        model.apply(.append(coordinate: point(1)), source: "longPress")
        await model.waitForCanonicalBuildForTesting()
        #expect(source.routeRequests.count == 1)
        #expect(model.itinerary.waypoints.prefix(pins.count).map(\.id) == pins.map(\.id))
        #expect(model.built?.legs.first == prior.first)
        #expect(model.itinerary.legs.count == 3)
        #expect(model.itinerary.waypoints.map(\.coordinate) == [point(0), point(0.2), point(0.6), point(1)])
        #expect(model.routeCompletionID != nil)
    }

    @Test func longLoopSplitsBothHalvesAndPreservesFarPinAndClosure() async throws {
        let source = PlannerFakeRoutingSource()
        source.distanceOverrides[key(point(0), point(1))] = 2_100_000
        source.distanceOverrides[key(point(1), point(0))] = 2_100_000
        let model = makeModel(source: source)
        model.showingLoop = true
        var observed: [Int] = []
        source.loopProgressInspection = { half, _ in
            observed.append(half)
            #expect(model.routeCompletionID == nil)
            #expect(!model.activeResponses.isEmpty)
            if half == 0 { #expect(source.routeRequests.count == 1) }
        }
        model.generateLoop(start: point(0), far: point(1))
        await model.waitForCanonicalBuildForTesting()
        #expect(observed == [0, 0, 0, 1, 1, 1])
        #expect(source.loopRequestCount == 1)
        #expect(model.itinerary.legs.count == 6)
        #expect(model.itinerary.waypoints.first?.coordinate == point(0))
        #expect(model.itinerary.waypoints.last?.coordinate == point(0))
        #expect(model.itinerary.waypoints.contains { $0.coordinate == point(1) })
        #expect(model.built?.legs.count == 6)
        #expect(model.routeCompletionID != nil)
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
            .replaceAll(waypoints: [start, end], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
            source: "fromHere"
        )
        await model.waitForCanonicalBuildForTesting()
        let originalLeg = try #require(model.itinerary.legs.first)

        model.apply(.insert(afterLegID: originalLeg.id, coordinate: inserted), source: "tap")
        await model.waitForCanonicalBuildForTesting()

        #expect(model.itinerary.waypoints.map(\.coordinate) == [start, inserted, end])
        #expect(model.lastCanonicalBuildFromLegIndex == 0)
        #expect(model.built?.legs.first?.endsAtFuelStop == nil)
        #expect(model.built?.legs.allSatisfy { $0.endsAtFuelStop == nil } == true)

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
            .replaceAll(waypoints: [point(0), point(0.5), point(1)], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
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

    @Test func fuelMarkerCannotMoveCanonicalIntent() async {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 0
        let source = PlannerFakeRoutingSource()
        let model = makeModel(source: source)
        model.apply(
            .replaceAll(waypoints: [point(0), point(1)], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
            source: "seed"
        )
        await model.waitForCanonicalBuildForTesting()
        let before = model.itinerary

        model.moveWaypoint(markerID: "fuel:\(model.itinerary.legs[0].id.uuidString):0", to: point(0.25).locationCoordinate)

        #expect(model.itinerary == before)
        #expect(model.canonicalBuildStartCount == 1)
    }

    @Test func flatLegLabelsIncludeGeneratedFuelStops() async throws {
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
            .replaceAll(waypoints: [first, second, third], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
            source: "seed"
        )
        await model.waitForCanonicalBuildForTesting()

        #expect(model.stages.count == 2)
        #expect(model.stageEndpointTitle(at: 0) == "Point 1 → Point 2")
        #expect(model.stageEndpointTitle(at: 1) == "Point 2 → Point 3")
    }

    @Test func twoWaypointFuelItineraryRendersOnlyItsTwoBuiltLegRows() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 250
        FuelRangePrefs.reservePercent = 5

        let first = point(0)
        let pump = point(0.25)
        let second = point(0.5)
        let source = PlannerFakeRoutingSource()
        source.distanceOverrides[key(first, second)] = 300_000
        source.distanceOverrides[key(first, pump)] = 150_000
        source.distanceOverrides[key(pump, second)] = 150_000
        source.fuelStops = [fuelStop("shell-antigonish", name: "Shell Antigonish", at: pump)]
        let mapState = MapState()
        let model = makeModel(source: source, mapState: mapState)
        model.apply(
            .replaceAll(waypoints: [first, second], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
            source: "seed"
        )
        await model.waitForCanonicalBuildForTesting()

        #expect(model.stages.count == 1)
        #expect(model.stageEndpointTitle(at: 0) == "Point 1 → Point 2")
        #expect(model.stageFuelStationSubtitle(at: 0) == nil)
        #expect(model.stages.allSatisfy { $0.profile == .dirt })

        model.focusStage(at: 0)
        #expect(mapState.routePolylineCoordinates.first == first)
        #expect(mapState.routePolylineCoordinates.last == second)
        #expect(mapState.plannerMarkers.map(\.label) == ["1", "2"])

        model.focusEntirePlannedRoute()
        #expect(mapState.routePolylineCoordinates.first == first)
        #expect(mapState.routePolylineCoordinates.last == second)
        #expect(mapState.plannerMarkers.count == 2)

        model.toast = RoutePlannerModel.routeReadyToast
        #expect(model.frameCompletedRouteForCelebration())
        #expect(model.toast == RoutePlannerModel.routeReadyToast)
        guard let camera = mapState.camera,
              case let .fit(coordinates) = camera.command else {
            Issue.record("Route completion should fit the complete route")
            return
        }
        #expect(coordinates.first == first)
        #expect(coordinates.last == second)
    }

    @Test func twoWaypointTwoStopItineraryRendersExactlyThreeFlatRows() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 220
        FuelRangePrefs.reservePercent = 5

        let first = point(0)
        let firstPump = point(0.25)
        let secondPump = point(0.5)
        let second = point(0.75)
        let source = PlannerFakeRoutingSource()
        source.distanceOverrides[key(first, second)] = 510_000
        source.distanceOverrides[key(first, firstPump)] = 170_000
        source.distanceOverrides[key(firstPump, secondPump)] = 170_000
        source.distanceOverrides[key(secondPump, second)] = 170_000
        source.fuelStops = [
            fuelStop("irving", name: "Irving", at: firstPump),
            fuelStop("caper-gas", name: "Caper Gas", at: secondPump)
        ]
        let map = MapState()
        let model = makeModel(source: source, mapState: map)
        model.apply(
            .replaceAll(waypoints: [first, second], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
            source: "seed"
        )
        await model.waitForCanonicalBuildForTesting()

        #expect(model.stages.count == 1)
        #expect(model.stages.map(\.profile) == [.dirt])
        #expect(model.stageEndpointTitle(at: 0) == "Point 1 → Point 2")
        #expect(model.built?.legs.count == 1)
        #expect(map.plannerMarkers.contains { $0.id.hasPrefix("break:") } == false)
        #expect(model.built?.legs.allSatisfy { $0.endsAtFuelStop == nil } == true)
    }

    @Test func perLegStyleSelectorAppliesToEachRiderLeg() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 220
        FuelRangePrefs.reservePercent = 5

        let first = point(0)
        let second = point(0.5)
        let third = point(1)
        let source = PlannerFakeRoutingSource()
        source.distanceOverrides[key(first, second)] = 80_000
        source.distanceOverrides[key(second, third)] = 90_000
        let model = makeModel(source: source)
        model.apply(
            .replaceAll(waypoints: [first, second, third], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
            source: "seed"
        )
        await model.waitForCanonicalBuildForTesting()
        #expect(model.stages.count == 2)
        #expect(model.stages.map(\.profile) == [.dirt, .dirt])
        #expect(model.built?.legs.allSatisfy { $0.endsAtFuelStop == nil } == true)

        source.routeRequests.removeAll()
        source.fuelChainRequests.removeAll()
        model.setStageProfile(.balanced, at: 1)
        await model.waitForCanonicalBuildForTesting()
        #expect(model.itinerary.legs[0].profile == .dirt)
        #expect(model.itinerary.legs[1].profile == .balanced)
        #expect(model.stages.map(\.profile) == [.dirt, .balanced])
        #expect(source.fuelChainRequests.isEmpty)
        #expect(source.routeRequests.contains { $0.profile == .balanced })

        source.routeRequests.removeAll()
        model.setStageProfile(.dirt, at: 0)
        await model.waitForCanonicalBuildForTesting()
        #expect(model.itinerary.legs[0].profile == .dirt)
        #expect(model.itinerary.legs[1].profile == .balanced)
        #expect(model.stages.map(\.profile) == [.dirt, .balanced])
    }

    @Test func perLegRideSettingsReachOnlyThatLegsRouteRequest() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.notificationsEnabled = false
        let source = PlannerFakeRoutingSource()
        let model = makeModel(source: source)
        model.apply(
            .replaceAll(
                waypoints: [point(0), point(0.5), point(1)],
                profile: .dirt,
                allowUnknown: false,
                avoidMotorways: false,
                preferBackRoads: false
            ),
            source: "seed"
        )
        await model.waitForCanonicalBuildForTesting()
        let firstPreferences = model.itinerary.legs[0].ridePreferences
        let selectedPreferences = RidePreferences(
            wander: 0.9,
            avoidCities: false,
            avoidHighways: false,
            avoidFerries: false
        )

        source.routeRequests.removeAll()
        model.applyLegRideSettings(
            at: 1,
            profile: .balanced,
            allowUnknown: true,
            ridePreferences: selectedPreferences
        )
        await model.waitForCanonicalBuildForTesting()

        #expect(model.itinerary.legs[0].ridePreferences == firstPreferences)
        #expect(model.itinerary.legs[1].ridePreferences == selectedPreferences)
        #expect(source.routeRequests.allSatisfy {
            $0.options?.ridePreferences == selectedPreferences
        })
    }

    @Test func defaultRideSettingsAreCopiedIntoNewPlanLegs() async throws {
        let source = PlannerFakeRoutingSource()
        let model = makeModel(source: source)
        let firstDefaults = RidePreferences(
            wander: 0.7,
            avoidCities: false,
            avoidHighways: true,
            avoidFerries: false
        )
        model.applyDefaultRideSettings(
            profile: .balanced,
            allowUnknown: true,
            ridePreferences: firstDefaults
        )

        model.apply(.append(coordinate: point(0)), source: "test")
        model.apply(.append(coordinate: point(0.5)), source: "test")
        await model.waitForCanonicalBuildForTesting()

        let laterDefaults = RidePreferences(
            wander: 0.25,
            avoidCities: true,
            avoidHighways: false,
            avoidFerries: true
        )
        model.applyDefaultRideSettings(
            profile: .dirt,
            allowUnknown: false,
            ridePreferences: laterDefaults
        )

        #expect(model.itinerary.legs[0].profile == .balanced)
        #expect(model.itinerary.legs[0].allowUnknown)
        #expect(model.itinerary.legs[0].ridePreferences == firstDefaults)

        model.apply(.append(coordinate: point(1)), source: "test")
        await model.waitForCanonicalBuildForTesting()

        #expect(model.itinerary.legs.count == 2)
        #expect(model.itinerary.legs[0].ridePreferences == firstDefaults)
        #expect(model.itinerary.legs[1].profile == .dirt)
        #expect(!model.itinerary.legs[1].allowUnknown)
        #expect(model.itinerary.legs[1].ridePreferences == laterDefaults)
    }

    @Test func stageCardFuelHopControlsDriveCleanPlanRebuild() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 220
        FuelRangePrefs.reservePercent = 5

        let first = point(0)
        let second = point(0.5)
        let third = point(1)
        let source = PlannerFakeRoutingSource()
        source.distanceOverrides[key(first, second)] = 80_000
        source.distanceOverrides[key(second, third)] = 90_000
        let model = makeModel(source: source)
        model.apply(
            .replaceAll(
                waypoints: [first, second, third],
                profile: .cleanest,
                allowUnknown: false,
                avoidMotorways: true,
                preferBackRoads: false
            ),
            source: "seed"
        )
        await model.waitForCanonicalBuildForTesting()
        #expect(model.stages.map(\.profile) == [.cleanest, .cleanest])
        #expect(model.built?.legs.allSatisfy { $0.endsAtFuelStop == nil } == true)

        source.routeRequests.removeAll()
        model.setFuelHopProfile(.balanced, at: 0)
        await model.waitForCanonicalBuildForTesting()
        #expect(model.itinerary.legs[0].profile == .balanced)
        #expect(model.itinerary.legs[0].hopOverrides.isEmpty)
        #expect(model.stages[0].profile == .balanced)
        #expect(source.routeRequests.contains { $0.profile == .balanced })
        #expect(source.routeRequests.contains {
            $0.profile == .balanced && $0.accessPolicy.motorizedUnknown == false
        })

        source.routeRequests.removeAll()
        model.setStageAllowUnknown(true, at: 0)
        await model.waitForCanonicalBuildForTesting()
        #expect(model.itinerary.legs[0].allowUnknown)
        #expect(model.stages[0].allowUnknown)
        #expect(source.routeRequests.contains {
            $0.profile == .balanced && $0.accessPolicy.motorizedUnknown == true
        })
        #expect(model.built?.legs.allSatisfy { $0.endsAtFuelStop == nil } == true)

        source.routeRequests.removeAll()
        model.setFuelHopProfile(.dirt, at: 1)
        await model.waitForCanonicalBuildForTesting()
        #expect(model.itinerary.legs[1].profile == .dirt)
        #expect(model.stages[1].profile == .dirt)
        #expect(model.stages[0].profile == .balanced)
        #expect(source.routeRequests.contains { $0.profile == .dirt })
    }

    @Test func cleanSecondLegOwnsItsHighwayPolicy() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 220
        FuelRangePrefs.reservePercent = 5

        let first = point(0)
        let second = point(0.5)
        let third = point(1)
        let source = PlannerFakeRoutingSource()
        source.distanceOverrides[key(first, second)] = 80_000
        source.distanceOverrides[key(second, third)] = 90_000
        let model = makeModel(source: source)
        model.apply(
            .replaceAll(waypoints: [first, second, third], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
            source: "seed"
        )
        await model.waitForCanonicalBuildForTesting()

        source.routeRequests.removeAll()
        source.fuelChainRequests.removeAll()
        model.setStageProfile(.cleanest, at: 1)
        await model.waitForCanonicalBuildForTesting()

        #expect(model.itinerary.legs[0].profile == .dirt)
        #expect(model.itinerary.legs[1].profile == .cleanest)
        #expect(model.stages[0].profile == .dirt)
        #expect(model.stages[1].profile == .cleanest)
        #expect(model.stages[1].avoidMotorways)
        #expect(source.fuelChainRequests.isEmpty)
        #expect(source.routeRequests.contains {
            $0.profile == .cleanest && $0.options?.avoidMotorways == true
        })

        source.routeRequests.removeAll()
        model.setStageAvoidMotorways(false, at: 1)
        await model.waitForCanonicalBuildForTesting()
        #expect(!model.stages[1].avoidMotorways)
        #expect(source.routeRequests.contains {
            $0.profile == .cleanest && $0.options?.avoidMotorways != true
        })
    }

    @Test func tappingAFuelPinDoesNothingWhenRoutingDidNotPlaceStops() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 250
        FuelRangePrefs.reservePercent = 5

        let first = point(0)
        let second = point(0.5)
        let source = PlannerFakeRoutingSource()
        source.distanceOverrides[key(first, second)] = 300_000
        source.fuelStops = [fuelStop("primary", name: "Primary Pump", at: point(0.25))]
        let model = makeModel(source: source)
        model.apply(
            .replaceAll(waypoints: [first, second], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
            source: "seed"
        )
        await model.waitForCanonicalBuildForTesting()

        #expect(model.built?.legs.first?.endsAtFuelStop == nil)
        #expect(!model.canReplaceFuelStop(at: 0))
        #expect(source.fuelChainRequests.isEmpty)
    }

    @Test func draftCanBeRefinedWithoutPromptUntilPinTapAndRequiresRoadSnap() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.notificationsEnabled = false
        let source = PlannerFakeRoutingSource()
        let map = MapState()
        let model = makeModel(source: source, mapState: map)
        model.selectMode(.plan)
        model.apply(.replaceAll(waypoints: [point(0), point(1)], profile: .dirt,
            allowUnknown: false, avoidMotorways: false, preferBackRoads: false), source: "seed")
        await model.waitForCanonicalBuildForTesting()
        source.routeRequests.removeAll()
        model.handleRouteTap(point(0.5).locationCoordinate, source: "longPress")
        for position in [point(0.3), point(0.6), point(0.8)] {
            model.moveWaypoint(markerID: "waypoint-draft", to: position.locationCoordinate)
            model.refreshMap() // Map viewport/redraw and re-selection are not acceptance.
            map.selectPlannerPin("waypoint-draft")
            #expect(!model.showsWaypointPlacementConfirmation)
            model.confirmWaypointPlacement() // No prompt means no commit.
            #expect(model.waypointPlacement?.coordinate == position)
            #expect(model.itinerary.waypoints.count == 2)
            #expect(source.routeRequests.isEmpty)
        }
        model.requestWaypointPlacementConfirmation(markerID: "waypoint-draft", snappedCoordinate: nil)
        #expect(!model.showsWaypointPlacementConfirmation)
        #expect(model.waypointPlacement?.coordinate == point(0.8))
        #expect(model.toast?.contains("No nearby road") == true)
        model.requestWaypointPlacementConfirmation(markerID: "wp:unrelated", snappedCoordinate: point(0.2).locationCoordinate)
        #expect(!model.showsWaypointPlacementConfirmation)
        model.requestWaypointPlacementConfirmation(markerID: "waypoint-draft", snappedCoordinate: point(0.75).locationCoordinate)
        #expect(model.showsWaypointPlacementConfirmation)
        #expect(model.waypointPlacement?.coordinate == point(0.75))
        model.keepMovingWaypoint()
        model.confirmWaypointPlacement()
        #expect(source.routeRequests.isEmpty)
        model.moveWaypoint(markerID: "waypoint-draft", to: point(0.6).locationCoordinate)
        #expect(!model.showsWaypointPlacementConfirmation)
        model.requestWaypointPlacementConfirmation(markerID: "waypoint-draft", snappedCoordinate: point(0.55).locationCoordinate)
        model.confirmWaypointPlacement()
        await model.waitForCanonicalBuildForTesting()
        #expect(model.itinerary.waypoints.map(\.coordinate) == [point(0), point(0.55), point(1)])
        #expect(model.waypointPlacement == nil)
        #expect(!source.routeRequests.isEmpty)
    }

    @Test func addedWaypointWaitsForConfirmationAfterDragging() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 0
        let source = PlannerFakeRoutingSource()
        let model = makeModel(source: source)
        model.selectMode(.plan)
        model.apply(.replaceAll(waypoints: [point(0), point(1)], profile: .dirt,
            allowUnknown: false, avoidMotorways: false, preferBackRoads: false), source: "seed")
        await model.waitForCanonicalBuildForTesting()
        source.routeRequests.removeAll()
        model.handleRouteTap(point(0).locationCoordinate, source: "longPress")
        #expect(model.waypointPlacement != nil)
        #expect(!model.showsWaypointPlacementConfirmation)
        #expect(model.itinerary.waypoints.count == 2)
        #expect(source.routeRequests.isEmpty)
        model.keepMovingWaypoint()
        #expect(!model.showsWaypointPlacementConfirmation)
        model.moveWaypoint(markerID: "waypoint-draft", to: CLLocationCoordinate2D(latitude: (point(0).latitude + point(1).latitude) / 2, longitude: (point(0).longitude + point(1).longitude) / 2))
        #expect(!model.showsWaypointPlacementConfirmation)
        model.requestWaypointPlacementConfirmation(markerID: "waypoint-draft", snappedCoordinate: CLLocationCoordinate2D(latitude: (point(0).latitude + point(1).latitude) / 2, longitude: (point(0).longitude + point(1).longitude) / 2))
        #expect(model.showsWaypointPlacementConfirmation)
        #expect(source.routeRequests.isEmpty)
        model.confirmWaypointPlacement()
        await model.waitForCanonicalBuildForTesting()
        #expect(model.waypointPlacement == nil)
        #expect(model.itinerary.waypoints.count == 3)
        #expect(!source.routeRequests.isEmpty)
    }

    @Test func failedContinuationKeepsDestinationAndInsertedPinCanBeDeleted() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.notificationsEnabled = false
        let source = PlannerFakeRoutingSource()
        let map = MapState()
        let model = makeModel(source: source, mapState: map)
        let start = point(0), destination = point(1), inserted = point(0.5)
        let snapped = RouteCoordinate(longitude: inserted.longitude + 0.0002, latitude: inserted.latitude)
        source.routeHandler = { req in
            let (a, b) = try requestEndpoints(req)
            if req.options?.arrivalEdgeId != nil {
                #expect(a == snapped)
                throw RoutingError.server("scripted onward failure")
            }
            return plannerRoadResponse(from: a, to: b == inserted ? snapped : b)
        }
        model.apply(.replaceAll(waypoints: [start, destination], profile: .dirt,
            allowUnknown: false, avoidMotorways: false, preferBackRoads: false), source: "fromHere")
        await model.waitForCanonicalBuildForTesting()
        let originalDestinationID = try #require(model.itinerary.waypoints.last?.id)
        model.handleRouteTap(start.locationCoordinate, source: "longPress")
        model.moveWaypoint(markerID: "waypoint-draft", to: inserted.locationCoordinate)
        #expect(!model.showsWaypointPlacementConfirmation)
        model.requestWaypointPlacementConfirmation(markerID: "waypoint-draft", snappedCoordinate: inserted.locationCoordinate)
        model.confirmWaypointPlacement()
        model.confirmWaypointPlacement() // A repeated callback must not insert twice.
        await model.waitForCanonicalBuildForTesting()
        #expect(model.mode == .plan)
        #expect(model.itinerary.waypoints.map(\.coordinate) == [start, inserted, destination])
        #expect(model.itinerary.waypoints.last?.id == originalDestinationID)
        #expect(model.built?.legs.count == 1)
        #expect(model.stages.count == 2)
        #expect(model.stages[1].error != nil)
        #expect(map.plannerMarkers.filter { $0.id.hasPrefix("wp:") }.count == 3)
        #expect(!map.plannerMarkers.contains { $0.id == "waypoint-draft" })
        model.deleteStage(at: 0)
        await model.waitForCanonicalBuildForTesting()
        #expect(model.itinerary.waypoints.map(\.coordinate) == [start, destination])
        #expect(model.itinerary.waypoints.last?.id == originalDestinationID)
        #expect(model.stages.count == 1)
        #expect(model.stages[0].error == nil)
        #expect(map.plannerMarkers.filter { $0.id.hasPrefix("wp:") }.count == 2)
    }

    @Test func insertedWaypointMoveAndDeleteKeepOneIdentityAndContinuousRoads() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.notificationsEnabled = false
        let source = PlannerFakeRoutingSource()
        let model = makeModel(source: source)
        let start = point(0), destination = point(1)
        source.routeHandler = { req in
            let (a, b) = try requestEndpoints(req)
            let matched = b == destination ? b : RouteCoordinate(longitude: b.longitude + 0.0002, latitude: b.latitude)
            return plannerRoadResponse(from: a, to: matched)
        }
        model.apply(.replaceAll(waypoints: [start, destination], profile: .dirt,
            allowUnknown: false, avoidMotorways: false, preferBackRoads: false), source: "fromHere")
        await model.waitForCanonicalBuildForTesting()
        model.handleRouteTap(start.locationCoordinate, source: "longPress")
        model.moveWaypoint(markerID: "waypoint-draft", to: point(0.4).locationCoordinate)
        #expect(!model.showsWaypointPlacementConfirmation)
        model.requestWaypointPlacementConfirmation(markerID: "waypoint-draft", snappedCoordinate: point(0.4).locationCoordinate)
        model.keepMovingWaypoint()
        model.moveWaypoint(markerID: "waypoint-draft", to: point(0.5).locationCoordinate)
        #expect(!model.showsWaypointPlacementConfirmation)
        model.requestWaypointPlacementConfirmation(markerID: "waypoint-draft", snappedCoordinate: point(0.5).locationCoordinate)
        model.confirmWaypointPlacement()
        await model.waitForCanonicalBuildForTesting()
        let id = model.itinerary.waypoints[1].id
        for coordinate in [point(0.6), point(0.7)] {
            model.moveWaypoint(markerID: "wp:\(id.uuidString)", to: coordinate.locationCoordinate)
            #expect(!model.showsWaypointPlacementConfirmation)
            model.requestWaypointPlacementConfirmation(markerID: "wp:\(id.uuidString)", snappedCoordinate: coordinate.locationCoordinate)
            model.confirmWaypointPlacement()
            await model.waitForCanonicalBuildForTesting()
            #expect(model.itinerary.waypoints.count == 3)
            #expect(model.itinerary.waypoints[1].id == id)
            #expect(model.itinerary.waypoints[1].coordinate == coordinate)
            #expect(model.itinerary.waypoints.last?.coordinate == destination)
            let built = try #require(model.built)
            #expect(built.legs.count == 2)
            #expect(built.legs[0].response.coordinates.last == built.legs[1].response.coordinates.first)
        }
        model.deleteStage(at: 0)
        await model.waitForCanonicalBuildForTesting()
        #expect(model.itinerary.waypoints.map(\.coordinate) == [start, destination])
    }

    @Test func existingWaypointMoveWaitsForYesAndNoAllowsRefinement() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 0
        let source = PlannerFakeRoutingSource()
        let model = makeModel(source: source)
        model.selectMode(.plan)
        model.apply(.replaceAll(waypoints: [point(0), point(1)], profile: .dirt,
            allowUnknown: false, avoidMotorways: false, preferBackRoads: false), source: "seed")
        await model.waitForCanonicalBuildForTesting()
        let waypoint = try #require(model.itinerary.waypoints.last)
        source.routeRequests.removeAll()
        let markerID = "wp:\(waypoint.id.uuidString)"
        model.moveWaypoint(markerID: markerID, to: point(0.7).locationCoordinate)
        #expect(!model.showsWaypointPlacementConfirmation)
        model.requestWaypointPlacementConfirmation(markerID: markerID, snappedCoordinate: point(0.7).locationCoordinate)
        #expect(model.showsWaypointPlacementConfirmation)
        #expect(model.itinerary.waypoints.last?.coordinate == waypoint.coordinate)
        #expect(source.routeRequests.isEmpty)
        model.keepMovingWaypoint()
        #expect(!model.showsWaypointPlacementConfirmation)
        model.confirmWaypointPlacement()
        #expect(source.routeRequests.isEmpty)
        model.moveWaypoint(markerID: markerID, to: point(0.8).locationCoordinate)
        #expect(!model.showsWaypointPlacementConfirmation)
        model.requestWaypointPlacementConfirmation(markerID: markerID, snappedCoordinate: point(0.8).locationCoordinate)
        model.confirmWaypointPlacement()
        await model.waitForCanonicalBuildForTesting()
        #expect(model.waypointMove == nil)
        #expect(model.itinerary.waypoints.last?.coordinate == point(0.8))
        #expect(!source.routeRequests.isEmpty)
    }

    @Test func confirmedPlanWaypointsStayUnlockedForMoveSelection() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 0
        let source = PlannerFakeRoutingSource()
        let map = MapState()
        let model = makeModel(source: source, mapState: map)
        model.selectMode(.plan)
        model.apply(
            .replaceAll(
                waypoints: [point(0), point(0.4), point(0.7), point(1)],
                profile: .dirt,
                allowUnknown: false,
                avoidMotorways: false,
                preferBackRoads: false
            ),
            source: "seed"
        )
        await model.waitForCanonicalBuildForTesting()

        let wpMarkers = map.plannerMarkers.filter { $0.id.hasPrefix("wp:") }
        #expect(wpMarkers.count == 4)
        #expect(wpMarkers.allSatisfy { !$0.isLocked })
        #expect(model.stages.count == 3)

        let first = try #require(wpMarkers.first)
        let third = try #require(wpMarkers.dropFirst(2).first)
        map.selectPlannerPin(first.id)
        #expect(map.selectedPlannerPinID == first.id)
        map.selectPlannerPin(third.id)
        #expect(map.selectedPlannerPinID == third.id)

        model.moveWaypoint(markerID: third.id, to: point(0.75).locationCoordinate)
        #expect(!model.showsWaypointPlacementConfirmation)
        model.requestWaypointPlacementConfirmation(markerID: third.id, snappedCoordinate: point(0.75).locationCoordinate)
        #expect(model.showsWaypointPlacementConfirmation)
        #expect(model.waypointMove != nil)
    }

    @Test func failedRouteKeepsItsRiderLegVisible() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 0
        let source = PlannerFakeRoutingSource()
        source.routeError = RoutingError.server("No eligible edge near Point 1")
        let model = makeModel(source: source)
        model.apply(
            .replaceAll(waypoints: [point(0), point(1)], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
            source: "seed"
        )
        await model.waitForCanonicalBuildForTesting()

        #expect(model.itinerary.waypoints.count == 2)
        #expect(model.stages.count == 1)
        #expect(model.stageEndpointTitle(at: 0) == "Point 1 → Point 2")
        #expect(model.stages[0].error == "No eligible edge near Point 1")
    }

    @Test func fuelServiceFailureCompletesRouteWithUnverifiedWarning() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 250
        FuelRangePrefs.reservePercent = 5
        let start = point(0)
        let end = point(1)
        let source = PlannerFakeRoutingSource()
        source.distanceOverrides[key(start, end)] = 300_000
        source.fuelChainError = RoutingError.server("Routing service timed out")
        let model = makeModel(source: source)
        model.apply(
            .replaceAll(waypoints: [start, end], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
            source: "seed"
        )
        await model.waitForCanonicalBuildForTesting()

        #expect(model.fuelGaps.isEmpty)
        #expect(model.unacknowledgedFuelGaps.isEmpty)
        #expect(model.stages.count == 1)
        #expect(model.stages[0].error == nil)
        #expect(model.stages[0].fuelUnknown == nil)
        #expect(model.stages[0].response != nil)
        #expect(model.errorMessage == nil)
        #expect(model.hasRoute)
        #expect(model.fuelCoverageNotices.isEmpty)
        #expect(source.fuelChainRequests.isEmpty)
    }

    @Test func fuelWarningProjectsOnlyOntoUnverifiedTailStage() {
        let warning = LegStatus.fuelUnknown("Fuel coverage could not be verified")

        #expect(RoutePlannerModel.projectedStatus(
            warning, builtStageIndex: 0, builtStageCount: 4
        ) == .built)
        #expect(RoutePlannerModel.projectedStatus(
            warning, builtStageIndex: 1, builtStageCount: 4
        ) == .built)
        #expect(RoutePlannerModel.projectedStatus(
            warning, builtStageIndex: 2, builtStageCount: 4
        ) == .built)
        #expect(RoutePlannerModel.projectedStatus(
            warning, builtStageIndex: 3, builtStageCount: 4
        ) == warning)
    }
}

@MainActor
private func makeModel(
    source: PlannerFakeRoutingSource,
    policy: RoutingSourcePolicy? = nil,
    mapState: MapState? = nil,
    locationService: LocationService? = nil
) -> RoutePlannerModel {
    RoutePlannerModel(
        routing: RoutingClient(),
        locationService: locationService ?? LocationService(),
        mapState: mapState ?? MapState(),
        navigation: NavigationSession(),
        offline: OfflineTileManager(),
        graphPacks: GraphPackStore(),
        network: NetworkPathMonitor(),
        routingSourcePolicy: policy ?? .fixed(source),
        itineraryBuilder: ItineraryBuilder(),
        packAcquisition: {
            let coverage = PermissivePackCoverage()
            return PackAcquisitionCoordinator(inspect: coverage, installer: coverage)
        }()
    )
}

@MainActor
private final class PermissivePackCoverage: PackCoverageInspecting, PackInstalling {
    let routingManifestVersion = "test-permissive"

    func isRoutingPackInstalled(_ regionID: String) -> Bool { true }
    func installedRoutingGraphPath(regionID: String) -> String? {
        "/fake/\(regionID)/graph.v2.bin"
    }
    func isRoutingPackPublished(_ regionID: String) -> Bool { true }
    func resolveCatalogRegionId(_ regionID: String) -> String? { regionID.lowercased() }
    func requiredCatalogRoutingRegions(for coordinates: [CLLocationCoordinate2D]) -> [String] {
        coordinates.compactMap { GraphPackStore.primaryRegionId(containing: $0)?.lowercased() }
    }
    func packRevisionState(_ regionID: String) -> PackRevisionState { .current }
    func displayTitle(forRegionId id: String) -> String { id.uppercased() }
    func installVerifiedPacks(_ regionIDs: [String], replaceInstalled: Bool) async throws {}
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
    let name: String
    var routeRequests: [RouteRequest] = []
    var fuelChainRequests: [FuelChainRequest] = []
    var distanceOverrides: [String: Double] = [:]
    var profileGeometry: [RouteProfile: [RouteCoordinate]] = [:]
    var fuelStops: [FuelChainStop] = []
    var stationCandidates: [FuelStationCandidate] = []
    var routeError: Error?
    var routeHandler: ((RouteRequest) async throws -> RouteResponse)?
    var progressRouteHandler: ((RouteRequest, @escaping @MainActor (RouteBuildProgress) -> Void) async throws -> RouteResponse)?

    func route(_ req: RouteRequest, onProgress: @escaping @MainActor (RouteBuildProgress) -> Void) async throws -> RouteResponse {
        if let progressRouteHandler {
            routeRequests.append(req)
            return try await progressRouteHandler(req, onProgress)
        }
        let response = try await route(req)
        onProgress(.completed(response: response))
        return response
    }
    var fuelChainError: Error?

    init(name: String = "live") {
        self.name = name
    }

    func route(_ req: RouteRequest) async throws -> RouteResponse {
        routeRequests.append(req)
        if let routeHandler { return try await routeHandler(req) }
        if let routeError { throw routeError }
        let endpoints = try requestEndpoints(req)
        let meters = distanceOverrides[key(endpoints.0, endpoints.1)] ?? 100_000
        return RouteResponse(
            status: "complete", error: nil, message: nil,
            distanceMeters: meters,
            estimatedMovingSeconds: nil, estimatedElapsedSeconds: nil,
            geometry: profileGeometry[req.profile] ?? [endpoints.0, endpoints.1], segments: nil,
            stats: RouteStats(dirtPercent: 80, pavedPercent: 20),
            maneuvers: nil, warnings: nil,
            dirtPercentValue: nil, pavedPercentValue: nil
        )
    }

    var loopRequestCount = 0
    var loopProgressInspection: ((Int, RouteBuildProgress) -> Void)?
    func planLoop(_ request: PlannedLoopRequest,
                  onProgress: @escaping @MainActor (Int, RouteBuildProgress) -> Void) async throws -> PlannedLoop {
        loopRequestCount += 1
        var responses: [RouteResponse] = []
        for (index, pair) in [(request.start, request.far), (request.far, request.start)].enumerated() {
            let response = try await route(RouteRequest(profile: request.profile, locations: [
                RouteLocation(latitude: pair.0.latitude, longitude: pair.0.longitude, label: "start"),
                RouteLocation(latitude: pair.1.latitude, longitude: pair.1.longitude, label: "end")
            ], allowUnknown: request.allowUnknown))
            onProgress(index, .started(regions: []))
            if let split = RoutePlannerModel.longRouteSplitPlan(response: response) {
                for (partIndex, part) in split.responses.enumerated() {
                    let event = RouteBuildProgress.leg(index: partIndex, response: part)
                    onProgress(index, event)
                    loopProgressInspection?(index, event)
                }
            }
            onProgress(index, .completed(response: response))
            responses.append(response)
        }
        return PlannedLoop(far: request.far, outbound: responses[0], inbound: responses[1], reriddenMeters: 0, returnMeters: 0)
    }

    func planLoop(_ request: PlannedLoopRequest) async throws -> PlannedLoop {
        loopRequestCount += 1
        func leg(_ from: RouteCoordinate, _ to: RouteCoordinate) async throws -> RouteResponse {
            try await route(RouteRequest(profile: request.profile, locations: [
                RouteLocation(latitude: from.latitude, longitude: from.longitude, label: "start"),
                RouteLocation(latitude: to.latitude, longitude: to.longitude, label: "end")
            ], allowUnknown: request.allowUnknown))
        }
        return try await PlannedLoop(far: request.far,
            outbound: leg(request.start, request.far), inbound: leg(request.far, request.start),
            reriddenMeters: 0, returnMeters: 0)
    }

    func fuelChain(_ req: FuelChainRequest) async throws -> FuelChainResponse {
        fuelChainRequests.append(req)
        if let fuelChainError { throw fuelChainError }
        let selectedStops: [FuelChainStop]
        if let required = req.fuel.requiredFirstStationId,
           let candidate = stationCandidates.first(where: { $0.id == required }),
           let latitude = candidate.latitude,
           let longitude = candidate.longitude {
            selectedStops = [FuelChainStop(
                id: candidate.id, latitude: latitude, longitude: longitude,
                name: candidate.name, brand: nil, address: nil, graphMeters: candidate.meters
            )]
        } else {
            let endpoints = (
                RouteCoordinate(
                    longitude: req.locations[0].longitude,
                    latitude: req.locations[0].latitude
                ),
                RouteCoordinate(
                    longitude: req.locations[1].longitude,
                    latitude: req.locations[1].latitude
                )
            )
            if let remaining = distanceOverrides[key(endpoints.0, endpoints.1)],
               remaining <= req.fuel.firstLegMaxMeters + 1 {
                selectedStops = []
            } else if let currentIndex = fuelStops.firstIndex(where: {
                $0.coordinate == endpoints.0
            }) {
                selectedStops = fuelStops.indices.contains(currentIndex + 1)
                    ? [fuelStops[currentIndex + 1]]
                    : []
            } else {
                selectedStops = fuelStops.first.map { [$0] } ?? []
            }
        }
        return FuelChainResponse(
            status: "complete", error: nil, message: nil, regionIds: ["test"],
            stops: selectedStops, graphMeters: nil,
            diagnostics: FuelChainDiagnostics(
                strategy: "fake", states: 1, dijkstraPops: 1,
                matchedFuel: selectedStops.count, elapsedMs: 1
            ),
            stationCandidates: stationCandidates
        )
    }

    func fuelStation(near point: RouteCoordinate, within meters: Double) async throws -> FuelChainStop? {
        nil
    }
}

private struct FuelPrefsRestore {
    let kilometers = FuelRangePrefs.kilometers
    let reserve = FuelRangePrefs.reservePercent
    let notifications = FuelRangePrefs.notificationsEnabled

    func restore() {
        FuelRangePrefs.kilometers = kilometers
        FuelRangePrefs.reservePercent = reserve
        FuelRangePrefs.notificationsEnabled = notifications
    }
}

private func point(_ value: Double) -> RouteCoordinate {
    RouteCoordinate(longitude: -63 + value, latitude: 45 + value / 10)
}

private func key(_ from: RouteCoordinate, _ to: RouteCoordinate) -> String {
    "\(from.latitude),\(from.longitude)>\(to.latitude),\(to.longitude)"
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

@MainActor
private func plannerRoadResponse(from: RouteCoordinate, to: RouteCoordinate) -> RouteResponse {
    RouteResponse(status: "complete", error: nil, message: nil, distanceMeters: 100_000,
        estimatedMovingSeconds: nil, estimatedElapsedSeconds: nil,
        geometry: [from, to], segments: nil, stats: .init(dirtPercent: 80, pavedPercent: 20),
        maneuvers: nil, warnings: nil, dirtPercentValue: nil, pavedPercentValue: nil,
        arrivalEdgeId: "reached-road")
}

private func recoveryFixture(_ coordinates: [RouteCoordinate], edge: String) -> RouteResponse {
    let meters = GeoMath.lineMeters(coordinates)
    return RouteResponse(status: "complete", error: nil, message: nil, distanceMeters: meters,
        estimatedMovingSeconds: nil, estimatedElapsedSeconds: nil, geometry: coordinates,
        segments: [RouteSegment(surfaceClass: "paved", trackClass: nil, distanceMeters: meters,
            geometry: coordinates, coords: nil, edgeId: edge)],
        stats: RouteStats(dirtPercent: 0, pavedPercent: 100), maneuvers: nil, warnings: nil,
        dirtPercentValue: nil, pavedPercentValue: nil)
}
