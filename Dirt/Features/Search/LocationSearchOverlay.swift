import MapKit
import SwiftUI

/// Extracted as a `ViewModifier` so RootView's body stays under the
/// Swift type-checker budget. Owns the search panel overlay, the
/// confirmation card, and the `onChange` hooks that fly the camera
/// and seed the region bias.
struct LocationSearchOverlay: ViewModifier {
    @Bindable var search: LocationSearchModel
    let app: AppEnvironment
    @Binding var activeSheet: ActiveSheet?
    @Binding var routeCardOpen: Bool

    init(
        search: LocationSearchModel,
        app: AppEnvironment,
        activeSheet: Binding<ActiveSheet?>,
        routeCardOpen: Binding<Bool>
    ) {
        self.search = search
        self.app = app
        _activeSheet = activeSheet
        _routeCardOpen = routeCardOpen
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                Group { searchPanel }
                    .animation(.spring(duration: 0.3, bounce: 0.1), value: search.isPresented)
            }
            .overlay(alignment: .top) {
                Group { confirmationCard }
                    .animation(.spring(duration: 0.32, bounce: 0.18), value: search.pendingResult?.id)
            }
            .ignoresSafeArea(.keyboard)
            .onChange(of: search.pendingResult?.id) { _, _ in
                flyToResult()
            }
            .onChange(of: search.isPresented) { _, presented in
                if presented { seedRegion() }
            }
    }

    // MARK: - Search panel

    @ViewBuilder
    private var searchPanel: some View {
        if search.isPresented {
            LocationSearchView(model: search)
                .zIndex(30)
                .transition(.identity)
        }
    }

    // MARK: - Confirmation card

    @ViewBuilder
    private var confirmationCard: some View {
        if let result = search.pendingResult {
            SearchConfirmationCard(
                result: result,
                onRoute: { routeToResult(result) },
                onWaypoint: { waypointResult(result) },
                onDismiss: { search.dismissPending() }
            )
            .padding(.top, 200)
            .zIndex(25)
            .transition(
                .offset(y: -8)
                    .combined(with: .opacity)
                    .animation(.spring(duration: 0.32, bounce: 0.18))
            )
        }
    }

    // MARK: - Actions

    private func routeToResult(_ result: LocationSearchService.Result) {
        withAnimation(DockSheetMotion.spring) {
            activeSheet = nil
            routeCardOpen = true
        }
        app.planner.routeToCoordinate(
            name: result.name,
            latitude: result.coordinate.latitude,
            longitude: result.coordinate.longitude
        )
        search.dismissPending()
    }

    private func waypointResult(_ result: LocationSearchService.Result) {
        app.planner.addPlanWaypoint(
            latitude: result.coordinate.latitude,
            longitude: result.coordinate.longitude
        )
        search.dismissPending()
    }

    private func flyToResult() {
        guard let result = search.pendingResult else { return }
        app.mapState.fly(
            to: RouteCoordinate(
                longitude: result.coordinate.longitude,
                latitude: result.coordinate.latitude
            ),
            zoom: 14
        )
    }

    private func seedRegion() {
        let center = app.mapState.mapCenter
        let span = MapState.spanForZoom(app.mapState.mapZoom)
        search.mapRegion = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
        )
        search.userCoordinate = app.location.lastLocation?.coordinate
    }
}
