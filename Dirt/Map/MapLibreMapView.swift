import MapLibre
import QuartzCore
import SwiftUI

/// MapLibre Native wrapper: swappable basemap (OSM Shortbread or Mapbox classic
/// raster styles), per-surface route paint,
/// A/B/stage markers, rider pins, and user tracking.
struct MapLibreMapView: UIViewRepresentable {
    let state: MapState
    let location: LocationService

    /// Paint buckets per-surface route colors.
    enum RoutePaintBucket: String, CaseIterable {
        case paved
        case gravel
        case loose
        case unknown

        var sourceID: String { "dirt-route-\(rawValue)" }
        var lineID: String { "\(sourceID)-line" }

        var color: Color {
            switch self {
            case .paved: DirtTheme.routePaved
            case .gravel: DirtTheme.routeGravel
            case .loose: DirtTheme.routeLoose
            case .unknown: DirtTheme.routeUnknown
            }
        }

        static func bucket(for surfaceKey: String) -> RoutePaintBucket {
            RoutePaintBucket(rawValue: surfaceKey.lowercased()) ?? .unknown
        }
    }

    private enum RouteAccessPaint {
        static let sourceID = "dirt-route-unknown-access"
        static let lineID = "\(sourceID)-line"
    }

    private enum RouteFerryPaint {
        static let sourceID = "dirt-route-ferry"
        static let casingID = "\(sourceID)-casing"
        static let lineID = "\(sourceID)-line"
    }

    private enum RoutePaintMetrics {
        static let surfaceWidth: CGFloat = 8
        static let casingWidth: CGFloat = 10
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleURL: state.styleURL)
        mapView.delegate = context.coordinator
        // We own contentInset (landscape drawer + nav look-ahead). Auto-adjust
        // fights those values and can yank the camera while following.
        // Prefer MLNMapView.automaticallyAdjustsContentInset over the deprecated
        // UIViewController.automaticallyAdjustsScrollViewInsets path in MapLibre.
        mapView.automaticallyAdjustsContentInset = false
        mapView.locationManager = DirtMapLocationManager()
        let launch = location.lastLocation?.coordinate
        if let launch, CLLocationCoordinate2DIsValid(launch) {
            mapView.setCenter(launch, zoomLevel: AppConfig.userLaunchZoom, animated: false)
            // Seeded from cached GPS / last ride — don't wait for another fix to frame.
            DispatchQueue.main.async { [state] in
                state.consumeInitialUserLocation(launch)
            }
        } else {
            mapView.setCenter(AppConfig.overviewCenter, zoomLevel: AppConfig.overviewZoom, animated: false)
        }
        mapView.logoView.isHidden = true
        mapView.attributionButtonPosition = .bottomLeft
        // Custom compass lives in MapControlStack.
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
        tap.require(toFail: longPress)

