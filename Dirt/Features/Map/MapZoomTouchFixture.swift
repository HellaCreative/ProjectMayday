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

    var body: some View {
        ZStack {
            MapLibreMapView(state: app.mapState, location: app.location)
                .ignoresSafeArea()
            VStack {
                VStack {
                    Text("Map touches: \(mapTouches)").accessibilityIdentifier("map-touch-count")
                    Text("Zoom actions: \(zoomActions)").accessibilityIdentifier("zoom-action-count")
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
        }
        .onChange(of: app.mapState.camera?.id) { _, _ in
            if let command = app.mapState.camera?.command, case .zoom = command {
                zoomActions += 1
            }
        }
    }

    private func recordMapTouch(_ coordinate: CLLocationCoordinate2D) {
        mapTouches += 1
        app.mapState.setPlannerMarkers([.init(id: "fixture-pin", latitude: coordinate.latitude,
            longitude: coordinate.longitude, label: "1", kind: .destination)])
    }
}
#endif
