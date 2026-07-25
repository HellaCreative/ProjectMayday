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
    let planner: RoutePlannerModel
    let groups: GroupsViewModel

    init() {
        planner = RoutePlannerModel(
            routing: routing,
            locationService: location,
            mapState: mapState,
            navigation: navigation,
            offline: offline
        )
        groups = GroupsViewModel(supabase: supabase, location: location, mapState: mapState)

        mapState.onTap = { [planner] coordinate in
            planner.handleMapTap(coordinate)
        }
        mapState.onLongPress = { [planner] coordinate in
            planner.handleMapLongPress(coordinate)
        }
    }
}
