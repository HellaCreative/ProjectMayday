import MapLibre
import SwiftUI

/// Navigation PiP: mini full-route overview with live rider mark.
/// The whole tile is tappable — swaps main map detail ↔ overview (no badge CTA).
struct NavigationPipView: View {
    @Environment(AppEnvironment.self) private var app

    private var showingOverviewOnMain: Bool {
        app.mapState.navigationCameraMode == .overview
    }

    var body: some View {
        Button {
            app.mapState.toggleNavigationCameraMode(routeCoordinates: app.navigation.coordinates)
        } label: {
            NavigationPipMapRepresentable(
                styleURL: app.mapState.styleURL,
                coordinates: app.navigation.coordinates,
                /// When main is in overview, PiP shows a tight follow hint; otherwise full route.
                showDetailFollow: showingOverviewOnMain,
                riderCoordinate: app.location.currentCoordinate?.locationCoordinate
            )
            .frame(width: 118, height: 148)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(DirtTheme.chromeBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            showingOverviewOnMain
                ? "Switch to navigation detail view"
                : "Switch to full route overview"
        )
    }
}

private struct NavigationPipMapRepresentable: UIViewRepresentable {
    let styleURL: URL
    let coordinates: [RouteCoordinate]
    /// When true, PiP shows a tight follow-style framing hint (main is overview).
    let showDetailFollow: Bool
    let riderCoordinate: CLLocationCoordinate2D?

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: styleURL)
        map.automaticallyAdjustsContentInset = true
        map.logoView.isHidden = true
        map.attributionButton.isHidden = true
        map.compassView.isHidden = true
        map.isUserInteractionEnabled = false
        map.delegate = context.coordinator
        context.coordinator.mapView = map
        return map
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        if mapView.styleURL != styleURL {
            mapView.styleURL = styleURL
        }
        context.coordinator.pendingCoordinates = coordinates
        context.coordinator.pendingDetail = showDetailFollow
        context.coordinator.pendingRider = riderCoordinate
        context.coordinator.syncRoute()
        context.coordinator.syncRider()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        weak var mapView: MLNMapView?
        var pendingCoordinates: [RouteCoordinate] = []
        var pendingDetail = false
        var pendingRider: CLLocationCoordinate2D?
        private var appliedRouteSignature = ""
        private var appliedRiderSignature = ""
        private var riderAnnotation: MLNPointAnnotation?

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            ensureRouteLayers(on: style)
            appliedRouteSignature = ""
            appliedRiderSignature = ""
            // Style load is async — re-apply pending route so we never leave world-view.
            syncRoute()
            syncRider()
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard annotation === riderAnnotation else { return nil }
            let reuseID = "dirt-pip-rider"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseID)
                ?? MLNAnnotationView(reuseIdentifier: reuseID)
            view.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
            view.backgroundColor = UIColor(DirtTheme.dirtMix)
            view.layer.cornerRadius = 6
            view.layer.borderWidth = 2
            view.layer.borderColor = UIColor.white.cgColor
            view.scalesWithViewingDistance = false
            return view
        }

        private func ensureRouteLayers(on style: MLNStyle) {
            guard style.source(withIdentifier: "dirt-pip-route") == nil else { return }
            let source = MLNShapeSource(identifier: "dirt-pip-route", shape: nil, options: nil)
            style.addSource(source)
            let casing = MLNLineStyleLayer(identifier: "dirt-pip-route-casing", source: source)
            casing.lineColor = NSExpression(forConstantValue: UIColor.white)
            casing.lineWidth = NSExpression(forConstantValue: 5)
            casing.lineOpacity = NSExpression(forConstantValue: 0.9)
            style.addLayer(casing)
            let line = MLNLineStyleLayer(identifier: "dirt-pip-route-line", source: source)
            line.lineColor = NSExpression(forConstantValue: UIColor(DirtTheme.orange))
            line.lineWidth = NSExpression(forConstantValue: 3)
            style.addLayer(line)
        }

        func syncRoute() {
            guard let mapView, let style = mapView.style else { return }
            ensureRouteLayers(on: style)
            guard let source = style.source(withIdentifier: "dirt-pip-route") as? MLNShapeSource else { return }

            let coordinates = pendingCoordinates
            let detail = pendingDetail
            let signature = "\(coordinates.count)-\(detail)-\(coordinates.first?.latitude ?? 0)-\(coordinates.last?.longitude ?? 0)"
            guard signature != appliedRouteSignature else { return }
            appliedRouteSignature = signature

            guard coordinates.count > 1 else {
                source.shape = nil
                return
            }
            var coords = coordinates.map(\.locationCoordinate)
            let polyline = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
            source.shape = polyline

            if detail, let last = coordinates.last {
                mapView.setCenter(last.locationCoordinate, zoomLevel: 14, animated: false)
            } else {
                // Default PiP: frame the entire planned route.
                var bounds = MLNCoordinateBounds(
                    sw: coordinates[0].locationCoordinate,
                    ne: coordinates[0].locationCoordinate
                )
                for coordinate in coordinates {
                    bounds.sw.latitude = min(bounds.sw.latitude, coordinate.latitude)
                    bounds.sw.longitude = min(bounds.sw.longitude, coordinate.longitude)
                    bounds.ne.latitude = max(bounds.ne.latitude, coordinate.latitude)
                    bounds.ne.longitude = max(bounds.ne.longitude, coordinate.longitude)
                }
                if let rider = pendingRider {
                    bounds.sw.latitude = min(bounds.sw.latitude, rider.latitude)
                    bounds.sw.longitude = min(bounds.sw.longitude, rider.longitude)
                    bounds.ne.latitude = max(bounds.ne.latitude, rider.latitude)
                    bounds.ne.longitude = max(bounds.ne.longitude, rider.longitude)
                }
                let pad = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
                mapView.setVisibleCoordinateBounds(bounds, edgePadding: pad, animated: false, completionHandler: nil)
            }
        }

        func syncRider() {
            guard let mapView else { return }
            guard let rider = pendingRider else {
                if let existing = riderAnnotation {
                    mapView.removeAnnotation(existing)
                    riderAnnotation = nil
                    appliedRiderSignature = ""
                }
                return
            }
            let signature = String(format: "%.5f,%.5f", rider.latitude, rider.longitude)
            if let existing = riderAnnotation {
                if signature != appliedRiderSignature {
                    existing.coordinate = rider
                    appliedRiderSignature = signature
                }
            } else {
                let annotation = MLNPointAnnotation()
                annotation.coordinate = rider
                riderAnnotation = annotation
                appliedRiderSignature = signature
                mapView.addAnnotation(annotation)
            }
        }
    }
}