        // Re-assert after attach — hosting VCs can fight the first assignment.
        DispatchQueue.main.async { [weak mapView] in
            mapView?.automaticallyAdjustsContentInset = false
        }

        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        mapView.automaticallyAdjustsContentInset = false
        mapView.showsUserLocation = location.isAuthorized
        context.coordinator.sync(mapView: mapView)
    }

    /// Per-category POI circle layer IDs and display colors.
    enum POILayer {
        static let generalSourceID = "dirt-poi"
        static let fuelSourceID = "dirt-poi-fuel"
        static let fuelClusterCircleID = "dirt-poi-fuel-cluster"
        static let fuelClusterCountID = "dirt-poi-fuel-cluster-count"
        static let categories: [(id: String, color: UIColor)] = [
            ("fuel",       UIColor(DirtTheme.orange)),
            ("campground", UIColor(red: 0.184, green: 0.620, blue: 0.267, alpha: 1)),
            ("lodging",    UIColor(red: 0.541, green: 0.353, blue: 0.169, alpha: 1)),
            ("liquor",     UIColor(red: 0.557, green: 0.267, blue: 0.788, alpha: 1))
        ]

        static func layerID(_ category: String) -> String { "dirt-poi-\(category)" }
        static func symbolID(_ category: String) -> String { "dirt-poi-\(category)-icon" }
        static func iconName(_ category: String) -> String { "dirt-poi-icon-\(category)" }
        /// Dots visible from regional overview for plan-route scanning.
        static let dotMinZoom = 6.5
        /// Numbered fuel clusters are useful only once the rider has moved
        /// from province overview into a local planning area.
        static let fuelClusterDetailMinZoom = 9.25
        /// Regional stations cluster through zoom 10; close planning shows all pumps.
        static let clusterMaxZoom = 10
        /// Glyphs only when close enough to distinguish individual stations.
        static let iconMinZoom = 10.5
        static var fuelSourceOptions: [MLNShapeSourceOption: Any] {
            [
                .clustered: true,
                .clusterRadius: 44,
                .clusterMinPoints: 2,
                .maximumZoomLevelForClustering: clusterMaxZoom
            ]
        }
        static var individualLayerIDs: [String] {
            categories.flatMap { [layerID($0.id), symbolID($0.id)] }
        }
        static var allLayerIDs: [String] {
            individualLayerIDs + [fuelClusterCircleID, fuelClusterCountID]
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
        private var appliedPlannerMarkerGeneration = -1
        private var appliedGroupMarkerGeneration = -1
        private var appliedFuelReplacementGeneration = -1
        private var appliedPinSelectionGeneration = -1
        private var appliedNavigatingLock: Bool?
        private var appliedCameraID: UUID?
        private var routeBuildSequenceID: UUID?
        private var importedRouteBuildStepCount = 0
        private var pendingRouteBuildSteps: [MapState.RouteBuildCameraStep] = []
        private var routeBuildCameraIsMoving = false
        private var routeBuildCameraRunID = UUID()
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
        private var appliedDebugGraph = -1
        private var appliedDebugPaintMode: DebugGraphPaintMode?

        init(state: MapState) {
            self.state = state
        }

        // MARK: Style / layers

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            self.mapView = mapView
            RoutingDebugLog.shared.event(
                "map style loaded url=\(mapView.styleURL?.absoluteString ?? "unknown")"
            )
            // Dual-sport nav: highway number shields (“NS 104 TCH”) crowd the
            // trail at mid zooms — hide them; keep ordinary street name labels.
            Self.hideHighwayShieldLabels(in: style)
            // Layer insertion order: network overlays (below) → route → POI
            addNetworkLayers(to: style)
            addDebugGraphLayers(to: style)
            addRouteLayers(to: style)
            addPOILayers(to: style)
            styleLoaded = true
            appliedRouteGeneration = -1
            appliedFuelReplacementGeneration = -1
            // Force overlay re-sync after a style reload
            appliedPoiData = -1; appliedPoiPrefs = -1
            appliedNetData = -1; appliedNetPrefs = -1
            appliedDebugGraph = -1
            sync(mapView: mapView)
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            let ns = error as NSError
            RoutingDebugLog.shared.event(
                "map load failed domain=\(ns.domain) code=\(ns.code) message=\(error.localizedDescription) style=\(mapView.styleURL?.absoluteString ?? "unknown")"
            )
        }

        /// Shortbread `label-shield-*` + junction ref chips — visual chrome only.
        private static func hideHighwayShieldLabels(in style: MLNStyle) {
            for layer in style.layers {
                let id = layer.identifier.lowercased()
                let isShield = id.contains("label-shield") || id.contains("shield-")
                let isJunctionRef = id.contains("motorway_junction") && id.contains("ref")
                if isShield || isJunctionRef {
                    layer.isVisible = false
                }
            }
        }

        // MARK: - Network overlay layers

        private func addNetworkLayers(to style: MLNStyle) {
            guard style.source(withIdentifier: "dirt-network") == nil else { return }
            let src = MLNShapeSource(identifier: "dirt-network", shape: nil, options: nil)
            style.addSource(src)

            // Nearby network, not selected-route paint: access stays blue so it
            // cannot be read as route unknown-access purple.
            let access = MLNLineStyleLayer(identifier: "dirt-net-access", source: src)
            access.predicate = NSPredicate(format: "surfaceClass == 'access' AND accessClass != 'motorized_restricted'")
            access.lineColor = NSExpression(forConstantValue: UIColor(DirtTheme.overlayAccess))
            access.lineWidth = NSExpression(forConstantValue: 2)
            access.lineOpacity = NSExpression(forConstantValue: 0.88)
            style.addLayer(access)

            // Nearby gravel stays cool gray so selected-route amber gravel still wins.
            let gravel = MLNLineStyleLayer(identifier: "dirt-net-gravel", source: src)
            gravel.predicate = NSPredicate(format: "surfaceClass == 'gravel' AND accessClass != 'motorized_restricted'")
            gravel.lineColor = NSExpression(forConstantValue: UIColor(DirtTheme.overlayGravel))
            gravel.lineWidth = NSExpression(forConstantValue: 2)
            gravel.lineOpacity = NSExpression(forConstantValue: 0.88)
            style.addLayer(gravel)

            // Nearby dirt/track uses route-loose brown, not purple.
            let track = MLNLineStyleLayer(identifier: "dirt-net-track", source: src)
            track.predicate = NSPredicate(format: "surfaceClass == 'track' AND accessClass != 'motorized_restricted'")
            track.lineColor = NSExpression(forConstantValue: UIColor(DirtTheme.overlayTrack))
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
            // Network surface classes always paint when features are loaded.
            // Map visibility toggles were removed; zoom / DIRT-logo control load.
        }

        private func addDebugGraphLayers(to style: MLNStyle) {
            guard style.source(withIdentifier: "dirt-debug-graph") == nil else { return }
            let src = MLNShapeSource(identifier: "dirt-debug-graph", shape: nil, options: nil)
            style.addSource(src)
            rebuildDebugPaintLayers(on: style, mode: state.debugGraphPaintMode)
            appliedDebugPaintMode = state.debugGraphPaintMode
        }

        private func debugPaintLayerIDs(for mode: DebugGraphPaintMode) -> [String] {
            PackDebugPaint.legend(for: mode).map { "dirt-debug-\(mode.rawValue)-\($0.key)" }
        }

        private func rebuildDebugPaintLayers(on style: MLNStyle, mode: DebugGraphPaintMode) {
            for old in DebugGraphPaintMode.allCases.flatMap({ debugPaintLayerIDs(for: $0) }) {
                if let layer = style.layer(withIdentifier: old) {
                    style.removeLayer(layer)
                }
            }
            guard let src = style.source(withIdentifier: "dirt-debug-graph") else { return }
            let attr = PackDebugPaint.attributeKey(for: mode)
            for item in PackDebugPaint.legend(for: mode) {
                let id = "dirt-debug-\(mode.rawValue)-\(item.key)"
                let layer = MLNLineStyleLayer(identifier: id, source: src)
                if mode == .access, item.key == "atv" {
                    layer.predicate = NSPredicate(format: "atvDesignated == 1")
                } else {
                    layer.predicate = NSPredicate(format: "%K == %@", attr, item.key)
                }
                layer.lineColor = NSExpression(forConstantValue: item.color)
                layer.lineWidth = NSExpression(forConstantValue: mode == .access && item.key == "atv" ? 3.2 : 2.4)
                layer.lineOpacity = NSExpression(forConstantValue: 0.92)
                if item.dashed {
                    layer.lineDashPattern = NSExpression(forConstantValue: [1.2, 1.2] as [NSNumber])
                }
                style.addLayer(layer)
            }
        }

        private func syncDebugGraphPaintMode(style: MLNStyle) {
            guard appliedDebugPaintMode != state.debugGraphPaintMode else { return }
            rebuildDebugPaintLayers(on: style, mode: state.debugGraphPaintMode)
            appliedDebugPaintMode = state.debugGraphPaintMode
        }

        // MARK: - POI layers (drawn above route layers)

        private func addPOILayers(to style: MLNStyle) {
            guard style.source(withIdentifier: POILayer.generalSourceID) == nil else { return }
            let generalSource = MLNShapeSource(
                identifier: POILayer.generalSourceID,
                shape: nil,
                options: nil
            )
            let fuelSource = MLNShapeSource(
                identifier: POILayer.fuelSourceID,
                shape: nil,
                options: POILayer.fuelSourceOptions
            )
            style.addSource(generalSource)
            style.addSource(fuelSource)
            registerPOIIcons(in: style)

            let fuelColor = POILayer.categories.first(where: { $0.id == "fuel" })?.color
                ?? UIColor(DirtTheme.orange)
            let clusterCircle = MLNCircleStyleLayer(
                identifier: POILayer.fuelClusterCircleID,
                source: fuelSource
            )
            clusterCircle.predicate = NSPredicate(format: "cluster == YES")
            clusterCircle.circleColor = NSExpression(forConstantValue: fuelColor)
            clusterCircle.circleRadius = NSExpression(mglJSONObject: [
                "interpolate", ["linear"], ["get", "point_count"],
                2, 13,
                10, 17,
                50, 21
            ] as [Any])
            clusterCircle.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
            clusterCircle.circleStrokeWidth = NSExpression(forConstantValue: 2)
            clusterCircle.minimumZoomLevel = Float(POILayer.fuelClusterDetailMinZoom)
            clusterCircle.maximumZoomLevel = Float(POILayer.iconMinZoom)
            style.addLayer(clusterCircle)

            let clusterCount = MLNSymbolStyleLayer(
                identifier: POILayer.fuelClusterCountID,
                source: fuelSource
            )
            clusterCount.predicate = NSPredicate(format: "cluster == YES")
            clusterCount.text = NSExpression(forKeyPath: "point_count_abbreviated")
            clusterCount.textColor = NSExpression(forConstantValue: UIColor.white)
            clusterCount.textFontSize = NSExpression(forConstantValue: 11)
            clusterCount.textAllowsOverlap = NSExpression(forConstantValue: true)
            clusterCount.textIgnoresPlacement = NSExpression(forConstantValue: true)
            clusterCount.minimumZoomLevel = Float(POILayer.fuelClusterDetailMinZoom)
            clusterCount.maximumZoomLevel = Float(POILayer.iconMinZoom)
            style.addLayer(clusterCount)

            for (cat, color) in POILayer.categories {
                let source = cat == "fuel" ? fuelSource : generalSource
                // Soft colored disc — small dots when zoomed out for planning,
                // larger when close enough to read icons.
                let circle = MLNCircleStyleLayer(identifier: POILayer.layerID(cat), source: source)
                circle.predicate = cat == "fuel"
                    ? NSPredicate(format: "category == %@ AND cluster != YES", cat)
                    : NSPredicate(format: "category == %@", cat)
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
                let symbol = MLNSymbolStyleLayer(identifier: POILayer.symbolID(cat), source: source)
                symbol.predicate = cat == "fuel"
                    ? NSPredicate(format: "category == %@ AND cluster != YES", cat)
                    : NSPredicate(format: "category == %@", cat)
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

        /// Keep selected-route paint above the road geometry but below the
        /// basemap's trail and street names. Both bundled map styles share
        /// these label identifiers; the fallback preserves route visibility if
        /// a future style does not.
        private func addRouteLayer(_ layer: MLNStyleLayer, to style: MLNStyle) {
            let labelAnchorIDs = [
                "label-path-bottom-12",
                "label-street-centre-12"
            ]
            if let labelAnchor = labelAnchorIDs.lazy.compactMap({
                style.layer(withIdentifier: $0)
            }).first {
                style.insertLayer(layer, below: labelAnchor)
            } else {
                style.addLayer(layer)
            }
        }

        private func addRouteLayers(to style: MLNStyle) {
            guard style.source(withIdentifier: RoutePaintBucket.paved.sourceID) == nil else { return }

            // Unknown access replaces surface paint: one opaque stroke, not a halo.
            let accessSource = MLNShapeSource(
                identifier: RouteAccessPaint.sourceID,
                shape: nil,
                options: nil
            )
            style.addSource(accessSource)
            let accessLine = MLNLineStyleLayer(
                identifier: RouteAccessPaint.lineID,
                source: accessSource
            )
            accessLine.lineColor = NSExpression(forConstantValue: UIColor(DirtTheme.routeAccess))
            accessLine.lineWidth = NSExpression(forConstantValue: RoutePaintMetrics.surfaceWidth)
            accessLine.lineOpacity = NSExpression(forConstantValue: 1)
            accessLine.lineCap = NSExpression(forConstantValue: "round")
            accessLine.lineJoin = NSExpression(forConstantValue: "round")
            addRouteLayer(accessLine, to: style)

            for bucket in RoutePaintBucket.allCases {
                let source = MLNShapeSource(identifier: bucket.sourceID, shape: nil, options: nil)
                style.addSource(source)

                let line = MLNLineStyleLayer(identifier: bucket.lineID, source: source)
                line.lineColor = NSExpression(forConstantValue: UIColor(bucket.color))
                line.lineWidth = NSExpression(forConstantValue: RoutePaintMetrics.surfaceWidth)
                line.lineOpacity = NSExpression(forConstantValue: 1)
                line.lineCap = NSExpression(forConstantValue: "round")
                line.lineJoin = NSExpression(forConstantValue: "round")

                addRouteLayer(line, to: style)
            }

            // Ferry is not a fifth surface. It receives a conventional marine
            // dash treatment and remains outside the Dirt/Paved composition.
            let ferrySource = MLNShapeSource(
                identifier: RouteFerryPaint.sourceID,
                shape: nil,
                options: nil
            )
            style.addSource(ferrySource)

            let ferryCasing = MLNLineStyleLayer(
                identifier: RouteFerryPaint.casingID,
                source: ferrySource
            )
            ferryCasing.lineColor = NSExpression(forConstantValue: UIColor.white)
            ferryCasing.lineWidth = NSExpression(forConstantValue: RoutePaintMetrics.casingWidth)
            ferryCasing.lineOpacity = NSExpression(forConstantValue: 0.72)
            ferryCasing.lineCap = NSExpression(forConstantValue: "round")
            ferryCasing.lineJoin = NSExpression(forConstantValue: "round")

            let ferryLine = MLNLineStyleLayer(
                identifier: RouteFerryPaint.lineID,
                source: ferrySource
            )
            ferryLine.lineColor = NSExpression(forConstantValue: UIColor(DirtTheme.routeFerry))
            ferryLine.lineWidth = NSExpression(forConstantValue: RoutePaintMetrics.surfaceWidth)
            ferryLine.lineOpacity = NSExpression(forConstantValue: 0.92)
            ferryLine.lineDashPattern = NSExpression(forConstantValue: [2.4, 1.1] as [NSNumber])
            ferryLine.lineCap = NSExpression(forConstantValue: "round")
            ferryLine.lineJoin = NSExpression(forConstantValue: "round")

            addRouteLayer(ferryCasing, to: style)
            addRouteLayer(ferryLine, to: style)
        }

        // MARK: Sync

        func sync(mapView: MLNMapView) {
            self.mapView = mapView
            applyContentInsets(on: mapView)
            syncStyle(mapView: mapView)
            // Explicit camera (fit / fly) before follow — otherwise the follow
            // zoom-lock can immediately undo a Zoom-to-Route after recenter.
            syncCamera(mapView: mapView)
            syncRouteBuildCamera(mapView: mapView)
            syncFollow(mapView: mapView)
            syncMarkers(mapView: mapView)
            syncPinSelection(mapView: mapView)
            syncPinEditLock(mapView: mapView)
            guard styleLoaded, let style = mapView.style else { return }
            syncRoute(style: style)
            syncPOI(style: style)
            syncFuelReplacementEmphasis(style: style)
            syncNetwork(style: style)
            syncDebugGraphPaintMode(style: style)
            syncDebugGraph(style: style)
        }

        /// MapLibre recenters immediately when contentInset changes — only write
        /// when the inset actually moved, or course-up follow looks like a flick.
        private func applyContentInsets(on mapView: MLNMapView) {
            var insets = state.overlayContentInsets
            if state.isNavigating,
               state.navigationCameraMode == .detail,
               state.followMode != .off,
               mapView.bounds.height > 1 {
                let bias = (mapView.bounds.height * MapState.navigationFollowTopInsetFraction)
                    .rounded(.toNearestOrAwayFromZero)
                insets.top += bias
            }
            let current = mapView.contentInset
            let changed =
                abs(current.top - insets.top) > 0.5
                || abs(current.left - insets.left) > 0.5
                || abs(current.bottom - insets.bottom) > 0.5
                || abs(current.right - insets.right) > 0.5
            guard changed else { return }
            // animated:false still updates immediately; avoid completion churn.
            mapView.contentInset = insets
        }

        // MARK: - POI sync

        private func syncPOI(style: MLNStyle) {
            let dataChanged  = appliedPoiData  != state.poiDataGeneration
            let prefsChanged = appliedPoiPrefs != state.layerPrefsGeneration
            guard dataChanged || prefsChanged else { return }
            appliedPoiData  = state.poiDataGeneration
            appliedPoiPrefs = state.layerPrefsGeneration

            if dataChanged {
                let pointFeature: (POIFeature) -> MLNPointFeature = { poi in
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
                let fuelShapes = state.poiFeatures.filter { $0.category == "fuel" }.map(pointFeature)
                let generalShapes = state.poiFeatures.filter { $0.category != "fuel" }.map(pointFeature)
                (style.source(withIdentifier: POILayer.fuelSourceID) as? MLNShapeSource)?.shape =
                    MLNShapeCollectionFeature(shapes: fuelShapes)
                (style.source(withIdentifier: POILayer.generalSourceID) as? MLNShapeSource)?.shape =
                    MLNShapeCollectionFeature(shapes: generalShapes)
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
            style.layer(withIdentifier: POILayer.fuelClusterCircleID)?.isVisible = prefs.showFuel
            style.layer(withIdentifier: POILayer.fuelClusterCountID)?.isVisible = prefs.showFuel
            applyFuelReplacementEmphasis(to: style)
        }

        private func applyFuelReplacementEmphasis(to style: MLNStyle) {
            let opacity = state.hasFuelReplacementCandidates ? 0.28 : 1.0
            (style.layer(withIdentifier: POILayer.layerID("fuel")) as? MLNCircleStyleLayer)?
                .circleOpacity = NSExpression(forConstantValue: opacity)
            (style.layer(withIdentifier: POILayer.symbolID("fuel")) as? MLNSymbolStyleLayer)?
                .iconOpacity = NSExpression(forConstantValue: opacity)
            (style.layer(withIdentifier: POILayer.fuelClusterCircleID) as? MLNCircleStyleLayer)?
                .circleOpacity = NSExpression(forConstantValue: opacity)
            (style.layer(withIdentifier: POILayer.fuelClusterCountID) as? MLNSymbolStyleLayer)?
                .textOpacity = NSExpression(forConstantValue: opacity)
        }

        private func syncFuelReplacementEmphasis(style: MLNStyle) {
            guard appliedFuelReplacementGeneration != state.markerGeneration else { return }
            appliedFuelReplacementGeneration = state.markerGeneration
            applyFuelReplacementEmphasis(to: style)
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

        private func syncDebugGraph(style: MLNStyle) {
            guard appliedDebugGraph != state.debugGraphDataGeneration else { return }
            appliedDebugGraph = state.debugGraphDataGeneration
            let lines = state.debugGraphFeatures.compactMap { feature -> MLNPolylineFeature? in
                guard feature.coordinates.count >= 2 else { return nil }
                var coords = feature.coordinates.map {
                    CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                }
                let line = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
                line.attributes = [
                    "edgeId": feature.edgeId,
                    "surfaceClass": feature.surfaceClass,
                    "accessClass": feature.accessClass,
                    "roadClass": feature.roadClass,
                    "source": RoutingGraphDebugManager.sourceLabel(edgeId: feature.edgeId),
                    "surfaceLeaf": feature.surfaceLeaf,
                    "surfaceFamily": feature.surfaceFamily,
                    "roadClassLeaf": feature.roadClassLeaf,
                    "roadTier": feature.roadTier,
                    "accessLeaf": feature.accessLeaf,
                    "atvDesignated": feature.atvDesignated ? 1 : 0
                ]
                return line
            }
            (style.source(withIdentifier: "dirt-debug-graph") as? MLNShapeSource)?.shape =
                MLNShapeCollectionFeature(shapes: lines)
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
                let segments = state.routeSegments.filter {
                    !$0.isFerry && !$0.accessUnknown && RoutePaintBucket.bucket(for: $0.surfaceKey) == bucket
                }
                (style.source(withIdentifier: bucket.sourceID) as? MLNShapeSource)?.shape = polylines(for: segments)
            }
            let ferries = state.routeSegments.filter(\.isFerry)
            (style.source(withIdentifier: RouteFerryPaint.sourceID) as? MLNShapeSource)?.shape =
                polylines(for: ferries)
            let unknownAccess = state.routeSegments.filter { !$0.isFerry && $0.accessUnknown }
            (style.source(withIdentifier: RouteAccessPaint.sourceID) as? MLNShapeSource)?.shape =
                polylines(for: unknownAccess)
        }

        private func polylines(for segments: [RouteDisplaySegment]) -> MLNShapeCollectionFeature {
            let lines = segments.map { segment -> MLNPolylineFeature in
                var coordinates = segment.coordinates.map(\.locationCoordinate)
                let line = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
                var attributes: [String: Any] = [:]
                if let stageIndex = segment.stageIndex { attributes["stageIndex"] = stageIndex }
                if let riderLegID = segment.riderLegID { attributes["riderLegID"] = riderLegID.uuidString }
                line.attributes = attributes
                return line
            }
            return MLNShapeCollectionFeature(shapes: lines)
        }

        private func syncMarkers(mapView: MLNMapView) {
            if appliedPlannerMarkerGeneration != state.plannerMarkerGeneration {
                appliedPlannerMarkerGeneration = state.plannerMarkerGeneration
                let oldPlanner = annotations.filter { !$0.kind.isGroupOverlay }
                mapView.removeAnnotations(oldPlanner)
                annotations.removeAll { !$0.kind.isGroupOverlay }
                let next = state.plannerMarkers.map(makeAnnotation)
                annotations.append(contentsOf: next)
                mapView.addAnnotations(next)
                // Force selection chrome to re-apply after planner pin rebuild.
                appliedPinSelectionGeneration = -1
                appliedNavigatingLock = nil
                syncPinSelection(mapView: mapView)
                syncPinEditLock(mapView: mapView)
            }

            if appliedGroupMarkerGeneration != state.groupMarkerGeneration {
                appliedGroupMarkerGeneration = state.groupMarkerGeneration
                let desired = Dictionary(uniqueKeysWithValues: state.groupMarkers.map { ($0.id, $0) })
                let existing = annotations.filter(\.kind.isGroupOverlay)
                let stale = existing.filter { desired[$0.markerID] == nil }
                if !stale.isEmpty {
                    mapView.removeAnnotations(stale)
                    let staleIDs = Set(stale.map(\.markerID))
                    annotations.removeAll { staleIDs.contains($0.markerID) }
                }
                let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.markerID, $0) })
                var added: [DirtAnnotation] = []
                for marker in state.groupMarkers {
                    if let annotation = existingByID[marker.id] {
                        annotation.coordinate = CLLocationCoordinate2D(
                            latitude: marker.latitude,
                            longitude: marker.longitude
                        )
                        annotation.label = marker.label
                        annotation.status = marker.status
                        annotation.title = marker.subtitle ?? marker.label
                        if let view = mapView.view(for: annotation) as? DirtRiderMarkerView {
                            view.configure(for: annotation)
                        }
                    } else {
                        let annotation = makeAnnotation(marker)
                        annotations.append(annotation)
                        added.append(annotation)
                    }
                }
                if !added.isEmpty { mapView.addAnnotations(added) }
            }
        }

        private func makeAnnotation(_ marker: MapState.Marker) -> DirtAnnotation {
            let annotation = DirtAnnotation()
            annotation.coordinate = CLLocationCoordinate2D(latitude: marker.latitude, longitude: marker.longitude)
            annotation.markerID = marker.id
            annotation.label = marker.label
            annotation.kind = marker.kind
            annotation.status = marker.status
            annotation.isLocked = marker.isLocked
            annotation.title = marker.subtitle ?? marker.label
            return annotation
        }

        private func syncPinSelection(mapView: MLNMapView) {
            guard appliedPinSelectionGeneration != state.pinSelectionGeneration else { return }
            appliedPinSelectionGeneration = state.pinSelectionGeneration
            let selectedID = state.selectedPlannerPinID
            for annotation in annotations {
                guard !annotation.kind.isGroupOverlay,
                      let view = mapView.view(for: annotation) as? DirtPlannerPinView else { continue }
                view.applySelectionChrome(annotation.markerID == selectedID, animated: true)
            }
            // Keep MapLibre selection in sync for drag-to-move.
            if let selectedID,
               let annotation = annotations.first(where: { $0.markerID == selectedID }) {
                mapView.selectAnnotation(annotation, animated: false, completionHandler: nil)
            }
        }

        /// When Start Nav locks editing, clear drag callbacks on already-built pin views.
        private func syncPinEditLock(mapView: MLNMapView) {
            let locked = state.isNavigating
            guard appliedNavigatingLock != locked else { return }
            appliedNavigatingLock = locked
            for annotation in annotations {
                guard !annotation.kind.isGroupOverlay,
                      let view = mapView.view(for: annotation) as? DirtPlannerPinView else { continue }
                if locked || annotation.isLocked {
                    view.onDragBegan = nil
                    view.onDragEnded = nil
                    view.applySelectionChrome(false, animated: false)
                } else {
                    view.onDragBegan = { [weak self] markerID in
                        self?.state.selectPlannerPin(markerID)
                        self?.state.onPlannerPinDragBegan?(markerID)
                    }
                    view.onDragEnded = { [weak self] markerID, coordinate in
                        self?.finishPlannerPinMove(markerID, coordinate: coordinate)
                    }
                }
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
            case let .zoom(level):
                mapView.setZoomLevel(level, animated: !UIAccessibility.isReduceMotionEnabled)
            case let .center(latitude, longitude, zoom):
                // Instant snap — never animate center while (re)engaging follow.
                // An animated setCenter raced follow and produced zoom-then-scroll.
                mapView.setCenter(
                    CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    zoomLevel: zoom,
                    direction: mapView.direction,
                    animated: false
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
                // Portrait used a huge bottom inset for the tall nav panel — that
                // collapses the visible map to nothing in landscape and breaks PiP overview.
                // Planning: sheet / drawer already live in `contentInset` via
                // `overlayContentInsets` — only add soft chrome so the line clears
                // brand + Packs/fit/recenter chips (do not double-count the sheet).
                let landscape = mapView.bounds.width > mapView.bounds.height
                let insets: UIEdgeInsets
                if state.isNavigating, landscape {
                    insets = UIEdgeInsets(top: 96, left: 160, bottom: 28, right: 80)
                } else if state.isNavigating {
                    insets = UIEdgeInsets(top: 100, left: 48, bottom: 280, right: 48)
                } else {
                    let overlay = state.overlayContentInsets
                    let sheetOpen =
                        overlay.bottom > 1 || overlay.left > 1 || overlay.right > 1
                    // No sheet: clear the portrait dock. Sheet open: clear control chips.
                    let bottomChrome: CGFloat = sheetOpen ? 64 : 120
                    insets = UIEdgeInsets(top: 88, left: 40, bottom: bottomChrome, right: 40)
                }
                mapView.setVisibleCoordinateBounds(bounds, edgePadding: insets, animated: true, completionHandler: nil)
                applyPitch(on: mapView, animated: false)
            case .applyViewMode:
                applyPitch(on: mapView, animated: true)
            case .resetNorth:
                // Drop any course-up tracking first — otherwise MapLibre restores
                // travel heading and the compass looks like a no-op (with a jog).
                mapView.userTrackingMode = .none
                // Use setDirection — mutating camera.heading via setCamera also
                // twitches pitch/center.
                let animate = state.followMode == .off
                mapView.setDirection(0, animated: animate)
                state.mapBearing = 0
            }
        }

        private func syncRouteBuildCamera(mapView: MLNMapView) {
            guard let sequence = state.routeBuildCameraSequence else {
                cancelRouteBuildCameraPlayback()
                return
            }
            if routeBuildSequenceID != sequence.id {
                cancelRouteBuildCameraPlayback()
                routeBuildSequenceID = sequence.id
                importedRouteBuildStepCount = 0
            }
            if sequence.steps.count > importedRouteBuildStepCount {
                pendingRouteBuildSteps.append(
                    contentsOf: sequence.steps[importedRouteBuildStepCount...]
                )
                importedRouteBuildStepCount = sequence.steps.count
            }
            playNextRouteBuildCameraStep(on: mapView)
        }

        private func playNextRouteBuildCameraStep(on mapView: MLNMapView) {
            guard !routeBuildCameraIsMoving, !pendingRouteBuildSteps.isEmpty else { return }
            routeBuildCameraIsMoving = true
            let step = pendingRouteBuildSteps.removeFirst()
            let runID = routeBuildCameraRunID
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            mapView.userTrackingMode = .none
            suppressFollowBreak(for: 1.2)
            // Set pitch before moving the camera. A second camera write during a
            // bounds animation is the flick the rider reported.
            applyPitch(on: mapView, animated: false)

            switch step {
            case .start(let coordinate):
                mapView.setCenter(
                    coordinate.locationCoordinate,
                    zoomLevel: 12.5,
                    direction: mapView.direction,
                    animated: !reduceMotion
                )
                finishRouteBuildCameraStep(
                    on: mapView,
                    runID: runID,
                    delay: reduceMotion ? 0.05 : 0.45
                )

            case .completedLeg(let coordinates):
                guard let bounds = coordinateBounds(for: coordinates) else {
                    finishRouteBuildCameraStep(on: mapView, runID: runID, delay: 0)
                    return
                }
                let insets = planningCameraInsets(for: mapView)
                if reduceMotion {
                    mapView.setVisibleCoordinateBounds(
                        bounds,
                        edgePadding: insets,
                        animated: false,
                        completionHandler: nil
                    )
                    finishRouteBuildCameraStep(on: mapView, runID: runID, delay: 0.05)
                } else {
                    mapView.setVisibleCoordinateBounds(
                        bounds,
                        edgePadding: insets,
                        animated: true
                    ) { [weak self, weak mapView] in
                        guard let self, let mapView else { return }
                        self.finishRouteBuildCameraStep(on: mapView, runID: runID, delay: 0.18)
                    }
                }
            }
        }

        private func finishRouteBuildCameraStep(
            on mapView: MLNMapView,
            runID: UUID,
            delay: TimeInterval
        ) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak mapView] in
                guard let self, let mapView, self.routeBuildCameraRunID == runID else { return }
                self.routeBuildCameraIsMoving = false
                self.playNextRouteBuildCameraStep(on: mapView)
            }
        }

        private func cancelRouteBuildCameraPlayback() {
            routeBuildCameraRunID = UUID()
            routeBuildSequenceID = nil
            importedRouteBuildStepCount = 0
            pendingRouteBuildSteps = []
            routeBuildCameraIsMoving = false
        }

        private func coordinateBounds(for coordinates: [RouteCoordinate]) -> MLNCoordinateBounds? {
            guard let first = coordinates.first else { return nil }
            var bounds = MLNCoordinateBounds(
                sw: first.locationCoordinate,
                ne: first.locationCoordinate
            )
            for coordinate in coordinates.dropFirst() {
                bounds.sw.latitude = min(bounds.sw.latitude, coordinate.latitude)
                bounds.sw.longitude = min(bounds.sw.longitude, coordinate.longitude)
                bounds.ne.latitude = max(bounds.ne.latitude, coordinate.latitude)
                bounds.ne.longitude = max(bounds.ne.longitude, coordinate.longitude)
            }
            return bounds
        }

        private func planningCameraInsets(for mapView: MLNMapView) -> UIEdgeInsets {
            let overlay = state.overlayContentInsets
            let sheetOpen = overlay.bottom > 1 || overlay.left > 1 || overlay.right > 1
            let bottomChrome: CGFloat = sheetOpen ? 64 : 120
            return UIEdgeInsets(top: 88, left: 40, bottom: bottomChrome, right: 40)
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
            guard needsReapply else { return }
            followApplied = state.followMode
            followGenerationApplied = state.followGeneration
            // Only suppress *programmatic* follow-breaks while we snap/engage.
            // User pan/pinch must still unlock immediately (see regionWillChange).
            suppressFollowBreak(for: 1.5)
            switch state.followMode {
            case .off:
                mapView.userTrackingMode = .none
            case .northUp:
                snapToUserForFollow(mapView: mapView)
                // No chase animation — camera already at user from snap / recenter.
                mapView.setUserTrackingMode(.follow, animated: false, completionHandler: nil)
            case .courseUp:
                snapToUserForFollow(mapView: mapView)
                mapView.setUserTrackingMode(.followWithCourse, animated: false, completionHandler: nil)
            }
            applyPitch(on: mapView, animated: false)
        }

        /// Put user under the crosshair at `followZoom` before enabling tracking.
        /// Never `setZoomLevel` alone first — that zooms wherever the map is looking,
        /// then tracking scrolls the puck across the screen.
        private func snapToUserForFollow(mapView: MLNMapView) {
            let zoom = state.followZoom
            // northUp must force bearing 0 — preserving direction here used to
            // undo compass "reset north" right after syncCamera ran.
            let direction: CLLocationDirection =
                state.followMode == .northUp ? 0 : mapView.direction
            if let user = mapView.userLocation?.coordinate,
               CLLocationCoordinate2DIsValid(user) {
                mapView.setCenter(user, zoomLevel: zoom, direction: direction, animated: false)
            } else if abs(mapView.zoomLevel - zoom) > 0.35 {
                mapView.setZoomLevel(zoom, animated: false)
            } else if state.followMode == .northUp, abs(mapView.direction) > 0.5 {
                mapView.setDirection(0, animated: false)
            }
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
            publishViewport(from: mapView)
        }

        func mapView(
            _ mapView: MLNMapView,
            regionWillChangeWith reason: MLNCameraChangeReason,
            animated: Bool
        ) {
            handleCameraChangeReason(reason)
        }

        func mapView(_ mapView: MLNMapView, regionIsChangingWith reason: MLNCameraChangeReason) {
            handleCameraChangeReason(reason)
        }

        func mapView(
            _ mapView: MLNMapView,
            regionDidChangeWith reason: MLNCameraChangeReason,
            animated: Bool
        ) {
            handleCameraChangeReason(reason)
            let bearing = mapView.direction
            if abs(bearing - state.mapBearing) > 0.4 {
                state.mapBearing = bearing
            }
            publishViewport(from: mapView)
        }

        private func publishViewport(from mapView: MLNMapView) {
            let visible = mapView.visibleCoordinateBounds
            state.updateMapViewport(
                center: mapView.camera.centerCoordinate,
                zoom: mapView.zoomLevel,
                bounds: MapViewportBounds(
                    minLongitude: visible.sw.longitude,
                    minLatitude: visible.sw.latitude,
                    maxLongitude: visible.ne.longitude,
                    maxLatitude: visible.ne.latitude
                )
            )
        }

        /// MapLibre clears tracking on user gesture — keep `followMode` in sync so
        /// `syncFollow` does not immediately re-lock course-up.
        func mapView(_ mapView: MLNMapView, didChange mode: MLNUserTrackingMode, animated: Bool) {
            guard mode == .none, state.followMode != .off else { return }
            // Ignore tracking resets that fire while we are programmatically engaging follow.
            if let until = suppressFollowBreakUntil, Date() < until { return }
            state.breakFollowFromGesture()
            followApplied = .off
        }

        private func handleCameraChangeReason(_ reason: MLNCameraChangeReason) {
            let gestureBits: MLNCameraChangeReason = [
                .gesturePan,
                .gesturePinch,
                .gestureRotate,
                .gestureZoomIn,
                .gestureZoomOut,
                .gestureTilt,
                .gestureOneFingerZoom
            ]
            // User gestures always release follow — even during the post-recenter
            // suppress window (that window only shields programmatic setCenter/zoom).
            if !reason.isDisjoint(with: gestureBits) {
                cancelRouteBuildCameraPlayback()
                state.cancelRouteBuildCamera()
                state.breakFollowFromGesture()
                return
            }
            if let until = suppressFollowBreakUntil, Date() < until { return }
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
            if dirtAnnotation.kind.isGroupOverlay {
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
            if state.isNavigating || dirtAnnotation.isLocked {
                view.onDragBegan = nil
                view.onDragEnded = nil
            } else {
                view.onDragBegan = { [weak self] markerID in
                    self?.state.selectPlannerPin(markerID)
                    self?.state.onPlannerPinDragBegan?(markerID)
                }
                view.onDragEnded = { [weak self] markerID, coordinate in
                    self?.finishPlannerPinMove(markerID, coordinate: coordinate)
                }
            }
            return view
        }

        private func finishPlannerPinMove(_ markerID: String, coordinate: CLLocationCoordinate2D) {
            guard let mapView else { return }
            let point = mapView.convert(coordinate, toPointTo: mapView)
            guard let snapped = snapToNearestRoad(coordinate, at: point, in: mapView) else {
                state.onPlannerPinSnapFailed?()
                return
            }
            state.onPlannerPinDragEnd?(markerID, snapped)
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            // Fuel pins expose the packed station name on tap. Other planner
            // pins use direct selection/drag behavior and need no callout.
            guard let dirtAnnotation = annotation as? DirtAnnotation else { return false }
            return dirtAnnotation.kind == .fuel
        }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            guard let dirtAnnotation = annotation as? DirtAnnotation else { return }
            if dirtAnnotation.kind.isGroupOverlay {
                state.onRiderTap?(dirtAnnotation.markerID)
                mapView.deselectAnnotation(annotation, animated: false)
                return
            }
            guard !state.isNavigating else { return }
            // Tap pin → select (orange lift) so drag / second-tap relocate is obvious.
            state.selectPlannerPin(dirtAnnotation.markerID)
            (mapView.view(for: dirtAnnotation) as? DirtPlannerPinView)?
                .applySelectionChrome(!dirtAnnotation.isLocked, animated: true)
            if dirtAnnotation.kind == .fuel {
                state.onPlannerPinDragBegan?(dirtAnnotation.markerID)
            }
        }

        func mapView(_ mapView: MLNMapView, didDeselect annotation: MLNAnnotation) {
            guard let dirtAnnotation = annotation as? DirtAnnotation,
                  !dirtAnnotation.kind.isGroupOverlay,
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
                  !dirtAnnotation.kind.isGroupOverlay,
                  !dirtAnnotation.isLocked else { return }
            if newState == .starting || newState == .dragging {
                state.selectPlannerPin(dirtAnnotation.markerID)
            }
            guard newState == .ending else { return }
            finishPlannerPinMove(dirtAnnotation.markerID, coordinate: annotation.coordinate)
            // Keep selection so the rider can nudge again; chrome stays on.
        }

        // MARK: Gestures

        private enum TouchResolution {
            case pin(DirtAnnotation)
            case route(UUID)
            case map
        }

        private func resolveTouch(_ point: CGPoint, in mapView: MLNMapView) -> TouchResolution {
            if let pin = plannerAnnotation(at: point, in: mapView) { return .pin(pin) }
            if let riderLegID = routeRiderLegID(at: point, in: mapView) { return .route(riderLegID) }
            return .map
        }

        private func logTouch(_ resolution: TouchResolution, gesture: String? = nil) {
            let suffix = gesture.map { " gesture=\($0)" } ?? ""
            switch resolution {
            case .pin(let pin):
                let kind = pin.kind == .fuel ? "fuel" : "waypoint"
                RoutingDebugLog.shared.event(
                    "map tap result=pin markerID=\(pin.markerID) kind=\(kind)\(suffix)"
                )
            case .route(let riderLegID):
                RoutingDebugLog.shared.event(
                    "map tap result=route riderLegID=\(riderLegID.uuidString)\(suffix)"
                )
            case .map:
                RoutingDebugLog.shared.event("map tap result=map\(suffix)")
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let mapView else { return }
            let pt = gesture.location(in: mapView)

            // Group rider / name badge wins — open peer details, never From here.
            if let rider = groupOverlayAnnotation(at: pt, in: mapView) {
                mapView.selectAnnotation(rider, animated: false, completionHandler: nil)
                return
            }

            let resolution = resolveTouch(pt, in: mapView)

            // Planner pin wins over route and map. Fuel selects for its info card,
            // but remains locked against every relocation path.
            if case .pin(let pin) = resolution {
                logTouch(resolution)
                if pin.kind == .fuel,
                   pin.markerID == state.selectedPlannerPinID,
                   !pin.markerID.hasPrefix("fuel-target:") {
                    state.onPlannerPinDragBegan?(pin.markerID)
                    return
                }
                mapView.selectAnnotation(pin, animated: true, completionHandler: nil)
                state.selectPlannerPin(pin.markerID)
                return
            }

            // POI wins over pin-drop: generous hit box so a near-miss still
            // opens the POI sheet instead of placing a From-here destination.
            if let cluster = fuelClusterFeature(at: pt, in: mapView, hitRadius: 32) {
                zoomIntoFuelCluster(cluster, on: mapView)
                return
            }
            if let poi = poiFeature(at: pt, in: mapView, hitRadius: 32) {
                state.onPOITap?(poi)
                return
            }

            if state.showRoutingGraphDebug,
               let hit = debugGraphFeature(at: pt, in: mapView) {
                state.debugGraphHit = hit
                return
            }

            let raw = mapView.convert(pt, toCoordinateFrom: mapView)
            if case .route(let riderLegID) = resolution {
                if state.isRouteBuilding {
                    RoutingDebugLog.shared.event("map tap result=route ignored reason=building")
                    return
                }
                logTouch(resolution)
                state.onRouteTap?(riderLegID, raw, "tap")
                return
            }
            logTouch(.map)
            let coordinate = snapToNearestRoad(raw, at: pt, in: mapView) ?? raw
            state.onTap?(coordinate)
        }

        /// The route casing is intentionally wider than the visible line, giving
        /// route editing a forgiving touch target without stealing nearby map taps.
        private func routeRiderLegID(at point: CGPoint, in mapView: MLNMapView) -> UUID? {
            let hitRadius: CGFloat = 14
            let box = CGRect(
                x: point.x - hitRadius,
                y: point.y - hitRadius,
                width: hitRadius * 2,
                height: hitRadius * 2
            )
            let ids = Set(
                RoutePaintBucket.allCases.map(\.lineID)
                    + [
                        RouteAccessPaint.lineID,
                        RouteFerryPaint.casingID,
                        RouteFerryPaint.lineID
                    ]
            )
            let features = mapView.visibleFeatures(in: box, styleLayerIdentifiers: ids)
            for feature in features {
                guard let raw = feature.attribute(forKey: "riderLegID") as? String,
                      let riderLegID = UUID(uuidString: raw) else { continue }
                return riderLegID
            }
            return nil
        }

        private func groupOverlayAnnotation(at point: CGPoint, in mapView: MLNMapView) -> DirtAnnotation? {
            let hitRadius: CGFloat = 44
            var best: DirtAnnotation?
            var bestDist = CGFloat.greatestFiniteMagnitude
            for annotation in annotations where annotation.kind.isGroupOverlay {
                let pinPoint = mapView.convert(annotation.coordinate, toPointTo: mapView)
                // Dot is at the coordinate; name chip sits down/right of it.
                let chipCenter = CGPoint(x: pinPoint.x + 28, y: pinPoint.y + 18)
                let candidates = [pinPoint, chipCenter]
                for center in candidates {
                    let dx = center.x - point.x
                    let dy = center.y - point.y
                    let dist = sqrt(dx * dx + dy * dy)
                    if dist <= hitRadius && dist < bestDist {
                        bestDist = dist
                        best = annotation
                    }
                }
            }
            return best
        }

        private func plannerAnnotation(at point: CGPoint, in mapView: MLNMapView) -> DirtAnnotation? {
            var best: DirtAnnotation?
            var bestDist = CGFloat.greatestFiniteMagnitude
            for annotation in annotations where !annotation.kind.isGroupOverlay {
                let pinPoint = mapView.convert(annotation.coordinate, toPointTo: mapView)
                // The annotation coordinate is the tip. The view frame covers the
                // full body and tip and already reflects the selected scale.
                let selectedScale: CGFloat = annotation.markerID == state.selectedPlannerPinID ? 1.18 : 1
                let kindScale: CGFloat = annotation.kind == .fuel ? 0.82 : 1
                let scale = selectedScale * kindScale
                let fallbackFrame: CGRect
                if annotation.markerID.hasPrefix("fuel-target:") {
                    fallbackFrame = CGRect(
                        x: pinPoint.x - DirtPlannerPinView.pinWidth * scale / 2,
                        y: pinPoint.y - DirtPlannerPinView.pinHeight * scale / 2,
                        width: DirtPlannerPinView.pinWidth * scale,
                        height: DirtPlannerPinView.pinHeight * scale
                    )
                } else {
                    fallbackFrame = CGRect(
                        x: pinPoint.x - DirtPlannerPinView.pinWidth * scale / 2,
                        y: pinPoint.y - DirtPlannerPinView.pinHeight * scale,
                        width: DirtPlannerPinView.pinWidth * scale,
                        height: DirtPlannerPinView.pinHeight * scale
                    )
                }
                let frame = mapView.view(for: annotation)?.frame ?? fallbackFrame
                guard frame.insetBy(dx: -12, dy: -12).contains(point) else { continue }
                let dx = pinPoint.x - point.x
                let dy = pinPoint.y - point.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist < bestDist {
                    bestDist = dist
                    best = annotation
                }
            }
            return best
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let mapView else { return }
            // Prep / active ride: map is inspect-only — no new waypoints.
            guard !state.isNavigating else { return }
            let pt = gesture.location(in: mapView)
            let resolution = resolveTouch(pt, in: mapView)
            switch resolution {
            case .pin(let pin):
                logTouch(resolution, gesture: "longPress")
                mapView.selectAnnotation(pin, animated: true, completionHandler: nil)
                state.selectPlannerPin(pin.markerID)
                return
            case .route(let riderLegID):
                if state.isRouteBuilding {
                    RoutingDebugLog.shared.event("map tap result=route ignored reason=building")
                    return
                }
                logTouch(resolution, gesture: "longPress")
                let raw = mapView.convert(pt, toCoordinateFrom: mapView)
                state.onRouteTap?(riderLegID, raw, "longPress")
                return
            case .map:
                break
            }
            if let cluster = fuelClusterFeature(at: pt, in: mapView, hitRadius: 32) {
                zoomIntoFuelCluster(cluster, on: mapView)
                return
            }
            // Same rule for plan waypoints: don't place on top of a POI.
            if let poi = poiFeature(at: pt, in: mapView, hitRadius: 32) {
                state.onPOITap?(poi)
                return
            }
            let raw = mapView.convert(pt, toCoordinateFrom: mapView)
            let coordinate = snapToNearestRoad(raw, at: pt, in: mapView) ?? raw
            logTouch(.map, gesture: "longPress")
            state.onLongPress?(coordinate)
        }

        private func debugGraphFeature(at point: CGPoint, in mapView: MLNMapView) -> RoutingGraphDebugHit? {
            let ids = Set(debugPaintLayerIDs(for: state.debugGraphPaintMode))
            let box = CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32)
            let hits = mapView.visibleFeatures(in: box, styleLayerIdentifiers: ids)
            guard let feature = hits.first else { return nil }
            let attrs = feature.attributes
            let edgeId = attrs["edgeId"] as? String ?? ""
            let atvRaw = attrs["atvDesignated"]
            let atv = (atvRaw as? Int).map { $0 != 0 }
                ?? (atvRaw as? NSNumber).map { $0.intValue != 0 }
                ?? false
            return RoutingGraphDebugHit(
                edgeId: edgeId,
                surfaceClass: attrs["surfaceClass"] as? String ?? "",
                accessClass: attrs["accessClass"] as? String ?? "",
                roadClass: attrs["roadClass"] as? String ?? "",
                source: attrs["source"] as? String ?? RoutingGraphDebugManager.sourceLabel(edgeId: edgeId),
                surfaceLeaf: attrs["surfaceLeaf"] as? String ?? "",
                surfaceFamily: attrs["surfaceFamily"] as? String ?? "",
                roadClassLeaf: attrs["roadClassLeaf"] as? String ?? "",
                roadTier: attrs["roadTier"] as? String ?? "",
                accessLeaf: attrs["accessLeaf"] as? String ?? "",
                atvDesignated: atv
            )
        }

        /// Snap a long-press to the nearest motorable road in the basemap
        /// (highway line layers). Generous hit box so placement feels magnetic.
        private func snapToNearestRoad(
            _ coordinate: CLLocationCoordinate2D,
            at point: CGPoint,
            in mapView: MLNMapView
        ) -> CLLocationCoordinate2D? {
            guard let style = mapView.style else { return nil }
            let roadIDs = Self.motorableRoadLayerIDs(in: style)
            guard !roadIDs.isEmpty else { return nil }

            // ~90pt search radius ≈ serious snap at dual-sport zooms.
            let hitRadius: CGFloat = 90
            let box = CGRect(
                x: point.x - hitRadius,
                y: point.y - hitRadius,
                width: hitRadius * 2,
                height: hitRadius * 2
            )
            let hits = mapView.visibleFeatures(in: box, styleLayerIdentifiers: roadIDs)
            let probe = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

            var best: (coordinate: RouteCoordinate, meters: Double)?
            for feature in hits {
                let polylines = Self.polylines(from: feature)
                for line in polylines where line.count >= 2 {
                    if let nearest = GeoMath.nearestPointOnPolyline(probe, in: line, maxMeters: 2_500) {
                        if best == nil || nearest.meters < best!.meters {
                            best = nearest
                        }
                    }
                }
            }
            guard let best else { return nil }
            return best.coordinate.locationCoordinate
        }

        private static func motorableRoadLayerIDs(in style: MLNStyle) -> Set<String> {
            let prefer = [
                "motorway", "trunk", "primary", "secondary", "tertiary",
                "unclassified", "residential", "living_street", "service", "track"
            ]
            let skip = ["footway", "path", "steps", "cycleway", "bridleway", "pedestrian", "raceway"]
            var ids = Set<String>()
            for layer in style.layers {
                let id = layer.identifier.lowercased()
                guard id.contains("highway") || id.contains("street") else { continue }
                if skip.contains(where: { id.contains($0) }) { continue }
                if prefer.contains(where: { id.contains($0) }) {
                    ids.insert(layer.identifier)
                }
            }
            // Fallback: any highway line layer if filters were too strict.
            if ids.isEmpty {
                for layer in style.layers where layer is MLNLineStyleLayer {
                    let id = layer.identifier.lowercased()
                    if id.contains("highway") { ids.insert(layer.identifier) }
                }
            }
            return ids
        }

        private static func polylines(from feature: MLNFeature) -> [[RouteCoordinate]] {
            if let line = feature as? MLNPolyline {
                return [coords(from: line)]
            }
            if let multi = feature as? MLNMultiPolyline {
                return multi.polylines.map { coords(from: $0) }
            }
            // Shape-source features often arrive as MLNPolylineFeature.
            if let lineFeature = feature as? MLNPolylineFeature {
                return [coords(from: lineFeature)]
            }
            return []
        }

        private static func coords(from polyline: MLNPolyline) -> [RouteCoordinate] {
            let count = Int(polyline.pointCount)
            guard count > 0 else { return [] }
            let ptr = polyline.coordinates
            return (0..<count).map { i in
                let c = ptr[i]
                return RouteCoordinate(longitude: c.longitude, latitude: c.latitude)
            }
        }

        private func poiFeature(at point: CGPoint, in mapView: MLNMapView, hitRadius: CGFloat) -> POIFeature? {
            let box = CGRect(
                x: point.x - hitRadius,
                y: point.y - hitRadius,
                width: hitRadius * 2,
                height: hitRadius * 2
            )
            let poiLayerIDs = Set(POILayer.individualLayerIDs)
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

        private func fuelClusterFeature(
            at point: CGPoint,
            in mapView: MLNMapView,
            hitRadius: CGFloat
        ) -> MLNPointFeature? {
            let box = CGRect(
                x: point.x - hitRadius,
                y: point.y - hitRadius,
                width: hitRadius * 2,
                height: hitRadius * 2
            )
            let layerIDs: Set<String> = [
                POILayer.fuelClusterCircleID,
                POILayer.fuelClusterCountID
            ]
            return mapView.visibleFeatures(in: box, styleLayerIdentifiers: layerIDs)
                .compactMap { $0 as? MLNPointFeature }
                .first
        }

        private func zoomIntoFuelCluster(_ cluster: MLNPointFeature, on mapView: MLNMapView) {
            let nextZoom = min(max(mapView.zoomLevel + 2, 8.5), 11)
            mapView.setCenter(cluster.coordinate, zoomLevel: nextZoom, animated: true)
            RoutingDebugLog.shared.event(
                "map tap result=fuelCluster count=\(cluster.attributes["point_count"] ?? "unknown") zoom=\(nextZoom)"
            )
        }
    }
}

