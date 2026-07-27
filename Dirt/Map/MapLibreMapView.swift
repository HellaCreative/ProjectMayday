import MapLibre
import QuartzCore
import SwiftUI

/// MapLibre Native wrapper: swappable basemap (OSM Shortbread or Mapbox classic
/// raster styles), per-surface route paint (web `route-network` colours),
/// A/B/stage markers, rider pins, and user tracking.
struct MapLibreMapView: UIViewRepresentable {
    let state: MapState
    let location: LocationService

    /// Paint buckets matching live web `route-network` line-color match.
    enum RoutePaintBucket: String, CaseIterable {
        case access
        case gravel
        case track
        case paved
        case connector

        var sourceID: String { "dirt-route-\(rawValue)" }
        var casingID: String { "\(sourceID)-casing" }
        var lineID: String { "\(sourceID)-line" }

        var color: Color {
            switch self {
            case .access: DirtTheme.routeAccess
            case .gravel: DirtTheme.routeGravel
            case .track: DirtTheme.routeTrack
            case .paved: DirtTheme.routePaved
            case .connector: DirtTheme.routeConnector
            }
        }

        static func bucket(for surfaceKey: String) -> RoutePaintBucket {
            switch surfaceKey.lowercased() {
            case "access", "resource":
                return .access
            case "gravel", "unknown", "unpaved", "dirt":
                return .gravel
            case "track", "double_track":
                return .track
            case "connector":
                return .connector
            case "paved":
                return .paved
            default:
                return .paved
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleURL: state.styleURL)
        mapView.delegate = context.coordinator
        mapView.automaticallyAdjustsContentInset = true
        mapView.setCenter(AppConfig.overviewCenter, zoomLevel: AppConfig.overviewZoom, animated: false)
        mapView.logoView.isHidden = true
        mapView.attributionButtonPosition = .bottomLeft
        // Custom compass lives in MapControlStack (web parity).
        mapView.compassView.isHidden = true
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

    /// Per-category POI circle layer IDs and display colors.
    enum POILayer {
        static let categories: [(id: String, color: UIColor)] = [
            ("fuel",       UIColor(red: 0.910, green: 0.451, blue: 0.047, alpha: 1)),
            ("campground", UIColor(red: 0.184, green: 0.620, blue: 0.267, alpha: 1)),
            ("lodging",    UIColor(red: 0.541, green: 0.353, blue: 0.169, alpha: 1)),
            ("liquor",     UIColor(red: 0.557, green: 0.267, blue: 0.788, alpha: 1))
        ]

        static func layerID(_ category: String) -> String { "dirt-poi-\(category)" }
        static func symbolID(_ category: String) -> String { "dirt-poi-\(category)-icon" }
        static func iconName(_ category: String) -> String { "dirt-poi-icon-\(category)" }
        /// Dots visible from regional overview for plan-route scanning.
        static let dotMinZoom = 6.5
        /// Glyphs only when close enough to read.
        static let iconMinZoom = 11.0
        static var allLayerIDs: [String] {
            categories.flatMap { [layerID($0.id), symbolID($0.id)] }
        }

        static func systemSymbolName(for category: String) -> String {
            switch category {
            case "fuel": return "fuelpump.fill"
            case "campground": return "tent.fill"
            case "lodging": return "bed.double.fill"
            case "liquor": return "wineglass.fill"
            default: return "mappin"
            }
        }

        static func makeIcon(category: String, color _: UIColor) -> UIImage? {
            let size = CGSize(width: 22, height: 22)
            let config = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            let symbolName = systemSymbolName(for: category)
            let symbol = UIImage(systemName: symbolName, withConfiguration: config)
                ?? UIImage(systemName: "mappin", withConfiguration: config)
            guard let symbol = symbol?.withTintColor(.white, renderingMode: .alwaysOriginal) else { return nil }
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { _ in
                let origin = CGPoint(
                    x: (size.width - symbol.size.width) / 2,
                    y: (size.height - symbol.size.height) / 2
                )
                symbol.draw(at: origin)
            }
        }
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        private let state: MapState
        private var styleLoaded = false
        private var appliedStyleGeneration = -1
        private var appliedRouteGeneration = -1
        private var appliedMarkerGeneration = -1
        private var appliedPinSelectionGeneration = -1
        private var appliedCameraID: UUID?
        private var followApplied: MapState.FollowMode?
        private var followGenerationApplied = -1
        private var annotations: [DirtAnnotation] = []
        private weak var mapView: MLNMapView?
        /// Ignore follow-break while we programmatically ease the camera.
        private var suppressFollowBreakUntil: Date?

        // Overlay generation trackers (separate for POI vs network, data vs prefs)
        private var appliedPoiData    = -1
        private var appliedPoiPrefs   = -1
        private var appliedNetData    = -1
        private var appliedNetPrefs   = -1

        init(state: MapState) {
            self.state = state
        }

        // MARK: Style / layers

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            self.mapView = mapView
            // Layer insertion order: network overlays (below) → route → POI (above)
            addNetworkLayers(to: style)
            addRouteLayers(to: style)
            addPOILayers(to: style)
            styleLoaded = true
            appliedRouteGeneration = -1
            // Force overlay re-sync after a style reload
            appliedPoiData = -1; appliedPoiPrefs = -1
            appliedNetData = -1; appliedNetPrefs = -1
            sync(mapView: mapView)
        }

        // MARK: - Network overlay layers

        private func addNetworkLayers(to style: MLNStyle) {
            guard style.source(withIdentifier: "dirt-network") == nil else { return }
            let src = MLNShapeSource(identifier: "dirt-network", shape: nil, options: nil)
            style.addSource(src)

            // access (blue) — exclude restricted
            let access = MLNLineStyleLayer(identifier: "dirt-net-access", source: src)
            access.predicate = NSPredicate(format: "surfaceClass == 'access' AND accessClass != 'motorized_restricted'")
            access.lineColor = NSExpression(forConstantValue: UIColor(red: 0.039, green: 0.400, blue: 0.761, alpha: 1))
            access.lineWidth = NSExpression(forConstantValue: 2)
            access.lineOpacity = NSExpression(forConstantValue: 0.88)
            style.addLayer(access)

            // gravel (gray)
            let gravel = MLNLineStyleLayer(identifier: "dirt-net-gravel", source: src)
            gravel.predicate = NSPredicate(format: "surfaceClass == 'gravel' AND accessClass != 'motorized_restricted'")
            gravel.lineColor = NSExpression(forConstantValue: UIColor(red: 0.365, green: 0.408, blue: 0.455, alpha: 1))
            gravel.lineWidth = NSExpression(forConstantValue: 2)
            gravel.lineOpacity = NSExpression(forConstantValue: 0.88)
            style.addLayer(gravel)

            // branches/track (purple)
            let track = MLNLineStyleLayer(identifier: "dirt-net-track", source: src)
            track.predicate = NSPredicate(format: "surfaceClass == 'track' AND accessClass != 'motorized_restricted'")
            track.lineColor = NSExpression(forConstantValue: UIColor(red: 0.486, green: 0.227, blue: 0.929, alpha: 1))
            track.lineWidth = NSExpression(forConstantValue: 2)
            track.lineOpacity = NSExpression(forConstantValue: 0.88)
            style.addLayer(track)

            // restricted (red, dashed)
            let restricted = MLNLineStyleLayer(identifier: "dirt-net-restricted", source: src)
            restricted.predicate = NSPredicate(format: "accessClass == 'motorized_restricted'")
            restricted.lineColor = NSExpression(forConstantValue: UIColor(red: 0.824, green: 0.153, blue: 0.188, alpha: 1))
            restricted.lineWidth = NSExpression(forConstantValue: 2)
            restricted.lineOpacity = NSExpression(forConstantValue: 0.85)
            restricted.lineDashPattern = NSExpression(forConstantValue: [1.2, 1.4] as [NSNumber])
            style.addLayer(restricted)

            // bridge (teal)
            let bridge = MLNLineStyleLayer(identifier: "dirt-net-bridge", source: src)
            bridge.predicate = NSPredicate(format: "structureType == 'bridge'")
            bridge.lineColor = NSExpression(forConstantValue: UIColor(red: 0.086, green: 0.529, blue: 0.373, alpha: 1))
            bridge.lineWidth = NSExpression(forConstantValue: 2.5)
            bridge.lineOpacity = NSExpression(forConstantValue: 0.92)
            style.addLayer(bridge)

            // tunnel (brown, dashed)
            let tunnel = MLNLineStyleLayer(identifier: "dirt-net-tunnel", source: src)
            tunnel.predicate = NSPredicate(format: "structureType == 'tunnel'")
            tunnel.lineColor = NSExpression(forConstantValue: UIColor(red: 0.576, green: 0.341, blue: 0.169, alpha: 1))
            tunnel.lineWidth = NSExpression(forConstantValue: 2.5)
            tunnel.lineOpacity = NSExpression(forConstantValue: 0.92)
            tunnel.lineDashPattern = NSExpression(forConstantValue: [0.8, 0.8] as [NSNumber])
            style.addLayer(tunnel)
            // Network surface classes always paint when features are loaded —
            // Map visibility toggles were removed; corridor/lens control load.
        }

        // MARK: - POI layers (drawn above route layers)

        private func addPOILayers(to style: MLNStyle) {
            guard style.source(withIdentifier: "dirt-poi") == nil else { return }
            let src = MLNShapeSource(identifier: "dirt-poi", shape: nil, options: nil)
            style.addSource(src)
            registerPOIIcons(in: style)
            for (cat, color) in POILayer.categories {
                // Soft colored disc — small dots when zoomed out for planning,
                // larger when close enough to read icons.
                let circle = MLNCircleStyleLayer(identifier: POILayer.layerID(cat), source: src)
                circle.predicate = NSPredicate(format: "category == %@", cat)
                circle.circleColor = NSExpression(forConstantValue: color)
                circle.circleRadius = NSExpression(mglJSONObject: [
                    "interpolate", ["linear"], ["zoom"],
                    6.5, 3.5,
                    8.5, 5.5,
                    11.0, 9.0,
                    13.0, 11.0
                ] as [Any])
                circle.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
                circle.circleStrokeWidth = NSExpression(mglJSONObject: [
                    "interpolate", ["linear"], ["zoom"],
                    6.5, 1.0,
                    11.0, 2.0
                ] as [Any])
                circle.minimumZoomLevel = Float(POILayer.dotMinZoom)
                style.addLayer(circle)

                // Category glyph only once zoomed in enough to read it.
                let symbol = MLNSymbolStyleLayer(identifier: POILayer.symbolID(cat), source: src)
                symbol.predicate = NSPredicate(format: "category == %@", cat)
                symbol.iconImageName = NSExpression(forConstantValue: POILayer.iconName(cat))
                symbol.iconAllowsOverlap = NSExpression(forConstantValue: true)
                symbol.iconIgnoresPlacement = NSExpression(forConstantValue: true)
                symbol.iconAnchor = NSExpression(forConstantValue: "center")
                symbol.minimumZoomLevel = Float(POILayer.iconMinZoom)
                style.addLayer(symbol)
            }
            applyPOILayerVisibility(to: style)
        }

        private func registerPOIIcons(in style: MLNStyle) {
            for (cat, color) in POILayer.categories {
                let name = POILayer.iconName(cat)
                guard style.image(forName: name) == nil,
                      let image = POILayer.makeIcon(category: cat, color: color) else { continue }
                style.setImage(image, forName: name)
            }
        }

        // MARK: - Route layers

        private func addRouteLayers(to style: MLNStyle) {
            guard style.source(withIdentifier: RoutePaintBucket.access.sourceID) == nil else { return }

            for bucket in RoutePaintBucket.allCases {
                let source = MLNShapeSource(identifier: bucket.sourceID, shape: nil, options: nil)
                style.addSource(source)

                let casing = MLNLineStyleLayer(identifier: bucket.casingID, source: source)
                casing.lineColor = NSExpression(forConstantValue: UIColor.white)
                casing.lineWidth = NSExpression(forConstantValue: 9)
                casing.lineOpacity = NSExpression(forConstantValue: 0.85)
                casing.lineCap = NSExpression(forConstantValue: "round")
                casing.lineJoin = NSExpression(forConstantValue: "round")

                let line = MLNLineStyleLayer(identifier: bucket.lineID, source: source)
                line.lineColor = NSExpression(forConstantValue: UIColor(bucket.color))
                line.lineWidth = NSExpression(forConstantValue: 7)
                line.lineOpacity = NSExpression(forConstantValue: 0.98)
                line.lineCap = NSExpression(forConstantValue: "round")
                line.lineJoin = NSExpression(forConstantValue: "round")

                style.addLayer(casing)
                style.addLayer(line)
            }
        }

        // MARK: Sync

        func sync(mapView: MLNMapView) {
            self.mapView = mapView
            syncStyle(mapView: mapView)
            // Explicit camera (fit / fly) before follow — otherwise the follow
            // zoom-lock can immediately undo a Zoom-to-Route after recenter.
            syncCamera(mapView: mapView)
            syncFollow(mapView: mapView)
            syncMarkers(mapView: mapView)
            syncPinSelection(mapView: mapView)
            guard styleLoaded, let style = mapView.style else { return }
            syncRoute(style: style)
            syncPOI(style: style)
            syncNetwork(style: style)
        }

        // MARK: - POI sync

        private func syncPOI(style: MLNStyle) {
            let dataChanged  = appliedPoiData  != state.poiDataGeneration
            let prefsChanged = appliedPoiPrefs != state.layerPrefsGeneration
            guard dataChanged || prefsChanged else { return }
            appliedPoiData  = state.poiDataGeneration
            appliedPoiPrefs = state.layerPrefsGeneration

            if dataChanged {
                let shapes = state.poiFeatures.map { poi -> MLNPointFeature in
                    let f = MLNPointFeature()
                    f.coordinate = CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude)
                    f.attributes = [
                        "category": poi.category,
                        "poi_id":   poi.id,
                        "name":     poi.name         ?? "",
                        "address":  poi.address       ?? "",
                        "brand":    poi.brand         ?? "",
                        "phone":    poi.phone         ?? "",
                        "website":  poi.website       ?? ""
                    ]
                    return f
                }
                (style.source(withIdentifier: "dirt-poi") as? MLNShapeSource)?.shape =
                    MLNShapeCollectionFeature(shapes: shapes)
            }

            if prefsChanged {
                applyPOILayerVisibility(to: style)
            }
        }

