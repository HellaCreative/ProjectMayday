import CoreLocation
import Foundation
import Observation
import SwiftData

/// Planner state machine covering the web POC's three route-finder modes:
/// From here (GPS → tapped B), Plan a route (chained multi-stage A→B hops,
/// one `/api/route` POST per stage), and Saved (local SwiftData store).
@Observable
final class RoutePlannerModel {
    enum Mode: String, CaseIterable, Identifiable {
        case fromHere = "From here"
        case plan = "Plan a route"
        case saved = "Saved"

        var id: String { rawValue }
    }

    struct Stage: Identifiable {
        let id = UUID()
        var start: RouteCoordinate?
        var end: RouteCoordinate?
        var profile: RouteProfile
        var allowUnknown = false
        var response: RouteResponse?
        var isRouting = false
        var error: String?
        /// Bumped on each `/api/route` for this stage; stale responses are ignored.
        var routeGeneration = 0
    }

    var mode: Mode = .fromHere {
        didSet { modeChanged(from: oldValue) }
    }
    var profile: RouteProfile = .balanced {
        didSet { if oldValue != profile { reroute() } }
    }
    var allowUnknown = false {
        didSet { if oldValue != allowUnknown { reroute() } }
    }
    var showUnknownAck = false

    // From here
    private(set) var destination: RouteCoordinate?
    private(set) var destinationName: String?
    private(set) var fromHereResponse: RouteResponse?

    // Plan
    private(set) var stages: [Stage] = []

    private(set) var isRouting = false
    var errorMessage: String?
    var toast: String?
    /// RootView watches this to open the route planner when a From here pin is dropped.
    var presentRouteCard = false
    private var routeIdentity: String?
    private var lastNavigationIdentity: String?
    /// Invalidates in-flight From here / Saved routes when the rider changes intent.
    private var fromHereRouteGeneration = 0

    private let routing: RoutingClient
    private let locationService: LocationService
    private let mapState: MapState
    let navigation: NavigationSession
    private let offline: OfflineTileManager

    init(
        routing: RoutingClient,
        locationService: LocationService,
        mapState: MapState,
        navigation: NavigationSession,
        offline: OfflineTileManager
    ) {
        self.routing = routing
        self.locationService = locationService
        self.mapState = mapState
        self.navigation = navigation
        self.offline = offline

        navigation.onRerouteNeeded = { [weak self] in
            self?.recalculateFromRider()
        }
        locationService.onLocation = { [weak self] location in
            self?.navigation.update(with: location)
        }
    }

    // MARK: - Aggregate stats

    var activeResponses: [RouteResponse] {
        switch mode {
        case .fromHere, .saved:
            return fromHereResponse.map { [$0] } ?? []
        case .plan:
            return stages.compactMap(\.response)
        }
    }

    var hasRoute: Bool { !activeResponses.isEmpty }

    var totalMeters: Double {
        activeResponses.reduce(0) { $0 + ($1.distanceMeters ?? 0) }
    }

    var aggregateDirtPercent: Int {
        let total = totalMeters
        guard total > 0 else { return 0 }
        let dirtMeters = activeResponses.reduce(0.0) {
            $0 + ($1.distanceMeters ?? 0) * Double($1.dirtPercent) / 100
        }
        return Int((dirtMeters / total * 100).rounded())
    }

    var aggregatePavedPercent: Int {
        hasRoute ? max(0, 100 - aggregateDirtPercent) : 0
    }

    var allCoordinates: [RouteCoordinate] {
        var coords: [RouteCoordinate] = []
        for response in activeResponses {
            for coordinate in response.coordinates where coordinate != coords.last {
                coords.append(coordinate)
            }
        }
        return coords
    }

    var allManeuvers: [RouteManeuver] {
        // Offset stage maneuvers so along-route distances stay monotonic.
        var result: [RouteManeuver] = []
        var offset = 0.0
        for response in activeResponses {
            for maneuver in response.maneuvers ?? [] {
                result.append(maneuver.shiftingAlong(by: offset))
            }
            offset += response.distanceMeters ?? 0
        }
        return result
    }

    // MARK: - Map interaction

    /// From here drops pin B as soon as the rider taps — before `/api/route` returns.
    static let paintsDestinationImmediatelyOnFromHereTap = true
    static let calculatingRouteToast = "Calculating route"

    func handleMapTap(_ coordinate: CLLocationCoordinate2D) {
        guard navigation.phase == .idle else { return }
        let point = RouteCoordinate(longitude: coordinate.longitude, latitude: coordinate.latitude)
        switch mode {
        case .fromHere:
            beginFromHereDestination(point)
        case .plan:
            // Web parity: Plan placement is long-press only. Tap inspects / no-ops.
            break
        case .saved:
            break
        }
    }