final class DirtAnnotation: MLNPointAnnotation {
    var markerID = ""
    var label = ""
    var kind: MapState.MarkerKind = .start
    var status: String?
    var isLocked = false
}

/// Teardrop stage pin: dark body + orange circle + white number,
/// bottom-anchored so the pin tip sits on the map coordinate.
/// A selected, editable waypoint owns its one-finger pan. Map gestures must
/// not cancel it after it has begun; system cancellation still ends the drag.
private final class DirtPinPanGestureRecognizer: UIPanGestureRecognizer {
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

final class DirtPlannerPinView: MLNAnnotationView {
    static let pinWidth: CGFloat = 36
    static let pinHeight: CGFloat = 44

    private let bodyLayer = CAShapeLayer()
    private let circleLayer = CAShapeLayer()
    private let labelView = UILabel()
    private let candidateHaloLayer = CAShapeLayer()
    private let candidateBadgeLayer = CAShapeLayer()
    private let candidateIconView = UIImageView()
    private var baseScale: CGFloat = 1
    private var isFuelCandidate = false
    private var isSelectedForEditing = false
    private var isCustomDragging = false
    private var dragOrigin: CLLocationCoordinate2D?
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
        isAccessibilityElement = true
        accessibilityTraits = [.button]

        // Shadow on the container layer
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.38
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 2)