        private func applyPOILayerVisibility(to style: MLNStyle) {
            let prefs = LayerPrefsSnapshot()
            for (cat, _) in POILayer.categories {
                let visible = prefs.isPOIEnabled(category: cat)
                style.layer(withIdentifier: POILayer.layerID(cat))?.isVisible = visible
                style.layer(withIdentifier: POILayer.symbolID(cat))?.isVisible = visible
            }
        }

        // MARK: - Network overlay sync

        private func syncNetwork(style: MLNStyle) {
            let dataChanged  = appliedNetData  != state.networkDataGeneration
            let prefsChanged = appliedNetPrefs != state.layerPrefsGeneration
            guard dataChanged || prefsChanged else { return }
            appliedNetData  = state.networkDataGeneration
            appliedNetPrefs = state.layerPrefsGeneration

            if dataChanged {
                let lines = state.networkFeatures.compactMap { feature -> MLNPolylineFeature? in
                    guard feature.coordinates.count >= 2 else { return nil }
                    var coords = feature.coordinates.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                    }
                    let line = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
                    line.attributes = [
                        "edgeId":        feature.edgeId,
                        "surfaceClass":  feature.surfaceClass,
                        "accessClass":   feature.accessClass,
                        "structureType": feature.structureType,
                        "province":      feature.province
                    ]
                    return line
                }
                (style.source(withIdentifier: "dirt-network") as? MLNShapeSource)?.shape =
                    MLNShapeCollectionFeature(shapes: lines)
            }
            // Layer visibility is always on; province/corridor gating is in NetworkOverlayManager.
        }

