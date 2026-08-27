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
    /// Temporary viewport diagnostic: live graph first, installed pack offline.
    let routingGraphDebug: RoutingGraphDebugManager
    /// Feasibility: local BC.mbtiles OSM hierarchy (visual only).
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

    /// Treat the rider as subscribed so Save / Export / Start gates never fire.
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
        // Network Lens was removed from Layers. Clear every legacy preference
        // so an old installation cannot retain an overlay it can no longer control.
        for region in ["ns", "nb", "qc", "on", "bc", "ab"] {
            UserDefaults.standard.set(false, forKey: "dirt.layers.network.\(region)")
        }
        UserDefaults.standard.set(false, forKey: BCOSMHierarchyOverlay.prefsKey)
        mapState.bumpLayerPrefs()
        bcOSMHierarchy.applyPrefs()
        planner.attachPOIManager(poiManager)
        offline.mapState = mapState

        navigation.cueMode = cueSettings.mode
        navigation.onCueAnnounced = { [cueSettings] text, announceKey in
            Task { @MainActor in
                cueSettings.speakCueIfNeeded(text, announceKey: announceKey)
            }
        }
        planner.onNavigationEnded = { [weak self] candidate in
            Task { @MainActor in
                guard let self else { return }
                self.cueSettings.stopSpeaking()
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
        mapState.onPlannerPinDragEnd = { [planner] markerID, coordinate in
            planner.moveWaypoint(markerID: markerID, to: coordinate)
        }
        mapState.onPlannerPinDragBegan = { [planner] markerID in
            planner.beginPlannerPinDrag(markerID: markerID)
        }

        // Frame the map on the rider as soon as GPS (or a cached fix) arrives.
        let priorLocationHandler = location.onLocation
        location.onLocation = { [mapState, graphPacks] locationFix in
            priorLocationHandler?(locationFix)
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