        // Replacement candidates are centered pump badges, not route-stage pins.
        candidateHaloLayer.path = UIBezierPath(
            ovalIn: CGRect(x: 2, y: 6, width: 32, height: 32)
        ).cgPath
        candidateHaloLayer.fillColor = UIColor.clear.cgColor
        candidateHaloLayer.strokeColor = UIColor(DirtTheme.orange).cgColor
        candidateHaloLayer.lineWidth = 2
        candidateHaloLayer.opacity = 0
        layer.addSublayer(candidateHaloLayer)

        candidateBadgeLayer.path = UIBezierPath(
            ovalIn: CGRect(x: 5, y: 9, width: 26, height: 26)
        ).cgPath
        candidateBadgeLayer.fillColor = UIColor(DirtTheme.orange).cgColor
        candidateBadgeLayer.strokeColor = UIColor.white.cgColor
        candidateBadgeLayer.lineWidth = 2
        candidateBadgeLayer.isHidden = true
        layer.addSublayer(candidateBadgeLayer)

        // Teardrop body (viewBox 0 0 36 44).
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

        candidateIconView.frame = CGRect(x: 10, y: 14, width: 16, height: 16)
        candidateIconView.image = UIImage(systemName: "fuelpump.fill")
        candidateIconView.tintColor = .white
        candidateIconView.contentMode = .scaleAspectFit
        candidateIconView.isHidden = true
        addSubview(candidateIconView)

