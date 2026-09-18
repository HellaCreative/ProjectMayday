import Foundation
import CoreLocation
import Testing
@testable import Dirt

@MainActor
@Suite(.serialized)
struct GroupRouteToMemberTests {
    @Test func offlineMemberNeverArmsARoute() {
        let model = makeGroupPlanner()
        let stale = memberTarget(
            userID: "alex",
            name: "Alex",
            isLive: false,
            lastSeenAt: Date().addingTimeInterval(-30)
        )
        model.routeToMember(stale)
        #expect(model.destination == nil)
        #expect(model.pendingGroupMemberUserIDForTesting == nil)
        #expect(model.toast == "That rider's location is no longer current.")
    }

    @Test func staleLiveWindowNeverArmsARoute() {
        let model = makeGroupPlanner()
        let stale = memberTarget(
            userID: "alex",
            name: "Alex",
            isLive: true,
            lastSeenAt: Date().addingTimeInterval(-121)
        )
        model.routeToMember(stale)
        #expect(model.destination == nil)
        #expect(model.pendingGroupMemberUserIDForTesting == nil)
        #expect(model.toast == "That rider's location is no longer current.")
    }

    @Test func freshMemberArmsFromHereTracking() {
        let model = makeGroupPlanner()
        let alex = memberTarget(userID: "alex", name: "Alex")
        model.routeToMember(alex)
        #expect(model.destination == alex.coordinate)
        #expect(model.destinationName == "Alex")
        #expect(model.mode == .fromHere)
        #expect(model.pendingGroupMemberUserIDForTesting == "alex")
        #expect(model.toast == RoutePlannerModel.calculatingRouteToast)
    }

    @Test func navigatingToADifferentRiderWaitsForConfirmAndReplace() {
        let model = makeGroupPlanner()
        let alex = memberTarget(userID: "alex", name: "Alex")
        let sam = memberTarget(
            userID: "sam",
            name: "Sam",
            latitude: 44.66,
            longitude: -63.58
        )
        model.routeToMember(alex)
        #expect(model.navigation.beginPrefetch())

        model.routeToMember(sam)
        #expect(model.pendingMemberRouteReplacement?.userID == "sam")
        #expect(model.destinationName == "Alex")
        #expect(model.pendingGroupMemberUserIDForTesting == "alex")

        model.confirmReplaceMemberRoute()
        #expect(model.pendingMemberRouteReplacement == nil)
        #expect(model.navigation.phase == .idle)
        #expect(model.destinationName == "Sam")
        #expect(model.pendingGroupMemberUserIDForTesting == "sam")
    }

    @Test func sameRiderWhileNavigatingDoesNotReplace() {
        let model = makeGroupPlanner()
        let alex = memberTarget(userID: "alex", name: "Alex")
        model.routeToMember(alex)
        #expect(model.navigation.beginPrefetch())
        model.routeToMember(alex)
        #expect(model.pendingMemberRouteReplacement == nil)
        #expect(model.destinationName == "Alex")
        #expect(model.toast == "Already routing to Alex.")
    }

    @Test func sharingEndedKeepsLastKnownAndStopsFreshRebuilds() {
        let model = makeGroupPlanner()
        let alex = memberTarget(userID: "alex", name: "Alex")
        model.installActiveGroupTrackingForTesting(alex)
        model.receiveGroupMemberSharingEnded(userID: alex.userID, displayName: alex.displayName)
        #expect(model.activeGroupMemberUserIDForTesting == "alex")
        #expect(model.groupNavigationNotice?.kind == .lastKnown)
        #expect(model.groupNavigationNotice?.title == "Alex stopped sharing")

        let lastKnown = GroupMemberRouteTarget(
            groupID: alex.groupID,
            userID: alex.userID,
            displayName: alex.displayName,
            coordinate: alex.coordinate,
            lastSeenAt: alex.lastSeenAt,
            accuracyMeters: alex.accuracyMeters,
            isLive: false
        )
        #expect(!StopTriggeredTrackingPolicy.targetIsFresh(lastKnown))
    }
}

@MainActor
private func makeGroupPlanner() -> RoutePlannerModel {
    let coverage = GroupPlannerPackCoverage()
    return RoutePlannerModel(
        routing: RoutingClient(),
        locationService: LocationService(),
        mapState: MapState(),
        navigation: NavigationSession(),
        offline: OfflineTileManager(),
        graphPacks: GraphPackStore(),
        network: NetworkPathMonitor(),
        routingSourcePolicy: .fixed(GroupPlannerFakeSource()),
        itineraryBuilder: ItineraryBuilder(),
        packAcquisition: PackAcquisitionCoordinator(inspect: coverage, installer: coverage)
    )
}

private func memberTarget(
    userID: String,
    name: String,
    isLive: Bool = true,
    lastSeenAt: Date = Date(),
    latitude: Double = 44.65,
    longitude: Double = -63.57
) -> GroupMemberRouteTarget {
    GroupMemberRouteTarget(
        groupID: "trail",
        userID: userID,
        displayName: name,
        coordinate: RouteCoordinate(longitude: longitude, latitude: latitude),
        lastSeenAt: lastSeenAt,
        accuracyMeters: 12,
        isLive: isLive
    )
}

@MainActor
private final class GroupPlannerFakeSource: RoutingSource {
    let name = "group-test"

    func route(_ req: RouteRequest) async throws -> RouteResponse {
        let start = RouteCoordinate(
            longitude: req.locations[0].longitude,
            latitude: req.locations[0].latitude
        )
        let end = RouteCoordinate(
            longitude: req.locations.last?.longitude ?? req.locations[0].longitude,
            latitude: req.locations.last?.latitude ?? req.locations[0].latitude
        )
        return RouteResponse(
            status: "complete", error: nil, message: nil,
            distanceMeters: 1_000,
            estimatedMovingSeconds: nil, estimatedElapsedSeconds: nil,
            geometry: [start, end], segments: nil,
            stats: RouteStats(dirtPercent: 80, pavedPercent: 20),
            maneuvers: nil, warnings: nil,
            dirtPercentValue: nil, pavedPercentValue: nil
        )
    }

    func fuelChain(_ req: FuelChainRequest) async throws -> FuelChainResponse {
        FuelChainResponse(
            status: "complete", error: nil, message: nil, regionIds: ["test"],
            stops: [], graphMeters: nil,
            diagnostics: FuelChainDiagnostics(
                strategy: "fake", states: 1, dijkstraPops: 1,
                matchedFuel: 0, elapsedMs: 1
            )
        )
    }

    func fuelStation(near point: RouteCoordinate, within meters: Double) async throws -> FuelChainStop? {
        nil
    }
}

@MainActor
private final class GroupPlannerPackCoverage: PackCoverageInspecting, PackInstalling {
    let routingManifestVersion = "test-group"

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
