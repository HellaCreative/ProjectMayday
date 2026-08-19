import CoreLocation
import Foundation
import Observation
import UIKit

struct RouteDisplaySegment {
    let coordinates: [RouteCoordinate]
    /// Packed `trackClass` / `surfaceClass` key used for selected-route paint.
    let surfaceKey: String

    var isDirt: Bool {
        RouteSegment.isAdventureSurface(surfaceKey)
    }
}

/// Single source of truth the SwiftUI layer mutates and the MapLibre
/// representable consumes. Generation counters keep UIKit diffing cheap.
@Observable
final class MapState {
    enum MarkerKind {
        case start
        case stage
        case destination
        case rider
        /// Unresolved peer `rider_alerts` pin when the rider is not live-sharing.
        case alert

        /// Peer presence / alert pins managed by Groups — preserved across route marker rebuilds.
        var isGroupOverlay: Bool {
            self == .rider || self == .alert
        }
    }

    struct Marker: Identifiable {
        let id: String
        let latitude: Double
        let longitude: Double
        let label: String
        let kind: MarkerKind
        /// Callout / map name for riders (full display name).
        var subtitle: String?
        /// Rider presence status: available | breakdown | injured | stuck.
        var status: String?
        /// When true, map ignores drag / tap-to-relocate (From here fuel pins).
        var isLocked: Bool = false
    }

    enum CameraCommand {
        case center(latitude: Double, longitude: Double, zoom: Double)
        case fit([RouteCoordinate])
        case applyViewMode
        case resetNorth
    }

    /// Follow locked with course-up vs north-up while following.
    enum FollowMode: Equatable {
        case off
        case northUp
        case courseUp
    }

    private(set) var routeSegments: [RouteDisplaySegment] = []
    private(set) var routeGeneration = 0
    private(set) var markers: [Marker] = []
    private(set) var markerGeneration = 0
    private(set) var camera: (id: UUID, command: CameraCommand)?
    /// Bumps when the basemap style URL changes so MapLibre reloads.
    private(set) var styleGeneration = 0
    private(set) var styleURL: URL = MapStyleCatalog.styleURL()

    func applyBasemapStyleURL(_ url: URL) {
        guard url != styleURL else { return }
        styleURL = url
        styleGeneration += 1
    }

    func restoreCatalogBasemapStyle() {
        applyBasemapStyleURL(MapStyleCatalog.styleURL())
    }

    func applySelectedMapStyle() {
        applyBasemapStyleURL(MapStyleCatalog.styleURL())
    }

    // MARK: - Map viewport (set by Coordinator on regionDidChange)

    /// Current map center; POIManager / NetworkOverlayManager observe this.
    var mapCenter: CLLocationCoordinate2D = AppConfig.overviewCenter
    /// Current map zoom; managers observe for min-zoom gating.
    var mapZoom: Double = AppConfig.overviewZoom
    /// True until the first GPS/cached fix centers the map (or the rider pans away).
    private(set) var awaitingInitialUserCenter = true

    /// Center on the rider once at launch. Ignores later fixes after the first
    /// successful center, or after the rider manipulates the camera.
    func consumeInitialUserLocation(_ coordinate: CLLocationCoordinate2D) {
        guard awaitingInitialUserCenter else { return }
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        awaitingInitialUserCenter = false
        recenterOnUser(
            at: RouteCoordinate(longitude: coordinate.longitude, latitude: coordinate.latitude),
            detailZoom: AppConfig.userLaunchZoom
        )
    }

    /// Rider panned / pinched — do not yank back to GPS on the next fix.
    func cancelAwaitingInitialUserCenter() {
        awaitingInitialUserCenter = false
    }

    // MARK: - Overlay layer state

    /// Bumped by LayersSheet via AppEnvironment whenever any layer toggle changes.
    /// MapLibreMapView.Coordinator detects the bump and re-applies layer visibility.
    private(set) var layerPrefsGeneration = 0

    /// Current POI features published by POIManager (filtered, viewport-clipped).
    var poiFeatures: [POIFeature] = []
    /// Bumped by updatePOIFeatures(_:) to signal the coordinator to refresh the source.
    private(set) var poiDataGeneration = 0

    /// Current road-network features published by NetworkOverlayManager.
    var networkFeatures: [NetworkLineFeature] = []
    /// Bumped by updateNetworkFeatures(_:) to refresh the network source.
    private(set) var networkDataGeneration = 0
    /// When false, Layers omits `motorized_unknown` (purple Access the router will not use).
    private(set) var networkAllowUnknown = false

    /// Localhost XYZ template for BC OSM hierarchy mbtiles (nil = off / missing).
    private(set) var bcOSMTileURLTemplate: String?
    /// Status when the hierarchy toggle is on but tiles cannot load.
    private(set) var bcOSMStatusMessage: String?
    /// Bumped whenever the BC OSM vector source must be rebuilt.
    private(set) var bcOSMOverlayGeneration = 0

    /// POI tapped on the map; RootView observes this to present the routing sheet.
    var selectedPOI: POIFeature?
    /// Called by the coordinator when the user taps a POI marker.
    var onPOITap: ((POIFeature) -> Void)?