    func handleMapLongPress(_ coordinate: CLLocationCoordinate2D) {
        guard navigation.phase == .idle else { return }
        let point = RouteCoordinate(longitude: coordinate.longitude, latitude: coordinate.latitude)
        switch mode {
        case .plan:
            appendPlanPoint(point)
        case .fromHere:
            beginFromHereDestination(point)
        case .saved:
            break
        }
    }

    private func beginFromHereDestination(_ point: RouteCoordinate) {
        destination = point
        destinationName = nil
        presentRouteCard = true
        toast = Self.calculatingRouteToast
        refreshMap()
        Task { await routeFromHere() }
    }

    private func appendPlanPoint(_ point: RouteCoordinate) {
        // New stages always open as Balanced; rider changes per-stage after.
        let stageProfile: RouteProfile = .balanced
        if stages.isEmpty {
            stages.append(Stage(start: point, profile: stageProfile, allowUnknown: false))
        } else if stages[stages.count - 1].end == nil {
            stages[stages.count - 1].end = point
            let index = stages.count - 1
            Task { await routeStage(at: index) }
        } else {
            let previousEnd = stages[stages.count - 1].end
            stages.append(Stage(start: previousEnd, end: point, profile: stageProfile, allowUnknown: false))
            let index = stages.count - 1
            Task { await routeStage(at: index) }
        }
        refreshMap()
    }

    /// Per-stage surface mode (each stage is its own `/api/route` request).
    func setStageProfile(_ newProfile: RouteProfile, at index: Int) {
        guard stages.indices.contains(index), stages[index].profile != newProfile else { return }
        stages[index].profile = newProfile
        if newProfile == .cleanest { stages[index].allowUnknown = false }
        if stages[index].end != nil {
            Task { await routeStage(at: index) }
        }
    }

    /// Per-stage unknown-access policy.
    func setStageAllowUnknown(_ allow: Bool, at index: Int) {
        guard stages.indices.contains(index), stages[index].allowUnknown != allow else { return }
        stages[index].allowUnknown = allow
        if stages[index].end != nil {
            Task { await routeStage(at: index) }
        }
    }

    /// Remove a plan stage. Stitches the next stage onto this stage’s start so
    /// the chain stays continuous (drops the deleted hop’s end pin).
    func deleteStage(at index: Int) {
        guard stages.indices.contains(index) else { return }
        mapState.selectPlannerPin(nil)
        errorMessage = nil
        // Invalidate this stage’s in-flight route before removing it.
        stages[index].routeGeneration += 1
        stages[index].isRouting = false

        if stages.count == 1 {
            stages = []
            routeIdentity = nil
            isRouting = stages.contains(where: \.isRouting)
            refreshMap()
            return
        }

        if index < stages.count - 1 {
            stages[index + 1].start = stages[index].start
            stages[index + 1].response = nil
            stages[index + 1].error = nil
        }

        stages.remove(at: index)

        routeIdentity = "plan:" + stages.compactMap { stage in
            stage.end.map { "\($0.latitude),\($0.longitude)" }
        }.joined(separator: ";")

        refreshMap()

        if index < stages.count, stages[index].end != nil {
            Task { await routeStage(at: index) }
        } else if !stages.isEmpty {
            let coords = allCoordinates
            if coords.count >= 2 {
                mapState.fit(coords)
            }
        }
    }

    // MARK: - Routing

