import Foundation
import CoreLocation
import SwiftUI
import Testing
@testable import Dirt

@MainActor
@Suite(.serialized)
struct RoutePlannerModelItineraryTests {
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
        #expect(model.showsWaypointPlacementConfirmation)
        #expect(source.routeRequests.isEmpty)
        model.confirmWaypointPlacement()
        await model.waitForCanonicalBuildForTesting()
        #expect(model.waypointPlacement == nil)
        #expect(model.itinerary.waypoints.count == 3)
        #expect(!source.routeRequests.isEmpty)
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
        #expect(model.showsWaypointPlacementConfirmation)
        #expect(model.itinerary.waypoints.last?.coordinate == waypoint.coordinate)
        #expect(source.routeRequests.isEmpty)
        model.keepMovingWaypoint()
        #expect(!model.showsWaypointPlacementConfirmation)
        model.confirmWaypointPlacement()
        #expect(source.routeRequests.isEmpty)
        model.moveWaypoint(markerID: markerID, to: point(0.8).locationCoordinate)
        model.confirmWaypointPlacement()
        await model.waitForCanonicalBuildForTesting()
        #expect(model.waypointMove == nil)
        #expect(model.itinerary.waypoints.last?.coordinate == point(0.8))
        #expect(!source.routeRequests.isEmpty)
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
    mapState: MapState? = nil
) -> RoutePlannerModel {
    RoutePlannerModel(
        routing: RoutingClient(),
        locationService: LocationService(),
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
    var fuelChainError: Error?

    init(name: String = "live") {
        self.name = name
    }

    func route(_ req: RouteRequest) async throws -> RouteResponse {
        routeRequests.append(req)
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
