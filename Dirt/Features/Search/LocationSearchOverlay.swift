import MapKit
import SwiftUI

struct LocationSearchOverlay: ViewModifier {
    @Bindable var model: LocationSearchModel
    let app: AppEnvironment
    @Binding var activeSheet: ActiveSheet?
    @Binding var routeCardOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    func body(content: Content) -> some View {
        content
            .allowsHitTesting(!model.isPresented && model.pendingResult == nil)
            .accessibilityHidden(model.isPresented || model.pendingResult != nil)
            .overlay {
                if model.isPresented {
                    GeometryReader { geometry in
                        ZStack(alignment: .top) {
                            Color.black.opacity(0.22).ignoresSafeArea()
                                .onTapGesture { model.isPresented = false }
                                .accessibilityHidden(true)
                            LocationSearchView(model: model)
                                .frame(maxWidth: 520)
                                .frame(height: min(470, max(160, geometry.size.height - topPadding - 12)))
                                .padding(.horizontal, 12)
                                .padding(.top, topPadding)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                if let result = model.pendingResult, !model.isPresented {
                    SearchConfirmationCard(result: result, onRoute: {
                        openPlanner()
                        app.planner.routeToCoordinate(name: result.name,
                            latitude: result.coordinate.latitude, longitude: result.coordinate.longitude)
                        model.pendingResult = nil
                    }, onWaypoint: {
                        openPlanner()
                        app.planner.addPlanWaypoint(latitude: result.coordinate.latitude,
                            longitude: result.coordinate.longitude)
                        model.pendingResult = nil
                    }, onDismiss: { model.pendingResult = nil })
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 12)
                    .padding(.top, topPadding)
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.isPresented)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.pendingResult?.id)
            .onChange(of: model.isPresented) { _, presented in
                guard presented else { return }
                model.pendingResult = nil
                if let bounds = app.mapState.visibleCoordinateBounds {
                    model.region = MKCoordinateRegion(
                        center: .init(latitude: (bounds.minLatitude + bounds.maxLatitude) / 2,
                                      longitude: (bounds.minLongitude + bounds.maxLongitude) / 2),
                        span: .init(latitudeDelta: max(0.01, bounds.latitudeSpan),
                                    longitudeDelta: max(0.01, bounds.longitudeSpan)))
                } else {
                    model.region = MKCoordinateRegion(center: app.mapState.mapCenter,
                        span: .init(latitudeDelta: 1, longitudeDelta: 1))
                }
            }
            .onChange(of: model.pendingResult?.id) { _, _ in
                guard let result = model.pendingResult else { return }
                app.mapState.fly(to: RouteCoordinate(longitude: result.coordinate.longitude,
                    latitude: result.coordinate.latitude), zoom: 14)
            }
            .onChange(of: app.navigation.phase) { _, phase in
                if phase != .idle {
                    model.isPresented = false
                    model.pendingResult = nil
                }
            }
    }

    private var topPadding: CGFloat { verticalSizeClass == .compact ? 12 : 76 }

    private func openPlanner() {
        activeSheet = nil
        app.planner.showingLoop = false
        routeCardOpen = true
    }
}