        let pan = DirtPinPanGestureRecognizer(target: self, action: #selector(handlePinPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(for annotation: DirtAnnotation) {
        if isCustomDragging { restoreMapGestures(reason: "pinReconfigured") }
        isFuelCandidate = annotation.markerID.hasPrefix("fuel-target:")
        labelView.text = annotation.label
        baseScale = annotation.kind == .fuel ? 0.82 : 1
        centerOffset = isFuelCandidate
            ? .zero
            : CGVector(dx: 0, dy: -(Self.pinHeight * baseScale / 2))
        transform = CGAffineTransform(scaleX: baseScale, y: baseScale)
        bodyLayer.isHidden = isFuelCandidate
        circleLayer.isHidden = isFuelCandidate
        labelView.isHidden = isFuelCandidate
        candidateBadgeLayer.isHidden = !isFuelCandidate
        candidateIconView.isHidden = !isFuelCandidate
        updateCandidateHalo()
        isAccessibilityElement = true
        let title = annotation.title ?? annotation.label
        accessibilityLabel = isFuelCandidate
            ? "Alternative fuel station, \(title)"
            : annotation.kind == .fuel
            ? "Fuel stop \(annotation.label), \(title)"
            : "Route pin \(annotation.label)"
        // All planner pins: dark #111820 body + orange circle.
        bodyLayer.fillColor = UIColor(red: 17/255, green: 24/255, blue: 32/255, alpha: 1).cgColor
        bodyLayer.strokeColor = UIColor(DirtTheme.orange).cgColor
        circleLayer.fillColor = UIColor(DirtTheme.orange).cgColor
    }

