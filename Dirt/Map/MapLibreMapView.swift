import MapLibre
import SwiftUI

/// MapLibre Native wrapper: Shortbread basemap (same style URL as the web POC),
/// dirt/paved route paint, A/B/stage markers, rider pins, and user tracking.
struct MapLibreMapView: UIViewRepresentable {
    let state: MapState
    let location: LocationService

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleURL: AppConfig.mapStyleURL)
        mapView.delegate = context.coordinator
        mapView.setCenter(AppConfig.overviewCenter, zoomLevel: AppConfig.overviewZoom, animated: false)
        mapView.logoView.isHidden = true
        mapView.attributionButtonPosition = .bottomLeft
        mapView.compassViewPosition = .topRight

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        for recognizer in mapView.gestureRecognizers ?? [] {
            if let existing = recognizer as? UITapGestureRecognizer {
                tap.require(toFail: existing)
            }
        }
        mapView.addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        mapView.addGestureRecognizer(longPress)

        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        mapView.showsUserLocation = location.isAuthorized
        context.coordinator.sync(mapView: mapView)
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        private let state: MapState
        private var styleLoaded = false
        private var appliedRouteGeneration = -1
        private var appliedMarkerGeneration = -1
        private var appliedCameraID: UUID?
        private var followApplied = false
        private var annotations: [DirtAnnotation] = []
        private weak var mapView: MLNMapView?

        init(state: MapState) {
            self.state = state
        }

        // MARK: Style / layers

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            self.mapView = mapView
            addRouteLayers(to: style)
            styleLoaded = true
            appliedRouteGeneration = -1
            sync(mapView: mapView)
        }

        private func addRouteLayers(to style: MLNStyle) {
            guard style.source(withIdentifier: "dirt-route-paved") == nil else { return }
            let pavedSource = MLNShapeSource(identifier: "dirt-route-paved", shape: nil, options: nil)
            let dirtSource = MLNShapeSource(identifier: "dirt-route-dirt", shape: nil, options: nil)
            style.addSource(pavedSource)
            style.addSource(dirtSource)

            func casing(_ id: String, source: MLNShapeSource) -> MLNLineStyleLayer {
                let layer = MLNLineStyleLayer(identifier: id, source: source)
                layer.lineColor = NSExpression(forConstantValue: UIColor.white)
                layer.lineWidth = NSExpression(forConstantValue: 8)
                layer.lineOpacity = NSExpression(forConstantValue: 0.85)
                layer.lineCap = NSExpression(forConstantValue: "round")
                layer.lineJoin = NSExpression(forConstantValue: "round")
                return layer
            }

            func line(_ id: String, source: MLNShapeSource, color: UIColor) -> MLNLineStyleLayer {
                let layer = MLNLineStyleLayer(identifier: id, source: source)
                layer.lineColor = NSExpression(forConstantValue: color)
                layer.lineWidth = NSExpression(forConstantValue: 5)
                layer.lineCap = NSExpression(forConstantValue: "round")
                layer.lineJoin = NSExpression(forConstantValue: "round")
                return layer
            }

            style.addLayer(casing("dirt-route-paved-casing", source: pavedSource))
            style.addLayer(casing("dirt-route-dirt-casing", source: dirtSource))
            style.addLayer(line("dirt-route-paved-line", source: pavedSource, color: UIColor(DirtTheme.pavedLine)))
            style.addLayer(line("dirt-route-dirt-line", source: dirtSource, color: UIColor(DirtTheme.orange)))
        }

        // MARK: Sync

        func sync(mapView: MLNMapView) {
            self.mapView = mapView
            syncFollow(mapView: mapView)
            syncCamera(mapView: mapView)
            syncMarkers(mapView: mapView)
            guard styleLoaded, let style = mapView.style else { return }
            syncRoute(style: style)
        }

        private func syncRoute(style: MLNStyle) {
            guard appliedRouteGeneration != state.routeGeneration else { return }
            appliedRouteGeneration = state.routeGeneration
            let dirt = polylines(for: state.routeSegments.filter(\.isDirt))
            let paved = polylines(for: state.routeSegments.filter { !$0.isDirt })
            (style.source(withIdentifier: "dirt-route-dirt") as? MLNShapeSource)?.shape = dirt
            (style.source(withIdentifier: "dirt-route-paved") as? MLNShapeSource)?.shape = paved
        }

        private func polylines(for segments: [RouteDisplaySegment]) -> MLNShapeCollectionFeature {
            let lines = segments.map { segment -> MLNPolylineFeature in
                var coordinates = segment.coordinates.map(\.locationCoordinate)
                return MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
            }
            return MLNShapeCollectionFeature(shapes: lines)
        }

        private func syncMarkers(mapView: MLNMapView) {
            guard appliedMarkerGeneration != state.markerGeneration else { return }
            appliedMarkerGeneration = state.markerGeneration
            mapView.removeAnnotations(annotations)
            annotations = state.markers.map { marker in
                let annotation = DirtAnnotation()
                annotation.coordinate = CLLocationCoordinate2D(latitude: marker.latitude, longitude: marker.longitude)
                annotation.markerID = marker.id
                annotation.label = marker.label
                annotation.kind = marker.kind
                annotation.title = marker.subtitle ?? marker.label
                return annotation
            }
            mapView.addAnnotations(annotations)
        }

        private func syncCamera(mapView: MLNMapView) {
            guard let camera = state.camera, camera.id != appliedCameraID else { return }
            appliedCameraID = camera.id
            switch camera.command {
            case let .center(latitude, longitude, zoom):
                mapView.setCenter(CLLocationCoordinate2D(latitude: latitude, longitude: longitude), zoomLevel: zoom, animated: true)
            case let .fit(coordinates):
                guard let first = coordinates.first else { return }
                var bounds = MLNCoordinateBounds(sw: first.locationCoordinate, ne: first.locationCoordinate)
                for coordinate in coordinates {
                    bounds.sw.latitude = min(bounds.sw.latitude, coordinate.latitude)
                    bounds.sw.longitude = min(bounds.sw.longitude, coordinate.longitude)
                    bounds.ne.latitude = max(bounds.ne.latitude, coordinate.latitude)
                    bounds.ne.longitude = max(bounds.ne.longitude, coordinate.longitude)
                }
                let insets = UIEdgeInsets(top: 90, left: 40, bottom: 280, right: 40)
                mapView.setVisibleCoordinateBounds(bounds, edgePadding: insets, animated: true, completionHandler: nil)
            }
        }

        private func syncFollow(mapView: MLNMapView) {
            if state.followUser != followApplied {
                followApplied = state.followUser
                mapView.userTrackingMode = state.followUser ? .followWithCourse : .none
            }
        }

        // MARK: Annotations

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            guard let dirtAnnotation = annotation as? DirtAnnotation else { return nil }
            let reuseID = "dirt-marker"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseID) as? DirtMarkerView
                ?? DirtMarkerView(reuseIdentifier: reuseID)
            view.configure(for: dirtAnnotation)
            return view
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            (annotation as? DirtAnnotation)?.kind == .rider
        }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            guard let dirtAnnotation = annotation as? DirtAnnotation, dirtAnnotation.kind == .rider else { return }
            state.onRiderTap?(dirtAnnotation.markerID)
        }

        // MARK: Gestures

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let mapView else { return }
            let coordinate = mapView.convert(gesture.location(in: mapView), toCoordinateFrom: mapView)
            state.onTap?(coordinate)
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let mapView else { return }
            let coordinate = mapView.convert(gesture.location(in: mapView), toCoordinateFrom: mapView)
            state.onLongPress?(coordinate)
        }
    }
}

final class DirtAnnotation: MLNPointAnnotation {
    var markerID = ""
    var label = ""
    var kind: MapState.MarkerKind = .start
}

final class DirtMarkerView: MLNAnnotationView {
    private let labelView = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        layer.cornerRadius = 14
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
        labelView.frame = bounds
        labelView.textAlignment = .center
        labelView.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        labelView.textColor = .white
        addSubview(labelView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(for annotation: DirtAnnotation) {
        labelView.text = annotation.label
        switch annotation.kind {
        case .start, .stage:
            backgroundColor = UIColor(DirtTheme.chrome)
        case .destination:
            backgroundColor = UIColor(DirtTheme.orange)
        case .rider:
            backgroundColor = UIColor(DirtTheme.navGreen)
        }
    }
}