    // MARK: - Overlay mutation helpers (called from managers / UI)

    func bumpLayerPrefs() { layerPrefsGeneration += 1 }

    func setNetworkAllowUnknown(_ allow: Bool) {
        guard networkAllowUnknown != allow else { return }
        networkAllowUnknown = allow
        layerPrefsGeneration += 1
    }

    func updatePOIFeatures(_ features: [POIFeature]) {
        poiFeatures = features
        poiDataGeneration += 1
    }

    func updateNetworkFeatures(_ features: [NetworkLineFeature]) {
        networkFeatures = features
        networkDataGeneration += 1
    }

    func updateBCOSMHierarchy(template: String?, status: String?) {
        bcOSMTileURLTemplate = template
        bcOSMStatusMessage = status
        bcOSMOverlayGeneration += 1
    }

    /// True when the basemap is pitched.
    var view3D = false {
        didSet {
            guard view3D != oldValue else { return }
            camera = (UUID(), .applyViewMode)
        }
    }
    var followMode: FollowMode = .off
    /// Bumps whenever follow must be re-applied (recenter while already course-up).
    private(set) var followGeneration = 0
    /// Preferred zoom while course-up / north-up following.
    /// ~14.5 = two levels out from the old street-tight 16.5 (more look-ahead).
    var followZoom: Double = MapState.navigationDetailZoom
    /// Active navigation: main map shows detail follow vs full-route overview (PiP swap).
    var navigationCameraMode: NavigationCameraMode = .detail
    /// True while Start Nav prep is showing or the ride is active.
    /// Locks planner pin edit (tap / drag / relocate); map pan + zoom stay free.
    var isNavigating = false

    /// Detail follow zoom while navigating (MapLibre zoom; −2 from prior 16.5).
    static let navigationDetailZoom: Double = 14.5
    /// Extra top content inset while course-up navigating so the puck sits lower
    /// on screen and more of the road ahead is visible.
    static let navigationFollowTopInsetFraction: CGFloat = 0.30

    /// Start Nav prep: lock pins so corridor zoom can’t drag a waypoint and restart downloads.
    func lockRouteEditingForPrep() {
        isNavigating = true
        selectPlannerPin(nil)
    }

    /// Cancel Start Nav prep before Begin Ride — restore pin editing.
    func unlockRouteEditingAfterPrepCancel() {
        isNavigating = false
        selectPlannerPin(nil)
    }
    /// Live map bearing in degrees (updated by MapLibre) for the compass rose.
    var mapBearing: Double = 0
    /// Asymmetric chrome (e.g. landscape route drawer) — MapLibre centers/follow
    /// inside the remaining map, not under the sheet.
    var overlayContentInsets: UIEdgeInsets = .zero {
        didSet {
            guard overlayContentInsets != oldValue else { return }
            overlayInsetsGeneration += 1
        }
    }
    private(set) var overlayInsetsGeneration = 0

    /// From here: empty-map taps place B; long-press relocates with road snap.
    /// When true, short taps do not relocate a selected pin (B is long-press only).
    var fromHereLongPressRelocatesDestination = false

    enum NavigationCameraMode: Equatable {
        /// Course-up follow with look-ahead framing.
        case detail
        /// Fit entire active route (main map overview).
        case overview
    }
    var onTap: ((CLLocationCoordinate2D) -> Void)?
    var onLongPress: ((CLLocationCoordinate2D) -> Void)?
    var onRiderTap: ((String) -> Void)?
    /// Called when the user drags a planner pin and releases it.
    /// Arguments: marker ID (e.g. "s0", "e0", "dest") + new map coordinate.
    var onPlannerPinDragEnd: ((String, CLLocationCoordinate2D) -> Void)?

    /// Currently selected planner pin (tap-to-select, then drag or tap map to move).
    var selectedPlannerPinID: String? {
        didSet {
            guard selectedPlannerPinID != oldValue else { return }
            pinSelectionGeneration += 1
        }
    }
    private(set) var pinSelectionGeneration = 0

    func selectPlannerPin(_ markerID: String?) {
        selectedPlannerPinID = markerID
    }

    var followUser: Bool {
        get { followMode != .off }
        set { followMode = newValue ? .courseUp : .off }
    }

    var desiredPitch: Double {
        guard view3D else { return 0 }
        return followMode != .off ? 55 : 45
    }

    var isNorthUp: Bool {
        abs(mapBearing.truncatingRemainder(dividingBy: 360)) < 1.5
            || abs(mapBearing.truncatingRemainder(dividingBy: 360) - 360) < 1.5
    }

    func setRoute(_ segments: [RouteDisplaySegment]) {
        routeSegments = segments
        routeGeneration += 1
    }

    func clearRoute() {
        setRoute([])
    }