        private func syncStyle(mapView: MLNMapView) {
            guard appliedStyleGeneration != state.styleGeneration else { return }
            appliedStyleGeneration = state.styleGeneration
            styleLoaded = false
            appliedRouteGeneration = -1
            mapView.styleURL = state.styleURL
        }

        private func syncRoute(style: MLNStyle) {
            guard appliedRouteGeneration != state.routeGeneration else { return }
            appliedRouteGeneration = state.routeGeneration
            for bucket in RoutePaintBucket.allCases {
                let segments = state.routeSegments.filter { RoutePaintBucket.bucket(for: $0.surfaceKey) == bucket }
                (style.source(withIdentifier: bucket.sourceID) as? MLNShapeSource)?.shape = polylines(for: segments)
            }
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
                annotation.status = marker.status
                annotation.title = marker.subtitle ?? marker.label
                return annotation
            }
            mapView.addAnnotations(annotations)
            // Force selection chrome to re-apply after annotation rebuild.
            appliedPinSelectionGeneration = -1
            syncPinSelection(mapView: mapView)
        }

        private func syncPinSelection(mapView: MLNMapView) {
            guard appliedPinSelectionGeneration != state.pinSelectionGeneration else { return }
            appliedPinSelectionGeneration = state.pinSelectionGeneration
            let selectedID = state.selectedPlannerPinID
            for annotation in annotations {
                guard annotation.kind != .rider,
                      let view = mapView.view(for: annotation) as? DirtPlannerPinView else { continue }
                view.applySelectionChrome(annotation.markerID == selectedID, animated: true)
            }
            // Keep MapLibre selection in sync for drag-to-move.
            if let selectedID,
               let annotation = annotations.first(where: { $0.markerID == selectedID }) {
                mapView.selectAnnotation(annotation, animated: false, completionHandler: nil)
            }
        }

        private func syncCamera(mapView: MLNMapView) {
            guard let camera = state.camera, camera.id != appliedCameraID else { return }
            appliedCameraID = camera.id
            // Overview / fly commands must not be treated as a follow-break gesture,
            // and must clear native tracking so MapLibre doesn't re-center mid-fit.
            suppressFollowBreak(for: 1.2)
            if case .fit = camera.command {
                mapView.userTrackingMode = .none
            }
            switch camera.command {
            case let .center(latitude, longitude, zoom):
                // If follow is engaging on this same sync turn, skip the animated
                // setCenter — syncFollow will move the camera once.
                if state.followMode != .off {
                    applyPitch(on: mapView, animated: false)
                    break
                }
                mapView.setCenter(
                    CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    zoomLevel: zoom,
                    direction: mapView.direction,
                    animated: true
                )
                applyPitch(on: mapView, animated: false)
            case let .fit(coordinates):
                guard let first = coordinates.first else { return }
                var bounds = MLNCoordinateBounds(sw: first.locationCoordinate, ne: first.locationCoordinate)
                for coordinate in coordinates {
                    bounds.sw.latitude = min(bounds.sw.latitude, coordinate.latitude)
                    bounds.sw.longitude = min(bounds.sw.longitude, coordinate.longitude)
                    bounds.ne.latitude = max(bounds.ne.latitude, coordinate.latitude)
                    bounds.ne.longitude = max(bounds.ne.longitude, coordinate.longitude)
                }
                let insets = UIEdgeInsets(top: 100, left: 48, bottom: 320, right: 48)
                mapView.setVisibleCoordinateBounds(bounds, edgePadding: insets, animated: true, completionHandler: nil)
                applyPitch(on: mapView, animated: false)
            case .applyViewMode:
                applyPitch(on: mapView, animated: true)
            case .resetNorth:
                let camera = mapView.camera
                camera.heading = 0
                camera.pitch = state.desiredPitch
                mapView.setCamera(camera, withDuration: 0.5, animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
                state.mapBearing = 0
            }
        }

        private func applyPitch(on mapView: MLNMapView, animated: Bool) {
            let pitch = state.desiredPitch
            guard abs(mapView.camera.pitch - pitch) > 0.5 else { return }
            let camera = mapView.camera
            camera.pitch = pitch
            if animated {
                // Pitch-only duration is fine when the center isn't also moving.
                mapView.setCamera(camera, withDuration: 0.35, animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
            } else {
                // Instant — animated setCamera reuses the *current* center and will
                // cancel an in-flight setCenter/fit (recenter hitch).
                mapView.camera = camera
            }
        }

        private func syncFollow(mapView: MLNMapView) {
            let needsReapply = followApplied != state.followMode
                || followGenerationApplied != state.followGeneration
            guard needsReapply else {
                // Keep detail zoom locked while following so dual-sport cues stay readable.
                if state.followMode != .off,
                   state.navigationCameraMode == .detail,
                   abs(mapView.zoomLevel - state.followZoom) > 0.35 {
                    suppressFollowBreak(for: 1.2)
                    mapView.setZoomLevel(state.followZoom, animated: false)
                }
                return
            }
            followApplied = state.followMode
            followGenerationApplied = state.followGeneration
            suppressFollowBreak(for: 1.5)
            switch state.followMode {
            case .off:
                mapView.userTrackingMode = .none
            case .northUp:
                // Zoom first (instant), then one tracking animation to the user.
                mapView.setZoomLevel(state.followZoom, animated: false)
                mapView.setUserTrackingMode(.follow, animated: true, completionHandler: nil)
            case .courseUp:
                mapView.setZoomLevel(state.followZoom, animated: false)
                mapView.setUserTrackingMode(.followWithCourse, animated: true, completionHandler: nil)
            }
            applyPitch(on: mapView, animated: false)
        }

        private func suppressFollowBreak(for seconds: TimeInterval) {
            suppressFollowBreakUntil = Date().addingTimeInterval(seconds)
        }

        // MARK: Camera / gestures

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            let bearing = mapView.direction
            if abs(bearing - state.mapBearing) > 0.4 {
                state.mapBearing = bearing
            }
            // Update viewport so POIManager / NetworkOverlayManager observe the change.
            state.mapCenter = mapView.camera.centerCoordinate
            state.mapZoom   = mapView.zoomLevel
        }

        func mapView(
            _ mapView: MLNMapView,
            regionWillChangeWith reason: MLNCameraChangeReason,
            animated: Bool
        ) {
            if let until = suppressFollowBreakUntil, Date() < until { return }
            let gestureBits: MLNCameraChangeReason = [
                .gesturePan,
                .gesturePinch,
                .gestureRotate,
                .gestureZoomIn,
                .gestureZoomOut,
                .gestureTilt,
                .gestureOneFingerZoom
            ]
            if !reason.isDisjoint(with: gestureBits) {
                state.breakFollowFromGesture()
            }
        }

        // MARK: Annotations

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            if annotation is MLNUserLocation {
                // Course arrow while navigating; default blue dot otherwise.
                guard state.isNavigating else { return nil }
                let reuseID = "dirt-course-puck"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseID) as? DirtCoursePuckView
                    ?? DirtCoursePuckView(reuseIdentifier: reuseID)
                return view
            }
            guard let dirtAnnotation = annotation as? DirtAnnotation else { return nil }
            if dirtAnnotation.kind == .rider {
                let reuseID = "dirt-rider-marker"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseID) as? DirtRiderMarkerView
                    ?? DirtRiderMarkerView(reuseIdentifier: reuseID)
                view.configure(for: dirtAnnotation)
                return view
            }
            let reuseID = "dirt-planner-pin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseID) as? DirtPlannerPinView
                ?? DirtPlannerPinView(reuseIdentifier: reuseID)
            view.configure(for: dirtAnnotation)
            view.applySelectionChrome(dirtAnnotation.markerID == state.selectedPlannerPinID, animated: false)
            // Custom pan drag (tap-select then drag). MapLibre's built-in drag
            // requires a long-press, which feels like the map is stealing the gesture.
            view.isDraggable = false
            view.hostMapView = mapView
            if state.isNavigating {
                view.onDragBegan = nil
                view.onDragEnded = nil
            } else {
                view.onDragBegan = { [weak self] markerID in
                    self?.state.selectPlannerPin(markerID)
                }
                view.onDragEnded = { [weak self] markerID, coordinate in
                    self?.state.onPlannerPinDragEnd?(markerID, coordinate)
                }
            }
            return view
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            // Rider tap routes immediately; name is already on the pin.
            false
        }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            guard let dirtAnnotation = annotation as? DirtAnnotation else { return }
            if dirtAnnotation.kind == .rider {
                state.onRiderTap?(dirtAnnotation.markerID)
                mapView.deselectAnnotation(annotation, animated: false)
                return
            }
            guard !state.isNavigating else { return }
            // Tap pin → select (orange lift) so drag / second-tap relocate is obvious.
            state.selectPlannerPin(dirtAnnotation.markerID)
        }

        func mapView(_ mapView: MLNMapView, didDeselect annotation: MLNAnnotation) {
            guard let dirtAnnotation = annotation as? DirtAnnotation,
                  dirtAnnotation.kind != .rider,
                  state.selectedPlannerPinID == dirtAnnotation.markerID else { return }
            // Keep selection until the rider picks another pin, moves it, or clears.
            // MapLibre deselects on map pan; restore selection chrome via generation.
            appliedPinSelectionGeneration = -1
        }

        func mapView(
            _ mapView: MLNMapView,
            didChange annotation: MLNAnnotation,
            from oldState: MLNAnnotationViewDragState,
            to newState: MLNAnnotationViewDragState
        ) {
            guard !state.isNavigating,
                  let dirtAnnotation = annotation as? DirtAnnotation,
                  dirtAnnotation.kind != .rider else { return }
            if newState == .starting || newState == .dragging {
                state.selectPlannerPin(dirtAnnotation.markerID)
            }
            guard newState == .ending else { return }
            state.onPlannerPinDragEnd?(dirtAnnotation.markerID, annotation.coordinate)
            // Keep selection so the rider can nudge again; chrome stays on.
        }

        // MARK: Gestures

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let mapView else { return }
            let pt = gesture.location(in: mapView)

            // Planner pin wins over map tap — select / don't drop a new waypoint.
            if let pin = plannerAnnotation(at: pt, in: mapView) {
                mapView.selectAnnotation(pin, animated: true, completionHandler: nil)
                state.selectPlannerPin(pin.markerID)
                return
            }

            // Selected pin + tap map → relocate (discoverable when route fails).
            if let selectedID = state.selectedPlannerPinID, !state.isNavigating {
                let coordinate = mapView.convert(pt, toCoordinateFrom: mapView)
                state.onPlannerPinDragEnd?(selectedID, coordinate)
                return
            }

            // POI wins over pin-drop: generous hit box so a near-miss still
            // opens the POI sheet instead of placing a From-here destination.
            if let poi = poiFeature(at: pt, in: mapView, hitRadius: 32) {
                state.onPOITap?(poi)
                return
            }

            let coordinate = mapView.convert(pt, toCoordinateFrom: mapView)
            state.onTap?(coordinate)
        }

        private func plannerAnnotation(at point: CGPoint, in mapView: MLNMapView) -> DirtAnnotation? {
            let hitRadius: CGFloat = 28
            var best: DirtAnnotation?
            var bestDist = CGFloat.greatestFiniteMagnitude
            for annotation in annotations where annotation.kind != .rider {
                let pinPoint = mapView.convert(annotation.coordinate, toPointTo: mapView)
                // Account for teardrop centerOffset (tip at coordinate, body above).
                let bodyCenter = CGPoint(x: pinPoint.x, y: pinPoint.y - DirtPlannerPinView.pinHeight / 2)
                let dx = bodyCenter.x - point.x
                let dy = bodyCenter.y - point.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist <= hitRadius && dist < bestDist {
                    bestDist = dist
                    best = annotation
                }
            }
            return best
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let mapView else { return }
            let pt = gesture.location(in: mapView)
            // Same rule for plan waypoints: don't place on top of a POI.
            if let poi = poiFeature(at: pt, in: mapView, hitRadius: 32) {
                state.onPOITap?(poi)
                return
            }
            let coordinate = mapView.convert(pt, toCoordinateFrom: mapView)
            state.onLongPress?(coordinate)
        }

        private func poiFeature(at point: CGPoint, in mapView: MLNMapView, hitRadius: CGFloat) -> POIFeature? {
            let box = CGRect(
                x: point.x - hitRadius,
                y: point.y - hitRadius,
                width: hitRadius * 2,
                height: hitRadius * 2
            )
            let poiLayerIDs = Set(POILayer.allLayerIDs)
            let poiHits = mapView.visibleFeatures(in: box, styleLayerIdentifiers: poiLayerIDs)
            guard let hit = poiHits.first as? MLNPointFeature else { return nil }
            let attrs = hit.attributes
            return POIFeature(
                id:           (attrs["poi_id"]  as? String) ?? "",
                category:     (attrs["category"] as? String) ?? "",
                latitude:     hit.coordinate.latitude,
                longitude:    hit.coordinate.longitude,
                name:         (attrs["name"]    as? String).flatMap { $0.isEmpty ? nil : $0 },
                address:      (attrs["address"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                brand:        (attrs["brand"]   as? String).flatMap { $0.isEmpty ? nil : $0 },
                openingHours: nil,
                phone:        (attrs["phone"]   as? String).flatMap { $0.isEmpty ? nil : $0 },
                website:      (attrs["website"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }
}

final class DirtAnnotation: MLNPointAnnotation {
    var markerID = ""
    var label = ""
    var kind: MapState.MarkerKind = .start
    var status: String?
}

/// HTML-parity teardrop stage pin: dark body + orange circle + white number,
/// bottom-anchored so the pin tip sits on the map coordinate.
final class DirtPlannerPinView: MLNAnnotationView {
    static let pinWidth: CGFloat = 36
    static let pinHeight: CGFloat = 44

    private let bodyLayer = CAShapeLayer()
    private let circleLayer = CAShapeLayer()
    private let labelView = UILabel()
    private var isCustomDragging = false
    private var savedMapScrollEnabled = true
    private var savedMapRotateEnabled = true

    weak var hostMapView: MLNMapView?
    var onDragBegan: ((String) -> Void)?
    var onDragEnded: ((String, CLLocationCoordinate2D) -> Void)?

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: Self.pinWidth, height: Self.pinHeight)
        // Shift the view up so its bottom tip aligns with the map coordinate.
        centerOffset = CGVector(dx: 0, dy: -(Self.pinHeight / 2))
        scalesWithViewingDistance = false
        clipsToBounds = false
        isDraggable = false
        isEnabled = true
        isUserInteractionEnabled = true

        // Shadow on the container layer
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.38
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 2)

        // Teardrop body — translates the HTML SVG path 1:1 (viewBox 0 0 36 44).
        bodyLayer.path = tearDropPath().cgPath
        bodyLayer.lineWidth = 1
        layer.addSublayer(bodyLayer)

        // Orange circle: cx=18 cy=17 r=9.5 → CGRect(x:8.5, y:7.5, w:19, h:19)
        circleLayer.path = UIBezierPath(
            ovalIn: CGRect(x: 8.5, y: 7.5, width: 19, height: 19)
        ).cgPath
        layer.addSublayer(circleLayer)

        // Number/letter label centred in the circle (top:10 left:8 w:20 h:14)
        labelView.frame = CGRect(x: 8, y: 10, width: 20, height: 14)
        labelView.textAlignment = .center
        labelView.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        labelView.textColor = .white
        labelView.adjustsFontSizeToFitWidth = true
        labelView.minimumScaleFactor = 0.7
        addSubview(labelView)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePinPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(for annotation: DirtAnnotation) {
        labelView.text = annotation.label
        // All planner pins: dark #111820 body + orange circle (HTML parity).
        bodyLayer.fillColor = UIColor(red: 17/255, green: 24/255, blue: 32/255, alpha: 1).cgColor
        bodyLayer.strokeColor = UIColor(DirtTheme.orange).cgColor
        circleLayer.fillColor = UIColor(DirtTheme.orange).cgColor
    }

    /// Selected = lifted + thicker orange rim so "ready to move" is obvious.
    func applySelectionChrome(_ selected: Bool, animated: Bool) {
        let changes = {
            self.transform = selected
                ? CGAffineTransform(scaleX: 1.18, y: 1.18)
                : .identity
            self.bodyLayer.lineWidth = selected ? 2.5 : 1
            self.bodyLayer.strokeColor = UIColor(DirtTheme.orange).cgColor
            self.layer.shadowOpacity = selected ? 0.55 : 0.38
            self.layer.shadowRadius = selected ? 6 : 3
            self.circleLayer.lineWidth = selected ? 2 : 0
            self.circleLayer.strokeColor = selected ? UIColor.white.cgColor : UIColor.clear.cgColor
        }
        if animated {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut], animations: changes)
        } else {
            changes()
        }
    }

    /// Larger tap/drag target than the 36×44 artboard.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -14, dy: -14).contains(point)
    }

    /// While dragging, reject MapLibre’s re-project-from-coordinate resets
    /// that would snap the pin back to its pre-drag location on every redraw.
    override var center: CGPoint {
        get { super.center }
        set {
            if isCustomDragging,
               let mapView = hostMapView,
               let annotation = annotation {
                let projected = mapView.convert(annotation.coordinate, toPointTo: mapView)
                let expected = CGPoint(
                    x: projected.x + centerOffset.dx,
                    y: projected.y + centerOffset.dy
                )
                if abs(newValue.x - expected.x) < 0.75, abs(newValue.y - expected.y) < 0.75 {
                    return
                }
            }
            super.center = newValue
        }
    }

    @objc private func handlePinPan(_ gesture: UIPanGestureRecognizer) {
        guard let mapView = hostMapView,
              let dirtAnnotation = annotation as? DirtAnnotation else { return }

        switch gesture.state {
        case .began:
            guard hostMapView != nil else { return }
            // Don't drag while navigating — coordinator also sets callbacks only in idle.
            isCustomDragging = true
            savedMapScrollEnabled = mapView.isScrollEnabled
            savedMapRotateEnabled = mapView.isRotateEnabled
            mapView.isScrollEnabled = false
            mapView.isRotateEnabled = false
            onDragBegan?(dirtAnnotation.markerID)
            applySelectionChrome(true, animated: true)
            movePin(with: gesture, on: mapView, annotation: dirtAnnotation)

        case .changed:
            guard isCustomDragging else { return }
            movePin(with: gesture, on: mapView, annotation: dirtAnnotation)

        case .ended, .cancelled, .failed:
            guard isCustomDragging else { return }
            movePin(with: gesture, on: mapView, annotation: dirtAnnotation)
            isCustomDragging = false
            mapView.isScrollEnabled = savedMapScrollEnabled
            mapView.isRotateEnabled = savedMapRotateEnabled
            if gesture.state == .ended {
                onDragEnded?(dirtAnnotation.markerID, dirtAnnotation.coordinate)
            }

        default:
            break
        }
    }

    private func movePin(
        with gesture: UIPanGestureRecognizer,
        on mapView: MLNMapView,
        annotation: DirtAnnotation
    ) {
        // Finger tracks the pin tip (map coordinate), not the view center.
        let point = gesture.location(in: mapView)
        let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
        annotation.coordinate = coordinate
        let projected = mapView.convert(coordinate, toPointTo: mapView)
        center = CGPoint(
            x: projected.x + centerOffset.dx,
            y: projected.y + centerOffset.dy
        )
    }

    /// SVG path M18 43 C15.5 39.1 4 27.7 4 17.4 C4 9.1 10.3 2 18 2
    ///   S32 9.1 32 17.4 C32 27.7 20.5 39.1 18 43 Z  (absolute, derived from
    ///   the HTML index.html .stage-marker background SVG).
    private func tearDropPath() -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 18, y: 43))
        path.addCurve(
            to: CGPoint(x: 4, y: 17.4),
            controlPoint1: CGPoint(x: 15.5, y: 39.1),
            controlPoint2: CGPoint(x: 4, y: 27.7)
        )
        path.addCurve(
            to: CGPoint(x: 18, y: 2),
            controlPoint1: CGPoint(x: 4, y: 9.1),
            controlPoint2: CGPoint(x: 10.3, y: 2)
        )
        // Smooth cubic S32 9.1 32 17.4 (reflected cp = 25.7,2)
        path.addCurve(
            to: CGPoint(x: 32, y: 17.4),
            controlPoint1: CGPoint(x: 25.7, y: 2),
            controlPoint2: CGPoint(x: 32, y: 9.1)
        )
        path.addCurve(
            to: CGPoint(x: 18, y: 43),
            controlPoint1: CGPoint(x: 32, y: 27.7),
            controlPoint2: CGPoint(x: 20.5, y: 39.1)
        )
        path.close()
        return path
    }
}