    private func updateCandidateHalo() {
        candidateHaloLayer.removeAllAnimations()
        guard isFuelCandidate else {
            candidateHaloLayer.opacity = 0
            return
        }
        candidateHaloLayer.opacity = UIAccessibility.isReduceMotionEnabled ? 0.9 : 0.7
        guard !UIAccessibility.isReduceMotionEnabled else { return }

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.85
        scale.toValue = 1.35
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.7
        opacity.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = 1.2
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        candidateHaloLayer.add(group, forKey: "fuelCandidatePulse")
    }

    /// Selected = lifted + thicker orange rim so "ready to move" is obvious.
    func applySelectionChrome(_ selected: Bool, animated: Bool) {
        isSelectedForEditing = selected
        let changes = {
            self.transform = selected
                ? CGAffineTransform(scaleX: self.baseScale * 1.18, y: self.baseScale * 1.18)
                : CGAffineTransform(scaleX: self.baseScale, y: self.baseScale)
            self.bodyLayer.lineWidth = selected ? 2.5 : 1
            self.bodyLayer.strokeColor = UIColor(DirtTheme.orange).cgColor
            self.layer.shadowOpacity = selected ? 0.55 : 0.38
            self.layer.shadowRadius = selected ? 6 : 3
            self.circleLayer.lineWidth = selected ? 2 : 0
            self.circleLayer.strokeColor = selected ? UIColor.white.cgColor : UIColor.clear.cgColor
            self.candidateBadgeLayer.lineWidth = selected ? 3 : 2
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

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let annotation = annotation as? DirtAnnotation else { return false }
        return isSelectedForEditing && onDragEnded != nil && annotation.kind != .fuel
    }

    @objc private func handlePinPan(_ gesture: UIPanGestureRecognizer) {
        // Terminal events must always release MapLibre, even when a state update
        // removed the annotation/callback while the finger was still down.
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            let mapView = hostMapView
            let dirtAnnotation = annotation as? DirtAnnotation
            if isCustomDragging, let mapView, let dirtAnnotation {
                movePin(with: gesture, on: mapView, annotation: dirtAnnotation)
            }
            let shouldNotify = gesture.state == .ended && isCustomDragging
            let markerID = dirtAnnotation?.markerID
            let coordinate = dirtAnnotation?.coordinate
            if !shouldNotify, let origin = dragOrigin {
                dirtAnnotation?.coordinate = origin
            }
            dragOrigin = nil
            restoreMapGestures(reason: "pinDrag\(gesture.state.rawValue)")
            if shouldNotify, let markerID, let coordinate {
                RoutingDebugLog.shared.event("map pinPan end markerID=\(markerID)")
                onDragEnded?(markerID, coordinate)
            }
            return
        }

        guard let mapView = hostMapView,
              let dirtAnnotation = annotation as? DirtAnnotation else { return }

        if gesture.state == .began, dirtAnnotation.kind == .fuel {
            RoutingDebugLog.shared.event(
                "map pinPan refused markerID=\(dirtAnnotation.markerID) reason=fuel"
            )
            return
        }

        // Nil during prep / navigation — let map pan/zoom win; never move pins.
        guard onDragEnded != nil else { return }

        switch gesture.state {
        case .began:
            guard isSelectedForEditing else { return }
            RoutingDebugLog.shared.event("map pinPan begin markerID=\(dirtAnnotation.markerID)")
            dragOrigin = dirtAnnotation.coordinate
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

        default:
            break
        }
    }

