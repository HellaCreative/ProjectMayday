import CoreLocation
import Foundation
import Observation

struct RouteDisplaySegment {
    let coordinates: [RouteCoordinate]
    /// Web `trackClass` / `surfaceClass` key used for selected-route paint.
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
    }

    enum CameraCommand {
        case center(latitude: Double, longitude: Double, zoom: Double)
        case fit([RouteCoordinate])
        case applyViewMode
        case resetNorth
    }

    /// Web stack: follow locked with course-up vs north-up while following.
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

    // MARK: - Map viewport (set by Coordinator on regionDidChange)

    /// Current map center; POIManager / NetworkOverlayManager observe this.
    var mapCenter: CLLocationCoordinate2D = AppConfig.overviewCenter
    /// Current map zoom; managers observe for min-zoom gating.
    var mapZoom: Double = AppConfig.overviewZoom

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

    /// POI tapped on the map; RootView observes this to present the routing sheet.
    var selectedPOI: POIFeature?
    /// Called by the coordinator when the user taps a POI marker.
    var onPOITap: ((POIFeature) -> Void)?

    // MARK: - Overlay mutation helpers (called from managers / UI)

    func bumpLayerPrefs() { layerPrefsGeneration += 1 }

    func updatePOIFeatures(_ features: [POIFeature]) {
        poiFeatures = features
        poiDataGeneration += 1
    }

    func updateNetworkFeatures(_ features: [NetworkLineFeature]) {
        networkFeatures = features
        networkDataGeneration += 1
    }

    /// True when the basemap is pitched (web `view3d`).
    var view3D = false {
        didSet {
            guard view3D != oldValue else { return }
            camera = (UUID(), .applyViewMode)
        }
    }
    var followMode: FollowMode = .off
    /// Bumps whenever follow must be re-applied (recenter while already course-up).
    private(set) var followGeneration = 0
    /// Preferred zoom while course-up / north-up following (dual-sport needs ~16–17).
    var followZoom: Double = 16.5
    /// Active navigation: main map shows detail follow vs full-route overview (PiP swap).
    var navigationCameraMode: NavigationCameraMode = .detail
    /// True while NavigationSession is prefetching or active — drives puck + gesture rules.
    var isNavigating = false
    /// Live map bearing in degrees (updated by MapLibre) for the compass rose.
    var mapBearing: Double = 0

    enum NavigationCameraMode: Equatable {
        /// Tight follow / course-up.
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

    func applySelectedMapStyle() {
        let next = MapStyleCatalog.styleURL()
        guard next != styleURL else { return }
        styleURL = next
        styleGeneration += 1
    }

    func setRoute(_ segments: [RouteDisplaySegment]) {
        routeSegments = segments
        routeGeneration += 1
    }

    func clearRoute() {
        setRoute([])
    }

    /// Flattened active-route polyline for network corridor sampling (HTML `activeRouteCoordinates`).
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

    /// Web recenter: re-lock follow + course-up at dual-sport detail zoom (~16.5).
    /// Follow alone owns the camera — a parallel `fly` raced `applyPitch`/`setCamera`
    /// against `setCenter` and caused a mid-map hitch before snapping to GPS.
    func recenterOnUser(at coordinate: RouteCoordinate?, detailZoom: Double = 16.5) {
        navigationCameraMode = .detail
        followZoom = detailZoom
        followMode = .courseUp
        followGeneration += 1
        // Pitch-only nudge when we have no fix yet; otherwise syncFollow recenters.
        if coordinate == nil {
            camera = (UUID(), .applyViewMode)
        }
    }

    /// Enter navigation detail framing (called from planner on Start).
    func beginNavigationCamera() {
        isNavigating = true
        navigationCameraMode = .detail
        followZoom = 16.5
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

    /// PiP tap: swap main map between detail follow and full-route overview.
    func toggleNavigationCameraMode(routeCoordinates: [RouteCoordinate]) {
        guard isNavigating else { return }
        switch navigationCameraMode {
        case .detail:
            navigationCameraMode = .overview
            followMode = .off
            followGeneration += 1
            fit(routeCoordinates)
        case .overview:
            recenterOnUser(at: nil, detailZoom: followZoom)
        }
    }

    /// Web compass: unlock heading-up and ease the map north.
    func resetNorth() {
        if followMode == .courseUp {
            followMode = .northUp
            followGeneration += 1
        }
        camera = (UUID(), .resetNorth)
    }

    /// User panned/rotated the map — drop follow lock (web `followLocked` break).
    func breakFollowFromGesture() {
        guard followMode != .off else { return }
        followMode = .off
        followGeneration += 1
    }

    /// Consolidates per-edge segments into continuous same-surface runs, the way
    /// the web POC merges adjacent edges before painting (`routeDisplaySegments`).
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
                    // Web fallback with no edge geometry: trackClass "connector".
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
