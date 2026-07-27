import Foundation
import Observation

/// Composition root: one instance per app, injected through the SwiftUI
/// environment.
@Observable
final class AppEnvironment {
    let location = LocationService()
    let routing = RoutingClient()
    let supabase = SupabaseService()
    let mapState = MapState()
    let offline = OfflineTileManager()
    let navigation = NavigationSession()
    let cueSettings = NavigationCueSettings()
    let subscription = SubscriptionService()
    let trial = TrialGateModel()
    let planner: RoutePlannerModel
    let groups: GroupsViewModel
    let incidents: IncidentRecoveryModel
    /// Loads Rider Services POIs from the Vercel CDN near the map viewport.
    let poiManager: POIManager
    /// Loads provincial road-network overlays (NS/NB/QC) near the viewport.
    let networkOverlayManager: NetworkOverlayManager

    private enum TesterKey {
        static let bypassAuth = "dirt_debug_bypass_auth_v1"
        static let bypassSubscription = "dirt_debug_bypass_subscription_v1"
    }

    /// Skip Sign in with Apple so map chrome can be tested while the Supabase
    /// Apple provider is unfinished. Persists across launches. Gated by
    /// `BuildChannel.showsTesterUnlock` (Debug always; Release while the
    /// pre-release flag is on).
    var debugBypassAuth: Bool {
        didSet { UserDefaults.standard.set(debugBypassAuth, forKey: TesterKey.bypassAuth) }
    }

    /// Treat the rider as subscribed so the delayed trial paywall never
    /// appears. Persists across launches. Does not fake a StoreKit receipt.
    var debugBypassSubscription: Bool {
        didSet {
            UserDefaults.standard.set(debugBypassSubscription, forKey: TesterKey.bypassSubscription)
            if debugBypassSubscription {
                trial.markSubscribed()
            }
        }
    }

    /// One-tap unlock used on the onboarding screen: map + no paywall.
    /// Groups / live sharing still need a real Apple → Supabase session.
    func unlockAsTester() {
        guard BuildChannel.showsTesterUnlock else { return }
        debugBypassAuth = true
        debugBypassSubscription = true
        trial.resetForTesting()
        trial.markSubscribed()
    }

    init() {
        // Only honor persisted unlocks while the channel still allows them —
        // flipping `allowPreReleaseTesterUnlock` to false clears the gate on
        // the next launch without a reinstall.
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
            offline: offline
        )
        groups = GroupsViewModel(supabase: supabase, location: location, mapState: mapState)
        incidents = IncidentRecoveryModel(planner: planner, locationService: location, routing: routing)
        poiManager             = POIManager(mapState: mapState)
        networkOverlayManager  = NetworkOverlayManager(mapState: mapState)

        navigation.cueMode = cueSettings.mode
        navigation.onCueAnnounced = { [cueSettings] text, meters in
            cueSettings.speakCueIfNeeded(text, distanceMeters: meters)
        }

        mapState.onTap = { [planner] coordinate in
            planner.handleMapTap(coordinate)
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
            guard let member = self.groups.member(forRiderMarkerID: markerID),
                  let lat = member.latitude,
                  let lon = member.longitude else { return }
            self.planner.routeToMember(
                name: member.displayName,
                latitude: lat,
                longitude: lon
            )
        }
        mapState.onPlannerPinDragEnd = { [planner] markerID, coordinate in
            planner.moveWaypoint(markerID: markerID, to: coordinate)
        }

        if debugBypassSubscription {
            trial.markSubscribed()
        }
    }

    func setCueMode(_ mode: NavigationCueMode) {
        cueSettings.mode = mode
        navigation.cueMode = mode
    }

    func setCueAudioEnabled(_ enabled: Bool) {
        cueSettings.audioEnabled = enabled
    }
}
