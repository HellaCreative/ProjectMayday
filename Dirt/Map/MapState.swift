import CoreLocation
import Foundation
import Observation
import UIKit

/// Geographic area currently visible in MapLibre. Fuel loading uses this
/// concrete viewport instead of guessing an area from centre + zoom.
struct MapViewportBounds: Equatable, Sendable {
    let minLongitude: Double
    let minLatitude: Double
    let maxLongitude: Double
    let maxLatitude: Double

    init(minLongitude: Double, minLatitude: Double, maxLongitude: Double, maxLatitude: Double) {
        self.minLongitude = min(minLongitude, maxLongitude)
        self.minLatitude = min(minLatitude, maxLatitude)
        self.maxLongitude = max(minLongitude, maxLongitude)
        self.maxLatitude = max(minLatitude, maxLatitude)
    }

    var longitudeSpan: Double { max(0, maxLongitude - minLongitude) }
    var latitudeSpan: Double { max(0, maxLatitude - minLatitude) }

    func expanded(by fraction: Double) -> MapViewportBounds {
        let safeFraction = max(0, fraction)
        let lonPad = max(longitudeSpan * safeFraction, 0.002)
        let latPad = max(latitudeSpan * safeFraction, 0.002)
        return MapViewportBounds(
            minLongitude: max(-180, minLongitude - lonPad),
            minLatitude: max(-90, minLatitude - latPad),
            maxLongitude: min(180, maxLongitude + lonPad),
            maxLatitude: min(90, maxLatitude + latPad)
        )
    }

    func contains(_ other: MapViewportBounds) -> Bool {
        minLongitude <= other.minLongitude
            && minLatitude <= other.minLatitude
            && maxLongitude >= other.maxLongitude
            && maxLatitude >= other.maxLatitude
    }

    func contains(latitude: Double, longitude: Double) -> Bool {
        latitude >= minLatitude && latitude <= maxLatitude
            && longitude >= minLongitude && longitude <= maxLongitude
    }
}

struct RouteDisplaySegment {
    let coordinates: [RouteCoordinate]
    /// Four-family surface key used for selected-route paint.
    let surfaceKey: String
    /// Ferry is a transport connector, not an unknown road surface.
    var isFerry = false
    /// Rider-facing crossing label carried by graph-v3 route segments.
    var crossingLabel: String? = nil
    /// Access is an independent warning channel and must not replace surface.
    var accessUnknown = false
    /// Planner stage that produced this paint run. Diagnostic in Phase 0 and
    /// later carried into the canonical rider-leg feature identity.
    var stageIndex: Int? = nil
    /// Canonical rider leg represented by this paint run. Fuel sub-legs share it.
    var riderLegID: UUID? = nil

    var isDirt: Bool {
        surfaceKey != SurfaceFamily.paved.rawValue
    }
}

/// Single source of truth the SwiftUI layer mutates and the MapLibre
/// representable consumes. Generation counters keep UIKit diffing cheap.
@Observable
final class MapState {
    enum MarkerKind {
        case start
        case stage
        case fuel
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
        /// Rider presence status: riding | flat_tire | dead_battery |
        /// unrepairable | injured | stuck (plus legacy available/breakdown).
        var status: String?
        /// When true, map ignores drag / tap-to-relocate (From here fuel pins).
        var isLocked: Bool = false
    }

    enum CameraCommand {
        case center(latitude: Double, longitude: Double, zoom: Double)
        case fit([RouteCoordinate])
        case applyViewMode
        case resetNorth
        case zoom(Double)
    }

    enum RouteBuildCameraStep {
        case start(RouteCoordinate)
        case completedLeg([RouteCoordinate])
    }

    struct RouteBuildCameraSequence {
        let id: UUID
        var steps: [RouteBuildCameraStep]
    }

    /// Follow locked with course-up vs north-up while following.
    enum FollowMode: Equatable {
        case off
        case northUp
        case courseUp
    }

    private(set) var routeSegments: [RouteDisplaySegment] = []
    private(set) var routeGeneration = 0
    private(set) var plannerMarkers: [Marker] = []
    private(set) var groupMarkers: [Marker] = []
    var markers: [Marker] { plannerMarkers + groupMarkers }
    private(set) var markerGeneration = 0
    private(set) var plannerMarkerGeneration = 0
    private(set) var groupMarkerGeneration = 0
    private(set) var hasFuelReplacementCandidates = false
    private(set) var camera: (id: UUID, command: CameraCommand)?
    /// Ordered camera story for a pin-triggered route build. The coordinator
    /// consumes every step, so fast fuel responses cannot overwrite one another.
    private(set) var routeBuildCameraSequence: RouteBuildCameraSequence?
    /// Bumps when the basemap style URL changes so MapLibre reloads.
    private(set) var styleGeneration = 0
    private(set) var tileSource = ShortbreadTileSource.publicOSM
    private(set) var styleURL: URL = MapStyleCatalog.styleURL(tileSource: .publicOSM)