    private func restoreMapGestures(reason: String) {
        guard isCustomDragging else { return }
        isCustomDragging = false
        if let mapView = hostMapView {
            mapView.isScrollEnabled = savedMapScrollEnabled
            mapView.isRotateEnabled = savedMapRotateEnabled
        }
        RoutingDebugLog.shared.event(
            "map gesture lock released reason=\(reason) scroll=\(savedMapScrollEnabled ? 1 : 0) rotate=\(savedMapRotateEnabled ? 1 : 0)"
        )
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { restoreMapGestures(reason: "pinRemovedFromWindow") }
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
    ///   the stage-marker SVG).
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

/// Group rider pin: status-colored dot + name/status chip.
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
        isEnabled = true
        isUserInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityTraits = [.button]

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

        nameLabel.font = .preferredFont(forTextStyle: .caption1)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = UIColor(DirtTheme.ink)
        nameLabel.numberOfLines = 1

        statusLabel.font = .preferredFont(forTextStyle: .caption2)
        statusLabel.adjustsFontForContentSizeCategory = true
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
            GroupsViewModel.normalizedStatus(annotation.status ?? "riding")
        }()
        let name = {
            let raw = annotation.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? "Rider" : raw
        }()

        nameLabel.text = name
        statusLabel.text = GroupsViewModel.statusLabel(status)
        dot.backgroundColor = Self.color(for: status)
        accessibilityLabel = name
        accessibilityValue = GroupsViewModel.statusLabel(status)
        accessibilityHint = "Opens rider details"