extension DirtPlannerPinView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Don't let the map pan run alongside pin drag.
        false
    }
}

/// HTML-parity group rider pin: status-colored dot + name/status chip.
/// Frame-based layout — Auto Layout inside `MLNAnnotationView` often collapses
/// label intrinsic size to zero (blank white chip).
final class DirtRiderMarkerView: MLNAnnotationView {
    private let dot = UIView()
    private let chip = UIView()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        scalesWithViewingDistance = false
        clipsToBounds = false

        dot.layer.cornerRadius = 11
        dot.layer.borderWidth = 2
        dot.layer.borderColor = UIColor.white.cgColor
        dot.layer.shadowColor = UIColor.black.cgColor
        dot.layer.shadowOpacity = 0.35
        dot.layer.shadowRadius = 4
        dot.layer.shadowOffset = CGSize(width: 0, height: 2)

        chip.backgroundColor = UIColor.white.withAlphaComponent(0.96)
        chip.layer.cornerRadius = 6
        chip.layer.borderWidth = 1
        chip.layer.borderColor = UIColor.white.cgColor
        chip.layer.shadowColor = UIColor.black.cgColor
        chip.layer.shadowOpacity = 0.2
        chip.layer.shadowRadius = 4
        chip.layer.shadowOffset = CGSize(width: 0, height: 2)