    func useTileSource(_ source: ShortbreadTileSource, reloadStyle: Bool = true) {
        guard source != tileSource else { return }
        tileSource = source
        if reloadStyle {
            applyBasemapStyleURL(MapStyleCatalog.styleURL(tileSource: source))
        }
    }

    func applyBasemapStyleURL(_ url: URL) {
        guard url != styleURL else { return }
        styleURL = url
        styleGeneration += 1
    }

    func restoreCatalogBasemapStyle() {
        applyBasemapStyleURL(MapStyleCatalog.styleURL(tileSource: tileSource))
    }

    func applySelectedMapStyle(_ id: MapStyleID = MapStyleCatalog.selectedID) {
        applyBasemapStyleURL(MapStyleCatalog.styleURL(for: id, tileSource: tileSource))
    }

    // MARK: - Map viewport (set by Coordinator on regionDidChange)

    /// Current map center; POIManager / NetworkOverlayManager observe this.
    var mapCenter: CLLocationCoordinate2D = AppConfig.overviewCenter
    /// Current map zoom; managers observe for min-zoom gating.
    var mapZoom: Double = AppConfig.overviewZoom
    /// Settled MapLibre viewport. POI loading expands this by a small overscan
    /// so zooming does not swap stations merely because a centre pad changed.
    private(set) var visibleCoordinateBounds: MapViewportBounds?
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