    func routeFromHere() async {
        guard let origin = locationService.currentCoordinate else {
            errorMessage = "Waiting for GPS — allow location access to route from here."
            if toast == Self.calculatingRouteToast { toast = nil }
            return
        }
        guard let requestedDest = destination else { return }

        fromHereRouteGeneration += 1
        let generation = fromHereRouteGeneration
        let requestedProfile = profile
        let requestedAllow = allowUnknown
        let requestedMode = mode

        isRouting = true
        errorMessage = nil
        if toast == nil { toast = Self.calculatingRouteToast }
        defer {
            if generation == fromHereRouteGeneration {
                isRouting = stages.contains(where: \.isRouting)
            }
        }
        do {
            let request = RouteRequest(
                profile: requestedProfile,
                locations: [
                    RouteLocation(latitude: origin.latitude, longitude: origin.longitude, label: "A"),
                    RouteLocation(latitude: requestedDest.latitude, longitude: requestedDest.longitude, label: "B")
                ],
                allowUnknown: requestedAllow
            )
            let response = try await routing.route(request)
            // Drop stale replies — rapid retap / profile / mode / clear can outrun HTTP.
            guard generation == fromHereRouteGeneration,
                  mode == requestedMode,
                  profile == requestedProfile,
                  allowUnknown == requestedAllow,
                  destinationMatches(requestedDest)
            else { return }

            fromHereResponse = response
            // applyRoutedBoundary parity: move the B pin to the geometry endpoint
            // so the marker sits on the road, not at the raw tap coordinate.
            // The server snaps waypoints onto the nearest graph edge; the geometry
            // first/last coordinate is the authoritative snapped position.
            if let snappedEnd = response.coordinates.last {
                destination = snappedEnd
            }
            let finalDest = destination ?? requestedDest
            routeIdentity = "here:\(finalDest.latitude),\(finalDest.longitude):\(requestedProfile.rawValue)"
            refreshMap()
            if let first = response.coordinates.first, let last = response.coordinates.last {
                mapState.fit([first, last])
            } else {
                mapState.fit(response.coordinates)
            }
            presentRouteWarnings(from: [response])
        } catch {
            guard generation == fromHereRouteGeneration else { return }
            fromHereResponse = nil
            errorMessage = error.localizedDescription
            toast = nil
            refreshMap()
        }
    }

    func routeStage(at index: Int) async {
        guard stages.indices.contains(index),
              let start = stages[index].start,
              let end = stages[index].end else { return }

        let stageID = stages[index].id
        stages[index].routeGeneration += 1
        let generation = stages[index].routeGeneration
        let requestedProfile = stages[index].profile
        let requestedAllow = stages[index].allowUnknown

        stages[index].isRouting = true
        stages[index].error = nil
        isRouting = true
        defer {
            if let idx = stages.firstIndex(where: { $0.id == stageID }),
               stages[idx].routeGeneration == generation {
                stages[idx].isRouting = false
            }
            isRouting = stages.contains(where: \.isRouting)
        }
        do {
            let request = RouteRequest(
                profile: requestedProfile,
                locations: [
                    RouteLocation(latitude: start.latitude, longitude: start.longitude, label: "A"),
                    RouteLocation(latitude: end.latitude, longitude: end.longitude, label: "B")
                ],
                allowUnknown: requestedAllow
            )
            let response = try await routing.route(request)
            // Resolve by stable stage id — index may have shifted (delete / reorder).
            guard let idx = stages.firstIndex(where: { $0.id == stageID }),
                  stages[idx].routeGeneration == generation,
                  stages[idx].profile == requestedProfile,
                  stages[idx].allowUnknown == requestedAllow,
                  coordinateMatches(stages[idx].start, start),
                  coordinateMatches(stages[idx].end, end)
            else { return }

            // applyRoutedBoundary parity: snap stage pins to geometry endpoints
            // so markers sit on the road after the server snaps waypoints to the
            // nearest graph edge (mirrors HTML applyRoutedBoundary logic).
            if let snappedStart = response.coordinates.first {
                stages[idx].start = snappedStart
            }
            if let snappedEnd = response.coordinates.last {
                stages[idx].end = snappedEnd
                // Keep adjacent stage boundary in sync.
                if stages.indices.contains(idx + 1) {
                    stages[idx + 1].start = snappedEnd
                }
            }
            stages[idx].response = response
            routeIdentity = "plan:" + stages.compactMap { stage in
                stage.end.map { "\($0.latitude),\($0.longitude)" }
            }.joined(separator: ";")
            refreshMap()
            // Zoom to this stage’s endpoints so A/B (or stage pins) stay readable —
            // fitting the full multi-stage polyline often leaves pins tiny.
            if let fitStart = stages[idx].start, let fitEnd = stages[idx].end {
                mapState.fit([fitStart, fitEnd])
            }
            presentRouteWarnings(from: activeResponses)
        } catch {
            guard let idx = stages.firstIndex(where: { $0.id == stageID }),
                  stages[idx].routeGeneration == generation else { return }
            stages[idx].response = nil
            stages[idx].error = error.localizedDescription
            errorMessage = error.localizedDescription
            refreshMap()
        }
    }

    private func destinationMatches(_ requested: RouteCoordinate) -> Bool {
        guard let current = destination else { return false }
        return coordinateMatches(current, requested)
    }