        nameLabel.sizeToFit()
        statusLabel.sizeToFit()

        let padX: CGFloat = 6
        let padY: CGFloat = 3
        let textWidth = max(nameLabel.bounds.width, statusLabel.bounds.width)
        let chipWidth = max(44, textWidth + padX * 2)
        let chipHeight = nameLabel.bounds.height + statusLabel.bounds.height + padY * 2 + 1

        let markerSize: CGFloat = 22
        let markerGap: CGFloat = 5
        let boundsWidth = max(chipWidth, markerSize) + 8
        let chipX = (boundsWidth - chipWidth) / 2
        let dotX = (boundsWidth - markerSize) / 2

        // Keep the identity chip above the location marker. Besides leaving the
        // dot and road beneath it unobscured, centering the two prevents the
        // chip from covering the beginning of the rider's name.
        chip.frame = CGRect(x: chipX, y: 0, width: chipWidth, height: chipHeight)
        dot.frame = CGRect(
            x: dotX,
            y: chip.frame.maxY + markerGap,
            width: markerSize,
            height: markerSize
        )
        nameLabel.frame = CGRect(x: padX, y: padY, width: textWidth, height: nameLabel.bounds.height)
        statusLabel.frame = CGRect(
            x: padX,
            y: nameLabel.frame.maxY + 1,
            width: textWidth,
            height: statusLabel.bounds.height
        )
        let boundsHeight = max(chip.frame.maxY, dot.frame.maxY) + 2
        // MapLibre owns this view's screen-space center. Both resizing and
        // changing `centerOffset` can reposition an annotation view during a
        // live refresh, so restore the map-provided center after updating its
        // geometry. This prevents rider chips jumping to the top-left corner.
        let mapPosition = center
        bounds = CGRect(x: 0, y: 0, width: boundsWidth, height: boundsHeight)

        // Anchor the map coordinate at the center of the status dot.
        centerOffset = CGVector(
            dx: boundsWidth / 2 - dot.frame.midX,
            dy: boundsHeight / 2 - dot.frame.midY
        )
        center = mapPosition
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Expand hit area to cover the name/status chip, not just the 22pt dot.
        let padded = bounds.insetBy(dx: -8, dy: -8)
        return padded.contains(point) || chip.frame.insetBy(dx: -6, dy: -6).contains(point)
    }

    private static func color(for status: String) -> UIColor {
        switch status {
        case "breakdown", "flat_tire", "dead_battery", "unrepairable":
            return UIColor(red: 0.863, green: 0.408, blue: 0.012, alpha: 1)
        case "injured": return UIColor(red: 0.757, green: 0.071, blue: 0.184, alpha: 1)
        case "stuck": return UIColor(red: 0.486, green: 0.227, blue: 0.929, alpha: 1)
        default: return UIColor(DirtTheme.navGreen)
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