    func updateMapViewport(
        center: CLLocationCoordinate2D,
        zoom: Double,
        bounds: MapViewportBounds
    ) {
        mapCenter = center
        mapZoom = zoom
        if visibleCoordinateBounds != bounds {
            visibleCoordinateBounds = bounds
        }
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

    /// Logo-on GRAPH tendrils. HUD is DEBUG-only; paint runs in every channel.
    var showRoutingGraphDebug = false
    /// GRAPH legend + tendrils default to Access so the logo overlay matches
    /// permissive / verified / unknown / restricted.
    var debugGraphPaintMode: DebugGraphPaintMode = .access
    var debugGraphFeatures: [NetworkLineFeature] = []
    private(set) var debugGraphDataGeneration = 0
    var debugGraphStatus: String?
    var debugGraphCapped = false
    var debugGraphHit: RoutingGraphDebugHit?

    /// Retired BC OSM experiment. Kept so RootView observation still compiles.
    private(set) var bcOSMTileURLTemplate: String?
    private(set) var bcOSMStatusMessage: String?
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

    func updateDebugGraphFeatures(_ features: [NetworkLineFeature], status: String?, capped: Bool) {
        debugGraphFeatures = features
        debugGraphStatus = status
        debugGraphCapped = capped
        debugGraphDataGeneration += 1
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
    /// A deliberate tap on the painted route, separate from an ordinary map tap.
    var onRouteTap: ((UUID, CLLocationCoordinate2D, String) -> Void)?
    var onLongPress: ((CLLocationCoordinate2D) -> Void)?
    var onRiderTap: ((String) -> Void)?
    /// Called as a movable planner pin begins dragging so the planner can
    /// reveal constrained targets (for example alternate route-connected pumps).
    var onPlannerPinDragBegan: ((String) -> Void)?
    /// Called when the user drags a planner pin and releases it.
    /// Arguments: marker ID (e.g. "s0", "e0", "dest") + new map coordinate.
    var onPlannerPinDragEnd: ((String, CLLocationCoordinate2D) -> Void)?
    var onPlannerPinSnapFailed: (() -> Void)?

    /// Currently selected planner pin (tap-to-select, then drag or tap map to move).
    var selectedPlannerPinID: String? {
        didSet {
            guard selectedPlannerPinID != oldValue else { return }
            pinSelectionGeneration += 1
        }
    }
    /// Gesture resolution reads this synchronously so route edits are never queued mid-build.
    var isRouteBuilding = false
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

    /// Exact visibility gate for controls that operate on the painted route.
    /// Waypoints or an in-progress/failed build do not count as a route line.
    var hasDisplayedRoute: Bool {
        routeSegments.contains(where: { $0.coordinates.count >= 2 })
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
        plannerMarkers = new.filter { !$0.kind.isGroupOverlay }
        groupMarkers = new.filter { $0.kind.isGroupOverlay }
        hasFuelReplacementCandidates = plannerMarkers.contains { $0.id.hasPrefix("fuel-target:") }
        plannerMarkerGeneration += 1
        groupMarkerGeneration += 1
        markerGeneration += 1
    }

    func setPlannerMarkers(_ new: [Marker]) {
        plannerMarkers = new.filter { !$0.kind.isGroupOverlay }
        hasFuelReplacementCandidates = plannerMarkers.contains { $0.id.hasPrefix("fuel-target:") }
        plannerMarkerGeneration += 1
        markerGeneration += 1
    }

    func setGroupMarkers(_ new: [Marker]) {
        groupMarkers = new.filter(\.kind.isGroupOverlay)
        groupMarkerGeneration += 1
        markerGeneration += 1
    }

    /// Button zoom keeps the current map centre, bearing, and follow intent.
    func zoomBy(_ delta: Double) {
        let target = min(20, max(2, mapZoom + delta))
        mapZoom = target
        if followMode != .off { followZoom = target }
        camera = (UUID(), .zoom(target))
    }

    func fly(to coordinate: RouteCoordinate, zoom: Double = 13) {
        cancelRouteBuildCamera()
        camera = (UUID(), .center(latitude: coordinate.latitude, longitude: coordinate.longitude, zoom: zoom))
    }

    /// Frame coordinates in view. Releases location-follow so course-up / zoom-lock
    /// cannot yank the camera back after an overview fit (Zoom to Route).
    func fit(_ coordinates: [RouteCoordinate]) {
        cancelRouteBuildCamera()
        stopFollowingForOverview()
        guard coordinates.count > 1 else {
            if let only = coordinates.first { fly(to: only) }
            return
        }
        camera = (UUID(), .fit(coordinates))
    }

    /// Start the leg-by-leg planning camera at the rider's first anchor.
    func beginRouteBuildCamera(at coordinate: RouteCoordinate) {
        stopFollowingForOverview()
        routeBuildCameraSequence = RouteBuildCameraSequence(
            id: UUID(),
            steps: [.start(coordinate)]
        )
    }

    /// Add the exact geometry that just became visible on the map.
    func appendCompletedRouteBuildLeg(_ coordinates: [RouteCoordinate]) {
        guard coordinates.count >= 2, var sequence = routeBuildCameraSequence else { return }
        sequence.steps.append(.completedLeg(coordinates))
        routeBuildCameraSequence = sequence
    }

    /// Rider gestures and deliberate camera controls always win immediately.
    func cancelRouteBuildCamera() {
        routeBuildCameraSequence = nil
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
    static func displaySegments(
        from responses: [RouteResponse],
        riderLegIDs: [UUID?] = []
    ) -> [RouteDisplaySegment] {
        var result: [RouteDisplaySegment] = []
        for (stageIndex, response) in responses.enumerated() {
            let riderLegID = riderLegIDs.indices.contains(stageIndex) ? riderLegIDs[stageIndex] : nil
            let segments = response.segments ?? []
            var currentCoords: [RouteCoordinate] = []
            var currentKey: String?
            var currentIsFerry = false
            var currentCrossingLabel: String?
            var currentAccessUnknown = false
            func flush() {
                if currentCoords.count > 1, let key = currentKey {
                    result.append(
                        RouteDisplaySegment(
                            coordinates: currentCoords,
                            surfaceKey: key,
                            isFerry: currentIsFerry,
                            crossingLabel: currentCrossingLabel,
                            accessUnknown: currentAccessUnknown,
                            stageIndex: stageIndex,
                            riderLegID: riderLegID
                        )
                    )
                }
                currentCoords = []
                currentKey = nil
                currentIsFerry = false
                currentCrossingLabel = nil
                currentAccessUnknown = false
            }
            if segments.isEmpty {
                let coords = response.coordinates
                if coords.count > 1 {
                    // No edge geometry: paint as connector.
                    result.append(
                        RouteDisplaySegment(
                            coordinates: coords,
                            surfaceKey: SurfaceFamily.unknown.rawValue,
                            stageIndex: stageIndex,
                            riderLegID: riderLegID
                        )
                    )
                }
                continue
            }
            for segment in segments {
                let coords = segment.coordinates
                guard !coords.isEmpty else { continue }
                let key = segment.presentationSurfaceFamily(
                    usesSurfaceLeaves: response.stats?.surfaceFamilyMode == "leaf-v3"
                ).rawValue
                let isFerry = segment.structureType?.lowercased() == "ferry"
                let crossingLabel = isFerry
                    ? (segment.crossingLabel?.isEmpty == false ? segment.crossingLabel : "Ferry crossing")
                    : nil
                let accessUnknown = segment.accessClass?.lowercased() == "motorized_unknown"
                if currentKey == key,
                   currentIsFerry == isFerry,
                   currentCrossingLabel == crossingLabel,
                   currentAccessUnknown == accessUnknown {
                    for coordinate in coords where coordinate != currentCoords.last {
                        currentCoords.append(coordinate)
                    }
                } else {
                    flush()
                    currentKey = key
                    currentIsFerry = isFerry
                    currentCrossingLabel = crossingLabel
                    currentAccessUnknown = accessUnknown
                    currentCoords = coords
                }
            }
            flush()
        }
        return result
    }
}
