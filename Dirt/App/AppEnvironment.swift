import CoreLocation
import Foundation
import Observation

/// Composition root: one instance per app, injected through the SwiftUI
/// environment.
@Observable
final class AppEnvironment {
    let location = LocationService()
    let supabase = SupabaseService()
    let mapState = MapState()
    let offline = OfflineTileManager()
    let shortbreadTiles = ShortbreadTileSourceManager()
    let graphPacks = GraphPackStore()
    let network = NetworkPathMonitor()
    let routing = RoutingClient()
    let navigation = NavigationSession()
    let cueSettings = NavigationCueSettings()
    let subscription = SubscriptionService()
    let trial = TrialGateModel()
    let planner: RoutePlannerModel
    let groups: GroupsViewModel
    let incidents: IncidentRecoveryModel
    let rideIntelligence: RideIntelligenceService
    /// Rider Services: fuel from the installed pack; other POIs from Overpass.
    let poiManager: POIManager
    /// Provincial road overlay from the installed graph pack.
    let networkOverlayManager: NetworkOverlayManager
    /// DEBUG-only viewport diagnostic. Release DIRT-logo uses the corridor overlay.
    let routingGraphDebug: RoutingGraphDebugManager
    /// Retired BC OSM mbtiles experiment (no-op; kept to avoid a pbxproj delete).
    let bcOSMHierarchy: BCOSMHierarchyOverlay

    /// Pending opt-in contribute sheet after End navigation.
    var pendingTrackContribution: RideContributionCandidate?

    private enum TesterKey {
        static let bypassAuth = "dirt_debug_bypass_auth_v1"
        static let bypassSubscription = "dirt_debug_bypass_subscription_v1"
    }

    /// Skip Sign in with Apple for pre-release map testing. Persists across launches.
    var debugBypassAuth: Bool {
        didSet { UserDefaults.standard.set(debugBypassAuth, forKey: TesterKey.bypassAuth) }
    }

    /// Treat the rider as subscribed so Export / Start gates never fire.
    var debugBypassSubscription: Bool {
        didSet {
            UserDefaults.standard.set(debugBypassSubscription, forKey: TesterKey.bypassSubscription)
            syncTrialEntitlement()
        }
    }

    /// One-tap unlock used on the onboarding screen: map + no paywall.
    func unlockAsTester() {
        guard BuildChannel.showsTesterUnlock else { return }
        debugBypassAuth = true
        debugBypassSubscription = true
        trial.resetForTesting()
        trial.markSubscribed()
    }

    func syncTrialEntitlement() {
        let entitled = subscription.isSubscribed
            || (BuildChannel.showsTesterUnlock && debugBypassSubscription)
        if entitled {
            trial.markSubscribed()
        } else {
            trial.isSubscribed = false
        }
    }

    /// Resolve Dirt's tile release once per launch. The map starts on public
    /// Shortbread, so manifest or edge failures never block launch or routing.
    func bootstrapShortbreadTileDelivery() async {
        let source = await shortbreadTiles.resolve()
        offline.useTileSource(source)
        mapState.useTileSource(source, reloadStyle: !offline.isEngaged)
    }

