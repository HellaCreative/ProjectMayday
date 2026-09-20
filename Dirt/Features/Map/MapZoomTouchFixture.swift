#if DEBUG
import SwiftUI
import CoreLocation

/// Exercises the real glass buttons over the real map recognizers without
/// starting routes/downloads. Map touches leave a marker so pass-through is visible.
struct MapZoomTouchFixture: View {
    @Environment(AppEnvironment.self) private var app
    @State private var mapTouches = 0
    @State private var zoomActions = 0
    @State private var standalone = false
    @State private var pinDrags = 0
    @State private var placementTaps = 0
    private var testsPlacement: Bool {
        ProcessInfo.processInfo.environment["DIRT_UI_TEST_PIN_PLACEMENT"] == "1"
    }

    var body: some View {
        ZStack {
            MapLibreMapView(state: app.mapState, location: app.location)
                .ignoresSafeArea()
            VStack {
                VStack {
                    Text("Map touches: \(mapTouches)").accessibilityIdentifier("map-touch-count")
                    Text("Zoom actions: \(zoomActions)").accessibilityIdentifier("zoom-action-count")
                    if testsPlacement {
                        Text("Pin drags: \(pinDrags)").accessibilityIdentifier("pin-drag-count")
                        Text("Placement taps: \(placementTaps)").accessibilityIdentifier("placement-tap-count")
                    }
                    Button(standalone ? "Show map stack" : "Show standalone zoom") { standalone.toggle() }
                }
                .padding().background(.regularMaterial)
                Spacer()
                HStack {
                    Spacer()
                    if standalone {
                        MapZoomControls(axis: .vertical)
                    } else {
                        MapControlStack()
                    }
                }
                .padding(24)
            }
        }
        .onAppear {
            app.mapState.onTap = recordMapTouch
            app.mapState.onLongPress = recordMapTouch
            if testsPlacement {
                app.mapState.onPlannerPinDragEnd = { id, coordinate in
                    pinDrags += 1
                    app.mapState.setPlannerMarkers([.init(id: id, latitude: coordinate.latitude,
                        longitude: coordinate.longitude, label: "+", kind: .stage)])
                    app.mapState.selectPlannerPin(id)
                }
                app.mapState.onPlannerPinPlacementTap = { id, _ in
                    placementTaps += 1
                    // Confirmation/No redraws the same draft in the planner.
                    let markers = app.mapState.plannerMarkers
                    app.mapState.setPlannerMarkers(markers)
                    app.mapState.selectPlannerPin(id)
                }
            }
        }
        .onChange(of: app.mapState.camera?.id) { _, _ in
            if let command = app.mapState.camera?.command, case .zoom = command {
                zoomActions += 1
            }
        }
    }

    private func recordMapTouch(_ coordinate: CLLocationCoordinate2D) {
        mapTouches += 1
        app.mapState.setPlannerMarkers([.init(id: testsPlacement ? "waypoint-draft" : "fixture-pin", latitude: coordinate.latitude,
            longitude: coordinate.longitude, label: testsPlacement ? "+" : "1", kind: .destination)])
        if testsPlacement { app.mapState.selectPlannerPin("waypoint-draft") }
    }
}
#endif
