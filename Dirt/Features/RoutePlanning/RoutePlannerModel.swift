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
        var response: RouteResponse?
        var isRouting = false
        var error: String?
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
                result.append(
                    RouteManeuver(
                        instruction: maneuver.instruction,
                        type: maneuver.type,
                        distanceMeters: maneuver.distanceMeters,
                        alongMeters: (maneuver.alongMeters ?? 0) + offset
                    )
                )
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
        if stages.isEmpty {
            stages.append(Stage(start: point, profile: profile))
        } else if stages[stages.count - 1].end == nil {
            stages[stages.count - 1].end = point
            let index = stages.count - 1
            Task { await routeStage(at: index) }
        } else {
            let previousEnd = stages[stages.count - 1].end
            stages.append(Stage(start: previousEnd, end: point, profile: profile))
            let index = stages.count - 1
            Task { await routeStage(at: index) }
        }
        refreshMap()
    }

    // MARK: - Routing

    func routeFromHere() async {
        guard let origin = locationService.currentCoordinate else {
            errorMessage = "Waiting for GPS — allow location access to route from here."
            if toast == Self.calculatingRouteToast { toast = nil }
            return
        }
        guard let destination else { return }
        isRouting = true
        errorMessage = nil
        if toast == nil { toast = Self.calculatingRouteToast }
        defer { isRouting = false }
        do {
            let request = RouteRequest(
                profile: profile,
                locations: [
                    RouteLocation(latitude: origin.latitude, longitude: origin.longitude, label: "A"),
                    RouteLocation(latitude: destination.latitude, longitude: destination.longitude, label: "B")
                ],
                allowUnknown: allowUnknown
            )
            let response = try await routing.route(request)
            fromHereResponse = response
            routeIdentity = "here:\(destination.latitude),\(destination.longitude):\(profile.rawValue)"
            refreshMap()
            mapState.fit(response.coordinates)
            presentRouteWarnings(from: [response])
        } catch {
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
        stages[index].isRouting = true
        stages[index].error = nil
        isRouting = true
        defer {
            if stages.indices.contains(index) { stages[index].isRouting = false }
            isRouting = stages.contains(where: \.isRouting)
        }
        do {
            let request = RouteRequest(
                profile: stages[index].profile,
                locations: [
                    RouteLocation(latitude: start.latitude, longitude: start.longitude, label: "A"),
                    RouteLocation(latitude: end.latitude, longitude: end.longitude, label: "B")
                ],
                allowUnknown: allowUnknown
            )
            let response = try await routing.route(request)
            guard stages.indices.contains(index) else { return }
            stages[index].response = response
            routeIdentity = "plan:" + stages.compactMap { stage in
                stage.end.map { "\($0.latitude),\($0.longitude)" }
            }.joined(separator: ";")
            refreshMap()
            let coords = allCoordinates
            if !coords.isEmpty { mapState.fit(coords) }
            presentRouteWarnings(from: activeResponses)
        } catch {
            guard stages.indices.contains(index) else { return }
            stages[index].response = nil
            stages[index].error = error.localizedDescription
            errorMessage = error.localizedDescription
            refreshMap()
        }
    }

    private func reroute() {
        switch mode {
        case .fromHere, .saved:
            if destination != nil {
                Task { await routeFromHere() }
            }
        case .plan:
            for index in stages.indices where stages[index].end != nil {
                stages[index].profile = profile
                Task { await routeStage(at: index) }
            }
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

    // MARK: - Clear / mode

    func clearRoute() {
        if navigation.phase != .idle {
            endNavigation()
        }
        destination = nil
        destinationName = nil
        fromHereResponse = nil
        stages = []
        errorMessage = nil
        routeIdentity = nil
        refreshMap()
    }

    private func modeChanged(from oldMode: Mode) {
        guard oldMode != mode else { return }
        // Web parity: From here is ephemeral — re-entering the tab clears it.
        if mode == .fromHere {
            destination = nil
            destinationName = nil
            fromHereResponse = nil
        }
        errorMessage = nil
        refreshMap()
    }

    // MARK: - Map paint

    func refreshMap() {
        mapState.setRoute(MapState.displaySegments(from: activeResponses))
        var markers: [MapState.Marker] = []
        switch mode {
        case .fromHere, .saved:
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
        let coords = saved.coordinates
        destination = coords.last
        destinationName = saved.name
        fromHereResponse = RouteResponse(
            status: "complete",
            error: nil,
            message: nil,
            distanceMeters: saved.distanceMeters,
            estimatedMovingSeconds: nil,
            estimatedElapsedSeconds: nil,
            geometry: coords,
            segments: nil,
            stats: RouteStats(dirtPercent: saved.dirtPercent, pavedPercent: saved.pavedPercent),
            maneuvers: nil,
            warnings: nil,
            dirtPercentValue: nil,
            pavedPercentValue: nil
        )
        routeIdentity = "saved:\(saved.id.uuidString)"
        refreshMap()
        mapState.fit(coords)
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
            segments: displaySegments
        )
        mapState.followUser = true
    }

    func skipPrefetch() {
        offline.skip()
    }

    func endNavigation() {
        navigation.end()
        mapState.followUser = false
        locationService.setBackgroundUpdates(false)
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