    /// Flattened active-route polyline for network corridor sampling.
    var routePolylineCoordinates: [RouteCoordinate] {
        var out: [RouteCoordinate] = []
        for segment in routeSegments {
            for coordinate in segment.coordinates {
                if let last = out.last,
                   abs(last.latitude - coordinate.latitude) < 1e-9,
                   abs(last.longitude - coordinate.longitude) < 1e-9 {
                    continue
                }
                out.append(coordinate)
            }
        }
        return out
    }

    func setMarkers(_ new: [Marker]) {
        markers = new
        markerGeneration += 1
    }

    func fly(to coordinate: RouteCoordinate, zoom: Double = 13) {
        camera = (UUID(), .center(latitude: coordinate.latitude, longitude: coordinate.longitude, zoom: zoom))
    }

    /// Frame coordinates in view. Releases location-follow so course-up / zoom-lock
    /// cannot yank the camera back after an overview fit (Zoom to Route).
    func fit(_ coordinates: [RouteCoordinate]) {
        stopFollowingForOverview()
        guard coordinates.count > 1 else {
            if let only = coordinates.first { fly(to: only) }
            return
        }
        camera = (UUID(), .fit(coordinates))
    }

    /// Drop user-tracking before overview framing (fit-route, stage focus, etc.).
    func stopFollowingForOverview() {
        if followMode != .off {
            followMode = .off
            followGeneration += 1
        }
    }

    func toggleView3D() {
        view3D.toggle()
    }

    /// Recenter: re-lock follow + course-up at navigation detail zoom.
    /// Always snap the camera to the known GPS fix first — zooming in place then
    /// enabling animated follow makes the puck scroll across the map.
    func recenterOnUser(at coordinate: RouteCoordinate?, detailZoom: Double = MapState.navigationDetailZoom) {
        navigationCameraMode = .detail
        followZoom = detailZoom
        followMode = .courseUp
        followGeneration += 1
        if let coordinate {
            camera = (UUID(), .center(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                zoom: detailZoom
            ))
        } else {
            camera = (UUID(), .applyViewMode)
        }
    }

    /// Enter navigation detail framing (called from planner on Start).
    func beginNavigationCamera() {
        isNavigating = true
        navigationCameraMode = .detail
        followZoom = MapState.navigationDetailZoom
        followMode = .courseUp
        followGeneration += 1
        camera = (UUID(), .applyViewMode)
    }

    func endNavigationCamera() {
        isNavigating = false
        navigationCameraMode = .detail
        followMode = .off
        followGeneration += 1
    }

    /// Swap main map between detail follow and full-route overview (nav control).
    func toggleNavigationCameraMode(
        routeCoordinates: [RouteCoordinate],
        userCoordinate: RouteCoordinate? = nil
    ) {
        guard isNavigating else { return }
        switch navigationCameraMode {
        case .detail:
            navigationCameraMode = .overview
            followMode = .off
            followGeneration += 1
            // Flatten for readable whole-route framing in landscape/portrait.
            if view3D { view3D = false }
            fit(routeCoordinates)
        case .overview:
            // Always snap back to GPS detail — nil fix still re-locks follow.
            recenterOnUser(
                at: userCoordinate,
                detailZoom: followZoom > 0 ? followZoom : MapState.navigationDetailZoom
            )
        }
    }

    /// Compass: unlock heading-up and ease the map north.
    func resetNorth() {
        if followMode == .courseUp {
            followMode = .northUp
            followGeneration += 1
        }
        camera = (UUID(), .resetNorth)
    }

    /// User panned/rotated the map — drop follow lock.
    func breakFollowFromGesture() {
        cancelAwaitingInitialUserCenter()
        guard followMode != .off else { return }
        followMode = .off
        followGeneration += 1
    }

    /// After a failed route, release follow lock so the map can pan again.
    /// Do not re-apply view mode — that recenters and makes the puck jump.
    func unlockAfterRouteFailure() {
        followMode = .off
        followGeneration += 1
    }

    /// Consolidates per-edge segments into continuous same-surface runs, the way
    /// adjacent same-surface edges are merged before painting.
    static func displaySegments(from responses: [RouteResponse]) -> [RouteDisplaySegment] {
        var result: [RouteDisplaySegment] = []
        for response in responses {
            let segments = response.segments ?? []
            var currentCoords: [RouteCoordinate] = []
            var currentKey: String?
            func flush() {
                if currentCoords.count > 1, let key = currentKey {
                    result.append(RouteDisplaySegment(coordinates: currentCoords, surfaceKey: key))
                }
                currentCoords = []
                currentKey = nil
            }
            if segments.isEmpty {
                let coords = response.coordinates
                if coords.count > 1 {
                    // No edge geometry: paint as connector.
                    result.append(RouteDisplaySegment(coordinates: coords, surfaceKey: "connector"))
                }
                continue
            }
            for segment in segments {
                let coords = segment.coordinates
                guard !coords.isEmpty else { continue }
                let key = segment.paintSurfaceKey
                if currentKey == key {
                    for coordinate in coords where coordinate != currentCoords.last {
                        currentCoords.append(coordinate)
                    }
                } else {
                    flush()
                    currentKey = key
                    currentCoords = coords
                }
            }
            flush()
        }
        return result
    }
}