    private func coordinateMatches(_ a: RouteCoordinate?, _ b: RouteCoordinate?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.latitude - b.latitude) < 1e-7
            && abs(a.longitude - b.longitude) < 1e-7
    }

    /// Invalidate every in-flight planner route (clear / mode convert / wipe).
    private func invalidateInFlightRoutes() {
        fromHereRouteGeneration += 1
        for index in stages.indices {
            stages[index].routeGeneration += 1
            stages[index].isRouting = false
        }
        isRouting = false
    }

    private func reroute() {
        switch mode {
        case .fromHere, .saved:
            if destination != nil {
                Task { await routeFromHere() }
            }
        case .plan:
            // Stages own their mode + access policy — the global default only
            // seeds new stages. Existing stages are edited via setStageProfile.
            break
        }
    }

    /// Mid-trip recalculation: rider position → preserved destination, same
    /// profile and access policy. Offline tiles are kept (web session rule 3).
    func recalculateFromRider() {
        guard navigation.phase == .active,
              let rider = locationService.currentCoordinate else { return }
        let target: RouteCoordinate?
        switch mode {
        case .fromHere, .saved:
            target = destination ?? allCoordinates.last
        case .plan:
            target = stages.last?.end
        }
        guard let target else { return }
        Task {
            do {
                let request = RouteRequest(
                    profile: profile,
                    locations: [
                        RouteLocation(latitude: rider.latitude, longitude: rider.longitude, label: "A"),
                        RouteLocation(latitude: target.latitude, longitude: target.longitude, label: "B")
                    ],
                    allowUnknown: allowUnknown
                )
                let response = try await routing.route(request)
                fromHereResponse = response
                mode = .fromHere
                destination = target
                let display = MapState.displaySegments(from: [response])
                navigation.replaceRoute(
                    coordinates: response.coordinates,
                    maneuvers: response.maneuvers ?? [],
                    segments: display
                )
                refreshMap()
                presentRouteWarnings(from: [response])
            } catch {
                toast = "No verified alternate route found. Backtrack to the last verified junction or end this stage."
            }
        }
    }

    // MARK: - Waypoint drag (map pin drag-to-move)

    /// Called by the map when the user drag-releases a planner pin.
    /// Applies client-side road snap (nearest point on active route within 500 m),
    /// updates the affected stage coordinate(s), and re-routes.
    ///
    /// Snap strategy: project the dropped coordinate onto every segment of the
    /// currently displayed route polyline.  If the nearest point is ≤ 500 m
    /// away we use it; otherwise the raw coordinate is kept.  This mirrors the
    /// HTML `snapPlacementPoint` approach (use loaded network geometry first,
    /// fall back to raw point when nothing is near enough).  Full rendered-layer
    /// snapping (like `queryRenderedFeatures`) is not yet available in
    /// MapLibre Native iOS.
    func moveWaypoint(markerID: String, to rawCoordinate: CLLocationCoordinate2D) {
        guard navigation.phase == .idle else { return }
        let raw = RouteCoordinate(longitude: rawCoordinate.longitude, latitude: rawCoordinate.latitude)
        let snapped = snapToRouteNetwork(raw)
        switch mode {
        case .fromHere:
            guard markerID == "dest" else { return }
            destination = snapped
            refreshMap()
            Task { await routeFromHere() }
        case .saved:
            // Saved overview: B is movable; A is the stored track start (display only).
            guard markerID == "dest" else { return }
            destination = snapped
            refreshMap()
            Task { await routeFromHere() }
        case .plan:
            if markerID == "s0" {
                guard !stages.isEmpty else { return }
                stages[0].start = snapped
                stages[0].response = nil
                refreshMap()
                if stages[0].end != nil { Task { await routeStage(at: 0) } }
            } else if markerID.hasPrefix("e"), let index = Int(markerID.dropFirst()),
                      stages.indices.contains(index) {
                stages[index].end = snapped
                stages[index].response = nil
                // Shared boundary: keep the next stage's start in sync.
                if stages.indices.contains(index + 1) {
                    stages[index + 1].start = snapped
                    stages[index + 1].response = nil
                }
                refreshMap()
                Task { await routeStage(at: index) }
                if stages.indices.contains(index + 1) {
                    let next = index + 1
                    Task { await routeStage(at: next) }
                }
            }
        }
    }

    /// Snaps `point` to the nearest position on the active route polyline
    /// within `maxMeters`.  Returns the raw point unchanged when no route is
    /// loaded or the polyline is farther away.
    private func snapToRouteNetwork(_ point: RouteCoordinate, maxMeters: Double = 500) -> RouteCoordinate {
        let coords = allCoordinates
        guard coords.count > 1 else { return point }
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        guard let result = GeoMath.nearestPointOnPolyline(location, in: coords, maxMeters: maxMeters) else {
            return point
        }
        return result.coordinate
    }

    // MARK: - POI routing (called by RootView POI action sheet)

    /// Route from current GPS position to a POI coordinate.
    /// Mirrors the web POC "Route to this" action on a poi-popup.
    func routeToCoordinate(name: String?, latitude: Double, longitude: Double) {
        let point = RouteCoordinate(longitude: longitude, latitude: latitude)
        mode = .fromHere
        destination = point
        destinationName = name
        presentRouteCard = true
        toast = Self.calculatingRouteToast
        refreshMap()
        Task { await routeFromHere() }
    }

    /// Add a coordinate as the next open plan waypoint.
    /// Mirrors the web POC "Use as waypoint" action when plannerTab == "plan".
    func addPlanWaypoint(latitude: Double, longitude: Double) {
        let point = RouteCoordinate(longitude: longitude, latitude: latitude)
        if mode != .plan { mode = .plan }
        appendPlanPoint(point)
    }

    // MARK: - Clear / mode

    /// From here has a pin and/or a calculated route worth confirming before leaving.
    var hasFromHereDraft: Bool {
        destination != nil || fromHereResponse != nil
    }

    /// Plan has at least one waypoint worth confirming before leaving.
    var hasPlanDraft: Bool {
        !stages.isEmpty
    }

    func clearRoute() {
        if navigation.phase != .idle {
            endNavigation()
        }
        invalidateInFlightRoutes()
        destination = nil
        destinationName = nil
        fromHereResponse = nil
        stages = []
        errorMessage = nil
        routeIdentity = nil
        mapState.selectPlannerPin(nil)
        refreshMap()
    }

    /// Switch tabs without the keep/clear confirmation (Saved, or empty drafts).
    func selectMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
    }

    /// From here → Plan: keep GPS→B (or geometry) as stage 1.
    func switchToPlanKeepingFromHere() {
        invalidateInFlightRoutes()
        let end = destination ?? fromHereResponse?.coordinates.last
        let start = fromHereResponse?.coordinates.first ?? locationService.currentCoordinate
        let keptResponse = fromHereResponse
        let keptProfile = profile
        let keptAllow = allowUnknown

        destination = nil
        destinationName = nil
        fromHereResponse = nil
        errorMessage = nil
        stages = []

        mode = .plan

        guard let start, let end else {
            refreshMap()
            return
        }
        var stage = Stage(start: start, end: end, profile: keptProfile, allowUnknown: keptAllow)
        stage.response = keptResponse
        stages = [stage]
        if keptResponse == nil {
            Task { await routeStage(at: 0) }
        } else {
            routeIdentity = "plan:\(end.latitude),\(end.longitude)"
        }
        refreshMap()
        mapState.fit([start, end])
    }

    /// From here → Plan: discard the From here draft and open an empty plan.
    func switchToPlanClearing() {
        invalidateInFlightRoutes()
        destination = nil
        destinationName = nil
        fromHereResponse = nil
        stages = []
        errorMessage = nil
        routeIdentity = nil
        mapState.selectPlannerPin(nil)
        mode = .plan
        refreshMap()
    }

    /// Plan → From here: use the last plan pin as From here destination B.
    func switchToFromHereUsingLastPin() {
        let lastPin = stages.last?.end
            ?? stages.last?.response?.coordinates.last
            ?? stages.last?.start
        let keptProfile = stages.last?.profile ?? profile
        let keptAllow = stages.last?.allowUnknown ?? false

        invalidateInFlightRoutes()
        stages = []
        errorMessage = nil
        routeIdentity = nil
        mapState.selectPlannerPin(nil)
        profile = keptProfile
        allowUnknown = keptAllow
        mode = .fromHere

        guard let lastPin else {
            destination = nil
            destinationName = nil
            fromHereResponse = nil
            refreshMap()
            return
        }
        beginFromHereDestination(lastPin)
    }

    /// Plan → From here: discard the plan and open empty From here.
    func switchToFromHereClearing() {
        invalidateInFlightRoutes()
        stages = []
        destination = nil
        destinationName = nil
        fromHereResponse = nil
        errorMessage = nil
        routeIdentity = nil
        mapState.selectPlannerPin(nil)
        mode = .fromHere
        refreshMap()
    }

    private func modeChanged(from oldMode: Mode) {
        guard oldMode != mode else { return }
        // Draft clear / convert is explicit via switchTo* helpers or clearRoute.
        // Saved ↔ other tabs only need a repaint.
        errorMessage = nil
        refreshMap()
    }

    // MARK: - Map paint

    func refreshMap() {
        mapState.setRoute(MapState.displaySegments(from: activeResponses))
        var markers: [MapState.Marker] = []
        switch mode {
        case .fromHere:
            if let destination {
                markers.append(
                    MapState.Marker(
                        id: "dest",
                        latitude: destination.latitude,
                        longitude: destination.longitude,
                        label: "B",
                        kind: .destination
                    )
                )
            }
        case .saved:
            // Show both endpoints so a loaded route has visible first + second pins.
            if let start = fromHereResponse?.coordinates.first {
                markers.append(
                    MapState.Marker(
                        id: "start",
                        latitude: start.latitude,
                        longitude: start.longitude,
                        label: "A",
                        kind: .start
                    )
                )
            }
            if let destination {
                markers.append(
                    MapState.Marker(
                        id: "dest",
                        latitude: destination.latitude,
                        longitude: destination.longitude,
                        label: "B",
                        kind: .destination
                    )
                )
            }
        case .plan:
            for (index, stage) in stages.enumerated() {
                if let start = stage.start, index == 0 {
                    markers.append(MapState.Marker(id: "s0", latitude: start.latitude, longitude: start.longitude, label: "A", kind: .start))
                }
                if let end = stage.end {
                    let isLast = index == stages.count - 1
                    markers.append(
                        MapState.Marker(
                            id: "e\(index)",
                            latitude: end.latitude,
                            longitude: end.longitude,
                            label: isLast ? "B" : "\(index + 1)",
                            kind: isLast ? .destination : .stage
                        )
                    )
                }
            }
        }
        let riders = mapState.markers.filter { $0.kind == .rider }
        mapState.setMarkers(markers + riders)
    }

    // MARK: - Save / export

    func saveRoute(named name: String, context: ModelContext) {
        guard hasRoute else { return }
        let route = SavedRoute(
            name: name.isEmpty ? "DIRT route" : name,
            profile: profile,
            coordinates: allCoordinates,
            distanceMeters: totalMeters,
            dirtPercent: aggregateDirtPercent,
            pavedPercent: aggregatePavedPercent
        )
        context.insert(route)
        try? context.save()
        toast = "Route saved"
    }

    func loadSavedRoute(_ saved: SavedRoute) {
        mode = .saved
        applyStoredRouteGeometry(
            name: saved.name,
            coordinates: saved.coordinates,
            distanceMeters: saved.distanceMeters,
            dirtPercent: saved.dirtPercent,
            pavedPercent: saved.pavedPercent,
            identity: "saved:\(saved.id.uuidString)",
            imported: false
        )
    }

    /// Reads a GPX file from the document picker or share sheet, displays the
    /// track on the map, and saves it to SwiftData (web Saved import parity).
    func importGPX(from url: URL, context: ModelContext) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let parsed = try GPXParser.parse(contentsOf: url)
            applyImportedTrack(parsed)
            saveRoute(named: parsed.name, context: context)
            toast = "Imported “\(parsed.name)”"
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            toast = nil
        }
    }

    private func applyImportedTrack(_ track: GPXParser.ParsedTrack) {
        let coords = track.coordinates
        guard coords.count >= 2 else {
            errorMessage = GPXParser.ParseError.noTrackOrRoute.errorDescription
            return
        }
        errorMessage = nil
        applyStoredRouteGeometry(
            name: track.name,
            coordinates: coords,
            distanceMeters: track.distanceMeters,
            dirtPercent: 0,
            pavedPercent: 0,
            identity: "imported:\(UUID().uuidString)",
            imported: true,
            segmentPolylines: track.segments
        )
        presentRouteCard = true
    }

    private func applyStoredRouteGeometry(
        name: String,
        coordinates: [RouteCoordinate],
        distanceMeters: Double,
        dirtPercent: Int,
        pavedPercent: Int,
        identity: String,
        imported: Bool,
        segmentPolylines: [[RouteCoordinate]]? = nil
    ) {
        mode = .saved
        destination = coordinates.last
        destinationName = name
        let segments: [RouteSegment]?
        if imported, let segmentPolylines, !segmentPolylines.isEmpty {
            segments = segmentPolylines.map { polyline in
                RouteSegment(
                    surfaceClass: "imported",
                    trackClass: "imported",
                    distanceMeters: GeoMath.lineMeters(polyline),
                    geometry: polyline,
                    coords: nil,
                    edgeId: nil
                )
            }
        } else {
            segments = nil
        }
        fromHereResponse = RouteResponse(
            status: "complete",
            error: nil,
            message: nil,
            distanceMeters: distanceMeters,
            estimatedMovingSeconds: nil,
            estimatedElapsedSeconds: nil,
            geometry: coordinates,
            segments: segments,
            stats: RouteStats(dirtPercent: dirtPercent, pavedPercent: pavedPercent),
            maneuvers: nil,
            warnings: nil,
            dirtPercentValue: nil,
            pavedPercentValue: nil
        )
        routeIdentity = identity
        refreshMap()
        // Fit the first and last points (A/B), not every polyline vertex —
        // long routes still frame the endpoints so both pins stay visible.
        if let first = coordinates.first, let last = coordinates.last {
            mapState.fit([first, last])
        }
    }

    /// Frame the map on a plan stage’s start + end pins.
    func focusStage(at index: Int) {
        guard stages.indices.contains(index) else { return }
        var points: [RouteCoordinate] = []
        if let start = stages[index].start { points.append(start) }
        if let end = stages[index].end { points.append(end) }
        guard !points.isEmpty else { return }
        mapState.fit(points)
    }

    /// Fit every waypoint / route geometry for the current Plan draft so the
    /// rider can see the whole planned trip without pinch-zooming.
    func focusEntirePlannedRoute() {
        guard mode == .plan else { return }
        let geometry = allCoordinates
        if geometry.count >= 2 {
            mapState.fit(geometry)
            return
        }
        var pins: [RouteCoordinate] = []
        for (index, stage) in stages.enumerated() {
            if let start = stage.start, index == 0 { pins.append(start) }
            if let end = stage.end { pins.append(end) }
        }
        mapState.fit(pins)
    }

    /// True when Plan mode has something worth framing (2+ pins or a route).
    var canFocusEntirePlannedRoute: Bool {
        guard mode == .plan else { return false }
        if allCoordinates.count >= 2 { return true }
        let pinCount = stages.reduce(0) { count, stage in
            count + (stage.start != nil ? 1 : 0) + (stage.end != nil ? 1 : 0)
        }
        // First stage start alone isn't enough — need A+B at minimum.
        return pinCount >= 2
    }

    func gpxFileURL() -> URL? {
        guard hasRoute else { return nil }
        let route = SavedRoute(
            name: destinationName ?? "DIRT \(profile.title) route",
            profile: profile,
            coordinates: allCoordinates,
            distanceMeters: totalMeters,
            dirtPercent: aggregateDirtPercent,
            pavedPercent: aggregatePavedPercent
        )
        let xml = GPXExporter.document(for: route)
        let url = FileManager.default.temporaryDirectory.appending(path: "dirt-route.gpx")
        do {
            try xml.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Navigation

    func startNavigation() {
        guard hasRoute else { return }
        let coords = allCoordinates
        guard coords.count > 1 else { return }
        lastNavigationIdentity = routeIdentity ?? "route"

        locationService.requestAlways()
        locationService.setBackgroundUpdates(true)
        locationService.startUpdates()

        let maneuvers = allManeuvers
        let displaySegments = MapState.displaySegments(from: activeResponses)
        // Activate immediately. Do not call MapLibre offline packs — they abort
        // the process (DatabaseFileSource / std::regex_error) with our style.
        navigation.activate(
            coordinates: coords,
            maneuvers: maneuvers,
            segments: displaySegments,
            stageEndMeters: stageEndAlongMeters()
        )
        mapState.beginNavigationCamera()
        if let coordinate = locationService.currentCoordinate {
            mapState.recenterOnUser(at: coordinate, detailZoom: 16.5)
        }
    }

    /// Along-route meters at each stage destination (for stage ETA labels).
    private func stageEndAlongMeters() -> [Double] {
        switch mode {
        case .fromHere, .saved:
            let total = GeoMath.lineMeters(allCoordinates)
            return total > 0 ? [total] : []
        case .plan:
            var ends: [Double] = []
            var cursor = 0.0
            for stage in stages {
                guard let response = stage.response else { continue }
                let len = response.distanceMeters ?? GeoMath.lineMeters(response.coordinates)
                cursor += len
                ends.append(cursor)
            }
            return ends
        }
    }

    func skipPrefetch() {
        offline.skip()
    }

    func endNavigation() {
        navigation.end()
        mapState.endNavigationCamera()
        locationService.setBackgroundUpdates(false)
    }

    // MARK: - Incident recovery support

    /// The destination the active route is preserving (recovery keeps it).
    var preservedDestination: RouteCoordinate? {
        switch mode {
        case .fromHere, .saved:
            return destination ?? allCoordinates.last
        case .plan:
            return stages.last?.end ?? allCoordinates.last
        }
    }

    /// Matches a report position to the nearest routed segment's network edge
    /// (within 150 m). Nil when the route response carried no edge IDs.
    func edgeIdNear(_ point: RouteCoordinate) -> String? {
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        var best: (meters: Double, edgeId: String)?
        for response in activeResponses {
            for segment in response.segments ?? [] {
                guard let edgeId = segment.edgeId, !edgeId.isEmpty else { continue }
                guard let nearest = GeoMath.nearestVertex(to: location, in: segment.coordinates) else { continue }
                if nearest.meters <= 150, nearest.meters < (best?.meters ?? .infinity) {
                    best = (nearest.meters, edgeId)
                }
            }
        }
        return best?.edgeId
    }

    /// Verified route geometry from the rider's position back to the last
    /// junction maneuver already passed (or the route start). Never a straight
    /// line — this is the existing polyline, reversed.
    func backtrackGeometry() -> (coordinates: [RouteCoordinate], meters: Double)? {
        guard navigation.phase == .active,
              let riderCoordinate = locationService.currentCoordinate else { return nil }
        let coords = navigation.coordinates
        guard coords.count > 1 else { return nil }
        let rider = CLLocation(latitude: riderCoordinate.latitude, longitude: riderCoordinate.longitude)
        guard let nearest = GeoMath.nearestVertex(to: rider, in: coords) else { return nil }
        let cumulative = GeoMath.cumulativeMeters(coords)
        let traveled = cumulative[nearest.index]

        // Last junction-type maneuver behind the rider; fall back to the start.
        let junctionAlong = navigation.maneuvers
            .compactMap(\.alongMeters)
            .filter { $0 < traveled - 20 }
            .max() ?? 0
        guard traveled - junctionAlong > 30 else { return nil }

        let startIndex = cumulative.lastIndex(where: { $0 <= junctionAlong }) ?? 0
        let slice = Array(coords[startIndex...min(nearest.index, coords.count - 1)]).reversed()
        let line = Array(slice)
        guard line.count > 1 else { return nil }
        return (line, traveled - junctionAlong)
    }

    /// Nearest point on the active route (the verified network line).
    func nearestRoutePoint(to point: RouteCoordinate) -> RouteCoordinate? {
        let coords = navigation.phase == .active ? navigation.coordinates : allCoordinates
        guard !coords.isEmpty else { return nil }
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        guard let nearest = GeoMath.nearestVertex(to: location, in: coords) else { return nil }
        return coords[nearest.index]
    }

    /// Applies a confirmed recovery route (detour / return-to-network).
    func applyRecoveryRoute(_ response: RouteResponse) {
        let target = preservedDestination
        fromHereResponse = response
        mode = .fromHere
        destination = target
        let display = MapState.displaySegments(from: [response])
        navigation.replaceRoute(
            coordinates: response.coordinates,
            maneuvers: response.maneuvers ?? [],
            segments: display
        )
        refreshMap()
        toast = "Route replaced"
    }

    /// Applies a confirmed backtrack: the existing verified line, reversed.
    func applyBacktrack(coordinates: [RouteCoordinate]) {
        navigation.replaceRoute(coordinates: coordinates, maneuvers: [], segments: [])
        mapState.setRoute([RouteDisplaySegment(coordinates: coordinates, surfaceKey: "connector")])
        toast = "Backtracking to the last junction"
    }

    // MARK: - Route to member

    func routeToMember(name: String, latitude: Double, longitude: Double) {
        mode = .fromHere
        destination = RouteCoordinate(longitude: longitude, latitude: latitude)
        destinationName = name
        presentRouteCard = true
        toast = Self.calculatingRouteToast
        refreshMap()
        Task { await routeFromHere() }
    }

    /// Surfaces the most actionable `/api/route` warning (unpaved / unknown / pavement).
    private func presentRouteWarnings(from responses: [RouteResponse]) {
        let codesPriority = [
            "unknown_access_used",
            "unavoidable_pavement",
            "unknown_access_enabled",
            "avoided_edges"
        ]
        let warnings = responses.flatMap { $0.warnings ?? [] }
        for code in codesPriority {
            if let match = warnings.first(where: { $0.code == code }),
               let message = match.message, !message.isEmpty {
                toast = message
                return
            }
        }
        let dirt = aggregateDirtPercent
        if dirt >= 25 {
            toast = "\(dirt)% unpaved / adventure surface on this route — stay alert for surface changes."
        } else {
            let km = totalMeters / 1000
            toast = String(format: "Route ready · %.1f km · %d%% dirt", km, dirt)
        }
    }
}
