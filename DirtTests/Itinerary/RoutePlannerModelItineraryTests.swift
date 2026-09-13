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
        FuelRangePrefs.automaticPlanningEnabled = false
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

    @Test func progressNotificationMatchesAutomaticFuelPlanningState() {
        let fuelOn = FuelRangePrefs.Snapshot(
            tankMeters: 260_000,
            usableMeters: 247_000,
            reservePercent: 5,
            automaticPlanningEnabled: true
        )
        let fuelOff = FuelRangePrefs.Snapshot(
            tankMeters: 260_000,
            usableMeters: 247_000,
            reservePercent: 5,
            automaticPlanningEnabled: false
        )

        #expect(RoutePlannerModel.initialBuildProgressToast(for: fuelOn)
            == RoutePlannerModel.calculatingFuelRangeToast)
        #expect(RoutePlannerModel.initialBuildProgressToast(for: fuelOff)
            == RoutePlannerModel.creatingRouteWithoutFuelToast)
        #expect(RoutePlannerModel.progressToastContent(
            for: RoutePlannerModel.creatingRouteWithoutFuelToast
        ) == RoutePlannerModel.ProgressToastContent(
            title: "Creating route",
            detail: "Fuel planning is off · Calculating distance"
        ))
    }

    @Test func progressNotificationNumbersEachFuelStop() {
        #expect(RoutePlannerModel.progressToastContent(for: "Creating fuel stop 1")
            == RoutePlannerModel.ProgressToastContent(
                title: "Creating fuel stop 1",
                detail: "Fuel stop required"
            ))
        #expect(RoutePlannerModel.progressToastContent(for: "Fuel stop 2 added")
            == RoutePlannerModel.ProgressToastContent(
                title: "Fuel stop 2 added",
                detail: "Continuing the route"
            ))
        #expect(RoutePlannerModel.isPersistentProgressToast("Checking range after fuel stop 2"))
    }

    @Test func loopSearchUsesPersistentAnimatedProgressContent() {
        for number in 1...6 {
            let message = "Finding loop \(number) of 6"
            #expect(RoutePlannerModel.isPersistentProgressToast(message))
            #expect(RoutePlannerModel.progressToastContent(for: message)?.title == message)
            #expect(RoutePlannerModel.progressToastContent(for: message)?.detail == "Comparing roads for your round trip")
        }
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

    @Test func planModeSelectsLiveWhileOnline() async {
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

        #expect(policyReports.contains { report in
            report.contains("packsCover=true")
                && report.contains("installed=[ns]")
                && report.contains("online=true")
                && report.contains("selected=live")
        })
        #expect(live.routeRequests.isEmpty == false)
        #expect(pack.routeRequests.isEmpty)
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
            .replaceAll(waypoints: [start, end], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
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

        #expect(model.stages.count == 3)
        #expect(model.stageEndpointTitle(at: 0) == "Point 1 → F1")
        #expect(model.stageEndpointTitle(at: 1) == "F1 → Point 2")
        #expect(model.stageEndpointTitle(at: 2) == "Point 2 → Point 3")
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

        #expect(model.stages.count == 2)
        #expect(model.stageEndpointTitle(at: 0) == "Point 1 → F1")
        #expect(model.stageEndpointTitle(at: 1) == "F1 → Point 2")
        #expect(model.stageFuelStationSubtitle(at: 0) == "Shell Antigonish")
        #expect(model.stages.allSatisfy { $0.profile == .dirt })

        model.focusStage(at: 0)
        #expect(mapState.routePolylineCoordinates.first == first)
        #expect(mapState.routePolylineCoordinates.last == pump)
        #expect(mapState.plannerMarkers.map(\.label) == ["1", "F1"])

        model.focusEntirePlannedRoute()
        #expect(mapState.routePolylineCoordinates.first == first)
        #expect(mapState.routePolylineCoordinates.last == second)
        #expect(mapState.plannerMarkers.count == 3)
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
        let model = makeModel(source: source)
        model.apply(
            .replaceAll(waypoints: [first, second], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
            source: "seed"
        )
        await model.waitForCanonicalBuildForTesting()

        #expect(model.stages.count == 3)
        #expect(model.stages.map(\.profile) == [.dirt, .dirt, .dirt])
        #expect(model.stageEndpointTitle(at: 0) == "Point 1 → F1")
        #expect(model.stageEndpointTitle(at: 1) == "F1 → F2")
        #expect(model.stageEndpointTitle(at: 2) == "F2 → Point 2")
    }

    @Test func firstFuelSectionProfileDoesNotEraseDownstreamSectionOverride() async throws {
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
        let model = makeModel(source: source)
        model.apply(
            .replaceAll(waypoints: [first, second], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
            source: "seed"
        )
        await model.waitForCanonicalBuildForTesting()

        model.setFuelHopProfile(.balanced, at: 1)
        await model.waitForCanonicalBuildForTesting()
        model.setFuelHopProfile(.dirt, at: 0)
        await model.waitForCanonicalBuildForTesting()

        let riderLeg = try #require(model.itinerary.legs.first)
        // Returning the first section to the rider-leg default removes its
        // redundant override, while the later section keeps its own profile.
        #expect(riderLeg.profile == .dirt)
        #expect(riderLeg.hopOverrides[riderLeg.from.uuidString] == nil)
        #expect(riderLeg.hopOverrides["irving"] == .balanced)
        #expect(model.stages.map(\.profile) == [.dirt, .balanced, .dirt])
    }

    @Test func cleanFuelHopInsideDirtRouteOwnsItsHighwayPolicyAndPropagatesItToRequests() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 220
        FuelRangePrefs.reservePercent = 5

        let first = point(0)
        let pump = point(0.25)
        let second = point(0.5)
        let source = PlannerFakeRoutingSource()
        source.distanceOverrides[key(first, second)] = 340_000
        source.distanceOverrides[key(first, pump)] = 170_000
        source.distanceOverrides[key(pump, second)] = 170_000
        source.fuelStops = [fuelStop("irving", name: "Irving", at: pump)]
        let model = makeModel(source: source)
        model.apply(
            .replaceAll(waypoints: [first, second], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
            source: "seed"
        )
        await model.waitForCanonicalBuildForTesting()
        #expect(model.stages.count == 2)

        source.routeRequests.removeAll()
        source.fuelChainRequests.removeAll()
        model.setFuelHopProfile(.cleanest, at: 1)
        await model.waitForCanonicalBuildForTesting()

        var riderLeg = try #require(model.itinerary.legs.first)
        #expect(riderLeg.profile == .dirt)
        #expect(riderLeg.hopOverrides["irving"] == .cleanest)
        #expect(riderLeg.hopAvoidMotorways["irving"] == nil)
        #expect(model.stages[0].profile == .dirt)
        #expect(!model.stages[0].avoidMotorways)
        #expect(model.stages[1].profile == .cleanest)
        #expect(model.stages[1].avoidMotorways)
        #expect(source.routeRequests.contains {
            $0.profile == .cleanest && $0.options?.avoidMotorways == true
        })
        #expect(source.fuelChainRequests.contains {
            $0.profile == .cleanest && $0.options?.avoidMotorways == true
        })

        source.routeRequests.removeAll()
        source.fuelChainRequests.removeAll()
        model.setStageAvoidMotorways(false, at: 1)
        await model.waitForCanonicalBuildForTesting()

        riderLeg = try #require(model.itinerary.legs.first)
        #expect(riderLeg.profile == .dirt)
        #expect(riderLeg.hopAvoidMotorways["irving"] == false)
        #expect(!model.stages[0].avoidMotorways)
        #expect(model.stages[1].profile == .cleanest)
        #expect(!model.stages[1].avoidMotorways)
        #expect(source.routeRequests.contains {
            $0.profile == .cleanest && $0.options?.avoidMotorways != true
        })
        #expect(source.fuelChainRequests.contains {
            $0.profile == .cleanest && $0.options?.avoidMotorways != true
        })

        source.routeRequests.removeAll()
        source.fuelChainRequests.removeAll()
        model.setStageAvoidMotorways(true, at: 1)
        await model.waitForCanonicalBuildForTesting()

        riderLeg = try #require(model.itinerary.legs.first)
        #expect(riderLeg.hopAvoidMotorways["irving"] == true)
        #expect(model.stages[1].profile == .cleanest)
        #expect(model.stages[1].avoidMotorways)
        #expect(source.routeRequests.contains {
            $0.profile == .cleanest && $0.options?.avoidMotorways == true
        })
        #expect(source.fuelChainRequests.contains {
            $0.profile == .cleanest && $0.options?.avoidMotorways == true
        })
    }

    @Test func allowUnknownSwitchUpdatesOnlyTheSelectedFuelStage() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 220
        FuelRangePrefs.reservePercent = 5
        FuelRangePrefs.automaticPlanningEnabled = true

        let start = point(0)
        let pump = point(0.25)
        let destination = point(0.5)
        let source = PlannerFakeRoutingSource()
        source.distanceOverrides[key(start, destination)] = 340_000
        source.distanceOverrides[key(start, pump)] = 170_000
        source.distanceOverrides[key(pump, destination)] = 170_000
        source.fuelStops = [fuelStop("irving", name: "Irving", at: pump)]
        let model = makeModel(source: source)
        model.apply(
            .replaceAll(
                waypoints: [start, destination],
                profile: .dirt,
                allowUnknown: false,
                avoidMotorways: false,
                preferBackRoads: false
            ),
            source: "seed"
        )
        await model.waitForCanonicalBuildForTesting()
        #expect(model.stages.count == 2)

        source.routeRequests.removeAll()
        source.fuelChainRequests.removeAll()
        model.setStageAllowUnknown(true, at: 0)
        await model.waitForCanonicalBuildForTesting()

        let riderLeg = try #require(model.itinerary.legs.first)
        let plans = source.fuelChainRequests.filter {
            $0.fuel.probeFirstReachableStation != true
        }
        #expect(!riderLeg.allowUnknown)
        #expect(riderLeg.hopAllowUnknown[riderLeg.from.uuidString] == true)
        #expect(model.stages.count == 2)
        #expect(model.stages[0].allowUnknown)
        #expect(!model.stages[1].allowUnknown)
        #expect(plans.first?.accessPolicy.motorizedUnknown == true)
        #expect(plans.last?.accessPolicy.motorizedUnknown == false)
    }

    @Test func tappingVisibleAlternativePumpReplacesTheFuelWaypoint() async throws {
        let prefs = FuelPrefsRestore()
        defer { prefs.restore() }
        FuelRangePrefs.kilometers = 250
        FuelRangePrefs.reservePercent = 5

        let first = point(0)
        let primary = point(0.25)
        let alternate = point(0.3)
        let second = point(0.5)
        let source = PlannerFakeRoutingSource()
        source.distanceOverrides[key(first, second)] = 300_000
        source.distanceOverrides[key(first, primary)] = 150_000
        source.distanceOverrides[key(primary, second)] = 150_000
        source.distanceOverrides[key(first, alternate)] = 155_000
        source.distanceOverrides[key(alternate, second)] = 145_000
        source.fuelStops = [fuelStop("primary", name: "Primary Pump", at: primary)]
        source.stationCandidates = [
            FuelStationCandidate(
                id: "alternate", meters: 155_000, dirtPct: 75,
                departureId: "start", latitude: alternate.latitude,
                longitude: alternate.longitude, name: "Alternate Pump", validForward: true
            )
        ]
        let mapState = MapState()
        let model = makeModel(source: source, mapState: mapState)
        model.apply(
            .replaceAll(waypoints: [first, second], profile: .dirt, allowUnknown: false, avoidMotorways: false, preferBackRoads: false),
            source: "seed"
        )
        await model.waitForCanonicalBuildForTesting()

        #expect(model.canReplaceFuelStop(at: 0))
        model.selectFuelWaypoint(at: 0)
        #expect(mapState.hasFuelReplacementCandidates)
        // Marker redraw reselects the active F pin. Replacement mode must stay
        // open rather than treating that callback as a dismissal tap.
        model.selectFuelWaypoint(at: 0)
        #expect(mapState.hasFuelReplacementCandidates)
        model.selectFuelTarget(markerID: "fuel-target:alternate")
        await model.waitForCanonicalBuildForTesting()

        #expect(!mapState.hasFuelReplacementCandidates)

        let riderLeg = try #require(model.itinerary.legs.first)
        #expect(riderLeg.fuelStopOverrides[riderLeg.from.uuidString] == "alternate")
        #expect(source.fuelChainRequests.contains {
            $0.fuel.requiredFirstStationId == "alternate"
        })
        #expect(model.built?.legs.first?.endsAtFuelStop?.stationID == "alternate")
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
        #expect(model.stages[0].fuelUnknown == "Fuel coverage on this leg could not be verified. Route kept—carry extra fuel or adjust this section.")
        #expect(model.stages[0].response != nil)
        #expect(model.errorMessage == nil)
        #expect(model.toast == "Route built. Fuel safety could not be verified for one or more legs.")
        #expect(model.hasRoute)
        let notice = try #require(model.fuelCoverageNotices.first)
        #expect(model.fuelCoverageNotices.count == 1)
        #expect(notice.kind == .unverified)
        #expect(notice.title == "Fuel coverage unverified")
        #expect(notice.scope == "Leg 1 · Point 1 → Point 2")
        #expect(notice.stageIndex == 0)
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
    let automatic = FuelRangePrefs.automaticPlanningEnabled

    func restore() {
        FuelRangePrefs.kilometers = kilometers
        FuelRangePrefs.reservePercent = reserve
        FuelRangePrefs.automaticPlanningEnabled = automatic
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