        nameLabel.font = .systemFont(ofSize: 12, weight: .bold)
        nameLabel.textColor = UIColor(DirtTheme.ink)
        nameLabel.numberOfLines = 1

        statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = UIColor(DirtTheme.muted)
        statusLabel.numberOfLines = 1

        addSubview(dot)
        addSubview(chip)
        chip.addSubview(nameLabel)
        chip.addSubview(statusLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(for annotation: DirtAnnotation) {
        let status = {
            let raw = (annotation.status ?? "available").trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? "available" : raw.lowercased()
        }()
        let name = {
            let raw = annotation.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? "Rider" : raw
        }()

        nameLabel.text = name
        statusLabel.text = status.replacingOccurrences(of: "_", with: " ")
        dot.backgroundColor = Self.color(for: status)

        nameLabel.sizeToFit()
        statusLabel.sizeToFit()

        let padX: CGFloat = 6
        let padY: CGFloat = 3
        let textWidth = max(nameLabel.bounds.width, statusLabel.bounds.width)
        let chipWidth = max(44, textWidth + padX * 2)
        let chipHeight = nameLabel.bounds.height + statusLabel.bounds.height + padY * 2 + 1

        dot.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
        nameLabel.frame = CGRect(x: padX, y: padY, width: textWidth, height: nameLabel.bounds.height)
        statusLabel.frame = CGRect(
            x: padX,
            y: nameLabel.frame.maxY + 1,
            width: textWidth,
            height: statusLabel.bounds.height
        )
        chip.frame = CGRect(x: 14, y: 16, width: chipWidth, height: chipHeight)

        let boundsWidth = max(chip.frame.maxX, dot.frame.maxX) + 4
        let boundsHeight = max(chip.frame.maxY, dot.frame.maxY) + 2
        frame = CGRect(x: 0, y: 0, width: boundsWidth, height: boundsHeight)

        // Anchor the map coordinate at the center of the status dot.
        centerOffset = CGVector(dx: boundsWidth / 2 - 11, dy: boundsHeight / 2 - 11)
    }

    private static func color(for status: String) -> UIColor {
        switch status {
        case "breakdown": return UIColor(red: 0.863, green: 0.408, blue: 0.012, alpha: 1)
        case "injured": return UIColor(red: 0.757, green: 0.071, blue: 0.184, alpha: 1)
        case "stuck": return UIColor(red: 0.486, green: 0.227, blue: 0.929, alpha: 1)
        default: return UIColor(red: 0.012, green: 0.329, blue: 0.651, alpha: 1)
        }
    }
}

/// Navigation course arrow (replaces the default blue location dot while navigating).
final class DirtCoursePuckView: MLNUserLocationAnnotationView {
    private let arrow = UIImageView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 36, height: 36)
        scalesWithViewingDistance = false

        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .bold)
        arrow.image = UIImage(systemName: "location.north.fill", withConfiguration: config)
        arrow.tintColor = UIColor(DirtTheme.orange)
        arrow.contentMode = .scaleAspectFit
        arrow.frame = bounds
        arrow.layer.shadowColor = UIColor.black.cgColor
        arrow.layer.shadowOpacity = 0.45
        arrow.layer.shadowRadius = 3
        arrow.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(arrow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func update() {
        super.update()
        // MapLibre rotates the annotation view with course in followWithCourse;
        // keep the symbol pointing "up" in view space (= forward).
        arrow.transform = .identity
    }
}