    init() {
        let storedAuth = UserDefaults.standard.bool(forKey: TesterKey.bypassAuth)
        let storedSub = UserDefaults.standard.bool(forKey: TesterKey.bypassSubscription)
        if BuildChannel.showsTesterUnlock {
            debugBypassAuth = storedAuth
            debugBypassSubscription = storedSub
        } else {
            debugBypassAuth = false
            debugBypassSubscription = false
            UserDefaults.standard.removeObject(forKey: TesterKey.bypassAuth)
            UserDefaults.standard.removeObject(forKey: TesterKey.bypassSubscription)
        }
        UserDefaults.standard.removeObject(forKey: "dirt.routing.useLive")

        planner = RoutePlannerModel(
            routing: routing,
            locationService: location,
            mapState: mapState,
            navigation: navigation,
            offline: offline,
            graphPacks: graphPacks,
            network: network,
            poiManager: nil
        )
        graphPacks.onPackRemoved = { [planner] regionID in
            planner.notePackRemoved(regionID)
        }
        groups = GroupsViewModel(supabase: supabase, location: location, mapState: mapState)
        rideIntelligence = RideIntelligenceService(supabase: supabase)
        incidents = IncidentRecoveryModel(
            planner: planner,
            locationService: location,
            network: network,
            groups: groups,
            rideIntelligence: rideIntelligence,
            graphPackVersion: { [graphPacks] in graphPacks.lastManifestVersion }
        )
        groups.onToast = { [planner] message in
            planner.toast = message
        }
        groups.onPeerLocationUpdate = { [planner] target in
            planner.receiveGroupMemberUpdate(target)
        }
        groups.onPeerSharingEnded = { [planner] userID, displayName in
            planner.receiveGroupMemberSharingEnded(userID: userID, displayName: displayName)
        }
        poiManager             = POIManager(
            mapState: mapState,
            graphPacks: graphPacks,
            network: network
        )
        networkOverlayManager  = NetworkOverlayManager(mapState: mapState, graphPacks: graphPacks)
        routingGraphDebug      = RoutingGraphDebugManager(
            mapState: mapState,
            graphPacks: graphPacks,
            network: network
        )
        bcOSMHierarchy         = BCOSMHierarchyOverlay(mapState: mapState)
        // Network Lens and BC OSM experiment are gone. Clear leftover prefs so
        // an old install cannot retain an overlay the rider can no longer control.
        for region in ["ns", "nb", "qc", "on", "bc", "ab"] {
            UserDefaults.standard.removeObject(forKey: "dirt.layers.network.\(region)")
        }
        UserDefaults.standard.removeObject(forKey: BCOSMHierarchyOverlay.prefsKey)
        mapState.bumpLayerPrefs()
        bcOSMHierarchy.applyPrefs()
        planner.attachPOIManager(poiManager)
        offline.mapState = mapState

        navigation.cueMode = cueSettings.mode
        navigation.onCueAnnounced = { [cueSettings] text, announceKey in
            cueSettings.speakCueIfNeeded(text, announceKey: announceKey)
        }
        navigation.onCueValidityChanged = { [cueSettings] identities in
            cueSettings.retainUpcomingCues(identities)
        }
        planner.onNavigationEnded = { [weak self] candidate in
            self?.cueSettings.stopSpeaking()
            self?.incidents.dismiss()
            Task { @MainActor in
                guard let self else { return }
                await self.rideIntelligence.flushPendingIncidents()
                guard let candidate else { return }
                // Prompt when preference on, or first time with a meaningful ride.
                if TrackContributePrefs.isEnabled || !TrackContributePrefs.hasBeenAsked {
                    self.pendingTrackContribution = candidate
                }
            }
        }

        mapState.onTap = { [planner] coordinate in
            planner.handleMapTap(coordinate)
        }
        mapState.onRouteTap = { [planner] riderLegID, coordinate, source in
            planner.handleRouteTap(coordinate, riderLegID: riderLegID, source: source)
        }
        mapState.onLongPress = { [planner] coordinate in
            planner.handleMapLongPress(coordinate)
        }
        mapState.onPOITap = { [weak self] poi in
            // Surface to RootView for the routing action sheet.
            self?.mapState.selectedPOI = poi
        }
        mapState.onRiderTap = { [weak self] markerID in
            guard let self else { return }
            if markerID.hasPrefix("alert:") {
                let alertID = String(markerID.dropFirst("alert:".count))
                if let alert = self.groups.peerAlerts.first(where: { $0.id == alertID }) {
                    self.groups.focusPeerAlert(alert)
                    return
                }
            }
            // Details first — never drop a From here pin here.
            self.groups.selectPeer(fromRiderMarkerID: markerID)
        }
        mapState.onPlannerPinSnapFailed = { [planner] in
            planner.showsWaypointPlacementConfirmation = false
            planner.toast = "Move the waypoint closer to a road, then try again"
            planner.refreshMap()
        }
        mapState.onPlannerPinDragEnd = { [planner] markerID, coordinate in
            planner.moveWaypoint(markerID: markerID, to: coordinate)
        }
        mapState.onPlannerPinDragBegan = { [planner] markerID in
            planner.beginPlannerPinDrag(markerID: markerID)
        }

        // Frame the map on the rider as soon as GPS (or a cached fix) arrives.
        let priorLocationHandler = location.onLocation
        location.onLocation = { [mapState, graphPacks, groups] locationFix in
            priorLocationHandler?(locationFix)
            groups.receiveLocationFix(locationFix)
            mapState.consumeInitialUserLocation(locationFix.coordinate)
            Task {
                await graphPacks.warmupActivePack(near: locationFix.coordinate)
            }
        }
        if let seed = location.lastLocation?.coordinate {
            mapState.consumeInitialUserLocation(seed)
            Task {
                await graphPacks.warmupActivePack(near: seed)
            }
        }

        if debugBypassSubscription {
            syncTrialEntitlement()
        }

#if DEBUG
        // Focused UI-test state for navigation-only chrome. This never ships in
        // release builds and avoids creating routes, downloads, or simulators.
        if ProcessInfo.processInfo.environment["DIRT_UI_TEST_CUES"] == "1" {
            navigation.activate(
                coordinates: [
                    RouteCoordinate(longitude: -63.60, latitude: 44.65),
                    RouteCoordinate(longitude: -63.58, latitude: 44.66)
                ],
                maneuvers: [
                    RouteManeuver(
                        instruction: "Turn right",
                        type: "turn",
                        stableID: "ui-test-junction",
                        kind: "junction",
                        side: "right",
                        distanceMeters: 0,
                        alongMeters: 700
                    )
                ]
            )
        }
        // Stable visual fixture for the route-progress notice. It exercises
        // the shipping view without starting routing or changing rider data.
        if ProcessInfo.processInfo.environment["DIRT_UI_TEST_ROUTE_PROGRESS"] == "craft" {
            planner.installRouteProgressFixtureForTesting(
                RoutePlannerModel.craftingRouteToast
            )
        }
        if ProcessInfo.processInfo.environment["DIRT_UI_TEST_FERRY"] == "1" {
            planner.installFerryPresentationFixtureForTesting()
        }
#endif
    }

    func setCueMode(_ mode: NavigationCueMode) {
        cueSettings.mode = mode
        navigation.cueMode = mode
        navigation.rebuildCuesForCurrentMode()
        if let location = location.lastLocation {
            navigation.update(with: location)
        }
    }

    func setCueAudioEnabled(_ enabled: Bool) {
        cueSettings.audioEnabled = enabled
    }
}
