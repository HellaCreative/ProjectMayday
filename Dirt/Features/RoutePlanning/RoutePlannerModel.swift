import CoreLocation
import Foundation
import Observation
import SwiftData
import UIKit

/// Planner state machine covering three route-finder modes:
/// From here (GPS → point 2), Plan a route (chained ordered waypoint hops),
/// and Saved (local SwiftData store). Live `/api/route` is always authoritative
/// while online. Start Navigation downloads the published regional packs needed
/// for no-signal recovery; installed packs route only while offline.
@Observable
final class RoutePlannerModel {
    enum Mode: String, CaseIterable, Identifiable {
        case fromHere = "From here"
        case plan = "Plan a route"
        case saved = "Saved"

        var id: String { rawValue }
    }

    struct Stage: Identifiable {
        let id: String
        let riderLegID: UUID
        let start: RouteCoordinate?
        let end: RouteCoordinate?
        let profile: RouteProfile
        let allowUnknown: Bool
        let response: RouteResponse?
        let isRouting: Bool
        let error: String?
        let endsAtFuelStop: Bool
        let fuelStopID: String?
        let fuelStopName: String?
        let fuelIdentity: UUID?
        let fuelGroupID: UUID?
        let maxRouteMeters: Double?

        init(
            builtLeg: BuiltLeg,
            riderLeg: RiderLeg,
            status: LegStatus,
            isFuelExpanded: Bool,
            profile: RouteProfile,
            allowUnknown: Bool
        ) {
            riderLegID = riderLeg.id
            start = builtLeg.fromCoordinate
            end = builtLeg.toCoordinate
            self.profile = profile
            self.allowUnknown = allowUnknown
            response = builtLeg.response
            if case .pending = status { isRouting = true } else { isRouting = false }
            if case .failed(let message) = status { error = message } else { error = nil }
            endsAtFuelStop = builtLeg.endsAtFuelStop != nil
            fuelStopID = builtLeg.endsAtFuelStop?.stationID
            fuelStopName = builtLeg.endsAtFuelStop?.name
            fuelIdentity = builtLeg.endsAtFuelStop?.id
            fuelGroupID = isFuelExpanded ? riderLeg.id : nil
            maxRouteMeters = nil
            if let identity = builtLeg.endsAtFuelStop?.id {
                id = identity.uuidString
            } else {
                let suffix = builtLeg.endsAtFuelStop?.stationID
                    ?? "\(builtLeg.toCoordinate.latitude),\(builtLeg.toCoordinate.longitude)"
                id = "\(riderLeg.id.uuidString):\(suffix)"
            }
        }
    }

    var mode: Mode = .fromHere {
        didSet { modeChanged(from: oldValue) }
    }
    var profile: RouteProfile = .dirt {
        didSet {
            guard oldValue != profile else { return }
            if !suppressPlannerReroute, profile == .cleanest {
                suppressPlannerReroute = true
                allowUnknown = false
                suppressPlannerReroute = false
            }
            syncNetworkAccessPolicy()
            reroute()
        }
    }
    var allowUnknown = false {
        didSet {
            if oldValue != allowUnknown {
                syncNetworkAccessPolicy()
                reroute()
            }
        }
    }
    var showUnknownAck = false

    // From here
    private(set) var destination: RouteCoordinate?
    private(set) var destinationName: String?
    private(set) var fromHereResponse: RouteResponse?
    /// Next short-tap places point 1 (GPS was off the routing graph).
    private(set) var fromHereNeedsStartPin = false
    /// Mapped-road start replacing GPS until Clear route.
    private(set) var fromHereStartOverride: RouteCoordinate?

    // Canonical rider intent and its disposable routed projection.
    private(set) var itinerary = RiderItinerary()
    private(set) var built: BuiltItinerary?
    var stages: [Stage] {
        guard let built else { return [] }
        let riderLegs = Dictionary(uniqueKeysWithValues: itinerary.legs.map { ($0.id, $0) })
        let counts = Dictionary(grouping: built.legs, by: \.riderLegID).mapValues(\.count)
        var sequenceByLeg: [UUID: Int] = [:]
        return built.legs.compactMap { builtLeg in
            guard let riderLeg = riderLegs[builtLeg.riderLegID] else { return nil }
            let sequence = sequenceByLeg[builtLeg.riderLegID, default: 0]
            sequenceByLeg[builtLeg.riderLegID] = sequence + 1
            let policy = itinerary.hopPolicy(riderLeg: riderLeg, sequence: sequence)
            return Stage(
                builtLeg: builtLeg,
                riderLeg: riderLeg,
                status: built.riderLegStatus[riderLeg.id] ?? .pending,
                isFuelExpanded: (counts[riderLeg.id] ?? 0) > 1,
                profile: policy.profile,
                allowUnknown: policy.allowUnknown
            )
        }
    }

    /// When true, `profile` / `allowUnknown` didSet skips `reroute()`.
    @ObservationIgnored private var suppressPlannerReroute = false
    /// Coalesce profile / Allow toggles so we don't fire 6 parallel Dijkstras.
    @ObservationIgnored private var rerouteCoalesceTask: Task<Void, Never>?
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var moveDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var pendingMove: (waypointID: UUID, coordinate: RouteCoordinate, source: String)?
    @ObservationIgnored private(set) var canonicalBuildStartCount = 0
    @ObservationIgnored private(set) var lastCanonicalBuildFromLegIndex: Int?
    /// Debounce From here point-2/point-1 retaps while the rider is adjusting the pin.
    @ObservationIgnored private var fromHereRouteDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var fromHereIntentGeneration = 0

    private(set) var isRouting = false
    var errorMessage: String?
    /// Non-destructive fuel recovery/status shown in the compact fuel summary.
    private(set) var fuelPlanNotice: String?
    /// Persistent, specific progress for multi-request fuel planning. Unlike a
    /// toast, this remains visible for the full operation and survives tab hops.
    private(set) var fuelPlanningStatus: String?
    /// Tentative, route-connected pumps revealed as the chain search advances.
    private var fuelPreviewStops: [RouteCoordinate] = []
    private(set) var replacingFuelStopID: UUID?
    private(set) var fuelReplacementCandidates: [FuelAlternate] = []
    /// Transient status capsule. Non-calculating toasts auto-clear.
    var toast: String? {
        didSet {
            guard toast != oldValue else { return }
            toastDismissTask?.cancel()
            toastDismissTask = nil
            guard let message = toast, message != Self.calculatingRouteToast else { return }
            let shown = message
            let seconds: Double = {
                if message.localizedCaseInsensitiveContains("PACKS") { return 4.5 }
                if message.localizedCaseInsensitiveContains("pack ready") { return 3.0 }
                if message.localizedCaseInsensitiveContains("fuel") { return 4.0 }
                return 1.0
            }()
            toastDismissTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                if self.toast == shown {
                    self.toast = nil
                }
            }
        }
    }
    @ObservationIgnored private var toastDismissTask: Task<Void, Never>?
    /// RootView watches this to open the route planner when a From here pin is dropped.
    var presentRouteCard = false
    private var routeIdentity: String?
    /// The library record currently on the map. Deliberately survives "Continue planning"
    /// so that saving an edited route writes back to it instead of forking a second copy.
    private(set) var savedRouteOrigin: SavedRouteOrigin?
    private var lastNavigationIdentity: String?
    private let routing: RoutingClient
    private let locationService: LocationService
    private let mapState: MapState
    let navigation: NavigationSession
    private let offline: OfflineTileManager
    private let graphPacks: GraphPackStore
    private let network: NetworkPathMonitor
    private let itineraryBuilder: ItineraryBuilder
    private let routingSourcePolicy: RoutingSourcePolicy
    private weak var poiManager: POIManager?
    /// Wired by AppEnvironment — restore Music volume after End Navigation.
    /// Fires after nav teardown. Argument is a contribute candidate when enough
    /// network edges were ridden (caller shows opt-in UI).
    @ObservationIgnored var onNavigationEnded: ((RideContributionCandidate?) -> Void)?

    init(
        routing: RoutingClient,
        locationService: LocationService,
        mapState: MapState,
        navigation: NavigationSession,
        offline: OfflineTileManager,
        graphPacks: GraphPackStore,
        network: NetworkPathMonitor,
        poiManager: POIManager? = nil,
        routingSourcePolicy: RoutingSourcePolicy? = nil,
        itineraryBuilder: ItineraryBuilder? = nil
    ) {
        self.routing = routing
        self.locationService = locationService
        self.mapState = mapState
        self.navigation = navigation
        self.offline = offline
        self.graphPacks = graphPacks
        self.network = network
        self.poiManager = poiManager
        self.itineraryBuilder = itineraryBuilder ?? ItineraryBuilder()
        if let routingSourcePolicy {
            self.routingSourcePolicy = routingSourcePolicy
        } else {
            let cache = RouteResponseCache()
            let live = LiveRoutingSource(
                client: routing,
                cache: cache,
                packRevision: { [graphPacks] in graphPacks.lastManifestVersion }
            )
            let pack = PackRoutingSource(packs: graphPacks, cache: cache)
            self.routingSourcePolicy = RoutingSourcePolicy(
                network: network, packs: graphPacks, live: live, pack: pack
            )
        }

        navigation.onRerouteNeeded = { [weak self] in
            guard let self else { return }
            self.recalculateFromRider(networkOnline: self.network.isOnline)
        }
        locationService.onLocation = { [weak self] location in
            guard let self else { return }
            self.navigation.update(with: location)
            self.considerAutoDownloadWhileRiding(at: location.coordinate)
        }
        graphPacks.onQuietPackReady = { [weak self] message in
            self?.toast = message
        }
        mapState.fromHereLongPressRelocatesDestination = true
    }

    /// Wired after `POIManager` exists (composition root creates planner first).
    func attachPOIManager(_ manager: POIManager) {
        poiManager = manager
    }

    // MARK: - Aggregate stats

    var activeResponses: [RouteResponse] {
        switch mode {
        case .fromHere, .plan:
            return built?.legs.map(\.response) ?? []
        case .saved:
            return fromHereResponse.map { [$0] } ?? []
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

    var hasFuelAssistedPlan: Bool {
        fuelStopCount > 0 && stages.count > 1
    }

    var fuelStopCount: Int { stages.filter(\.endsAtFuelStop).count }

    var completedFuelLegCount: Int { stages.filter { $0.response != nil }.count }

    var longestFuelLegMeters: Double {
        stages.compactMap { $0.response?.distanceMeters }.max() ?? 0
    }

    var fuelUsableRangeKm: Double {
        FuelRangePrefs.usableKilometers(for: FuelRangePrefs.kilometers)
    }

    var fuelReserveMarginKm: Double {
        max(0, fuelUsableRangeKm - longestFuelLegMeters / 1000)
    }

    var fuelSurfaceNoticeCount: Int {
        stages.indices.filter { profileAvailabilityNotice(at: $0) != nil }.count
    }

    func stageEndpointTitle(at index: Int) -> String {
        guard stages.indices.contains(index) else { return "Leg \(index + 1)" }
        let stage = stages[index]
        let startName: String
        if index > 0, stages[index - 1].endsAtFuelStop {
            if let prior = stages[index - 1].fuelStopName, !prior.isEmpty {
                startName = prior
            } else {
                let fuelOrdinal = stages.prefix(index).filter(\.endsAtFuelStop).count
                startName = "Fuel stop \(fuelOrdinal)"
            }
        } else {
            let ordinal = itinerary.waypoints.firstIndex(where: { $0.id == itinerary.legs.first(where: { $0.id == stage.riderLegID })?.from })
                .map { $0 + 1 } ?? 1
            startName = "Point \(ordinal)"
        }
        let endName: String
        if let fuel = stages[index].fuelStopName, !fuel.isEmpty {
            endName = fuel
        } else if stages[index].endsAtFuelStop {
            let fuelOrdinal = stages.prefix(index + 1).filter(\.endsAtFuelStop).count
            endName = "Fuel stop \(fuelOrdinal)"
        } else {
            let ordinal = itinerary.waypoints.firstIndex(where: { $0.id == itinerary.legs.first(where: { $0.id == stage.riderLegID })?.to })
                .map { $0 + 1 } ?? (index + 2)
            endName = "Point \(ordinal)"
        }
        return "\(startName) → \(endName)"
    }

    /// Automatic pump hops are derived safety stops. The final non-fuel hop in
    /// each group represents the rider-created leg and is the row that may be
    /// removed from the plan.
    func canDeleteStage(at index: Int) -> Bool {
        stages.indices.contains(index) && !stages[index].endsAtFuelStop
    }

    func fuelMarginText(at index: Int) -> String? {
        guard stages.indices.contains(index),
              stages[index].fuelGroupID != nil,
              let meters = stages[index].response?.distanceMeters,
              FuelRangePrefs.isEnabled
        else { return nil }
        let margin = FuelRangePrefs.usableKilometers(for: FuelRangePrefs.kilometers) - meters / 1000
        if margin >= 0 {
            return "\(Int(margin.rounded())) km before reserve"
        }
        return "\(Int(abs(margin).rounded())) km beyond usable range"
    }

    /// A connected result may still fall short of the selected profile's promise.
    /// Surface truth stays visible rather than silently relabeling the leg.
    func profileAvailabilityNotice(at index: Int) -> String? {
        guard stages.indices.contains(index), let response = stages[index].response else { return nil }
        let dirt = response.dirtPercent
        let paved = response.pavedPercent
        switch stages[index].profile {
        case .cleanest where dirt >= 10:
            return "Clean: \(dirt)% dirt / \(paved)% paved — the most paved connected option for this leg."
        case .balanced where dirt < 40 || dirt > 60:
            return "Balanced: \(dirt)% dirt / \(paved)% paved — the closest connected mix for this leg."
        case .dirt where dirt < 50:
            return "Dirt: \(dirt)% dirt / \(paved)% paved — connected dirt is limited on this leg."
        default:
            return nil
        }
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

    /// The only mutation door for rider-owned route intent.
    func apply(_ action: ItineraryAction, source: String) {
        if case .move(let waypointID, let coordinate) = action {
            pendingMove = (waypointID, coordinate, source)
            moveDebounceTask?.cancel()
            moveDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(420))
                guard !Task.isCancelled,
                      let self,
                      let pending = self.pendingMove,
                      pending.waypointID == waypointID
                else { return }
                self.pendingMove = nil
                self.applyImmediately(
                    .move(waypointID: pending.waypointID, to: pending.coordinate),
                    source: pending.source
                )
            }
            return
        }
        moveDebounceTask?.cancel()
        pendingMove = nil
        applyImmediately(action, source: source)
    }

    private func applyImmediately(_ action: ItineraryAction, source: String) {
        if case .replaceFuelStop = action {
        } else if replacingFuelStopID != nil || !fuelReplacementCandidates.isEmpty {
            replacingFuelStopID = nil
            fuelReplacementCandidates = []
        }
        let before = itinerary
        let change = reduce(before, action)
        guard change.itinerary != before else { return }
        itinerary = change.itinerary
        RoutingDebugLog.shared.event(
            ItineraryLog.line(action: action, before: before, after: itinerary, source: source)
        )
        buildTask?.cancel()
        itineraryBuilder.setCurrentGeneration(itinerary.generation)

        // Navigation recovery already owns the rider-position → active-leg-end
        // request. Record the blocked edges canonically, preserve the visible
        // itinerary, and let applyRecoveryRoute commit that current-position leg.
        if case .markImpassable = action, navigation.phase == .active {
            if let current = built {
                built = BuiltItinerary(
                    generation: itinerary.generation,
                    legs: current.legs,
                    riderLegStatus: current.riderLegStatus
                )
            }
            isRouting = false
            refreshMap()
            return
        }

        guard let fromLeg = change.rebuildFromLegIndex else {
            built = BuiltItinerary.empty(for: itinerary)
            isRouting = false
            refreshMap()
            return
        }
        startCanonicalBuild(
            from: fromLeg,
            fromFuelSequence: change.rebuildFromFuelSequence,
            preserveFuelStops: change.preserveFuelStops,
            reuse: built
        )
    }

    private func startCanonicalBuild(
        from legIndex: Int,
        fromFuelSequence: Int = 0,
        preserveFuelStops: Bool = false,
        reuse: BuiltItinerary?
    ) {
        let requested = itinerary
        canonicalBuildStartCount += 1
        lastCanonicalBuildFromLegIndex = legIndex
        isRouting = true
        isAssemblingRoute = true
        fuelPlanningStatus = FuelRangePrefs.isEnabled ? "Planning fuel legs…" : nil
        toast = Self.calculatingRouteToast
        refreshMap()
        buildTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.itineraryBuilder.build(
                requested,
                from: legIndex,
                fromFuelSequence: fromFuelSequence,
                preserveFuelStops: preserveFuelStops,
                reuse: reuse,
                fuel: FuelRangePrefs.snapshot,
                source: self.routingSourcePolicy
            ) { [weak self] progress in
                guard let self, self.itinerary.generation == progress.generation else { return }
                self.built = progress
                self.refreshMap()
            }
            guard !Task.isCancelled, self.itinerary.generation == result.generation else { return }
            self.built = result
            self.isRouting = false
            self.isAssemblingRoute = false
            self.fuelPlanningStatus = nil
            self.errorMessage = result.riderLegStatus.values.compactMap {
                if case .failed(let message) = $0 { return message }
                return nil
            }.first
            if self.errorMessage == nil {
                self.routeIdentity = "plan:" + self.itinerary.waypoints.dropFirst().map {
                    "\($0.coordinate.latitude),\($0.coordinate.longitude)"
                }.joined(separator: ";")
                self.announceRouteReadyIfComplete()
            } else if self.toast == Self.calculatingRouteToast {
                self.toast = nil
            }
            self.syncFuelAnchors(from: result)
            self.refreshMap()
        }
    }

    private func seedCanonicalBuild(
        coordinates: [RouteCoordinate],
        profile: RouteProfile,
        allowUnknown: Bool,
        responses: [RouteResponse]
    ) {
        let before = itinerary
        itinerary = reduce(
            before,
            .replaceAll(waypoints: coordinates, profile: profile, allowUnknown: allowUnknown)
        ).itinerary
        var legs: [BuiltLeg] = []
        for index in responses.indices where itinerary.legs.indices.contains(index) {
            legs.append(BuiltLeg(
                riderLegID: itinerary.legs[index].id,
                fromCoordinate: itinerary.waypoints[index].coordinate,
                toCoordinate: itinerary.waypoints[index + 1].coordinate,
                endsAtFuelStop: nil,
                response: responses[index],
                fuelUsedOnArrivalMeters: responses[index].distanceMeters ?? 0
            ))
        }
        built = BuiltItinerary(
            generation: itinerary.generation,
            legs: legs,
            riderLegStatus: Dictionary(uniqueKeysWithValues: itinerary.legs.map { riderLeg in
                (riderLeg.id, legs.contains(where: { $0.riderLegID == riderLeg.id }) ? .built : .pending)
            })
        )
        RoutingDebugLog.shared.event(
            ItineraryLog.line(
                action: .replaceAll(waypoints: coordinates, profile: profile, allowUnknown: allowUnknown),
                before: before,
                after: itinerary,
                source: "seed"
            )
        )
    }

    func waitForCanonicalBuildForTesting() async {
        await buildTask?.value
    }

    /// From here drops point 2 as soon as the rider taps — before on-device routing returns.
    static let paintsDestinationImmediatelyOnFromHereTap = true
    static let calculatingRouteToast = "Calculating route"
    static let routeReadyToast = "Route successful"

    /// True while From here / Plan is still building the full route
    /// (including chained fuel stops). Holds calculating toast + spinner.
    private var isAssemblingRoute = false
    /// Stable within this app process; a fresh launch can pick a different near-equal corridor.
    let planningSessionSeed: UInt64 = UInt64.random(in: 1...9_007_199_254_740_991)

    func handleMapTap(_ coordinate: CLLocationCoordinate2D) {
        guard navigation.phase == .idle else { return }
        if replacingFuelStopID != nil {
            cancelFuelReplacement()
            return
        }
        let point = RouteCoordinate(longitude: coordinate.longitude, latitude: coordinate.latitude)
        switch mode {
        case .fromHere:
            // First pin: short tap point 2. After off-graph GPS recovery: tap point 1.
            // Relocate point 2: long-press only (road-snapped).
            // Only needsStartPin steals short taps for point 1 — a sticky start override
            // must not block placing / replacing point 2.
            guard !hasRoute else { return }
            if fromHereNeedsStartPin {
                beginFromHereStartOverride(point)
            } else {
                beginFromHereDestination(point)
            }
        case .plan, .saved:
            break
        }
    }

    /// A short tap directly on a painted Plan route inserts a rider waypoint
    /// into that exact leg. The new pin is selected immediately so it can be
    /// dragged to shape the ride; fuel stops are then safely re-seated around it.
    func handleRouteTap(
        _ coordinate: CLLocationCoordinate2D,
        riderLegID: UUID? = nil,
        source: String = "tap"
    ) {
        guard navigation.phase == .idle,
              mode == .plan,
              !isRouting,
              fuelPlanningStatus == nil,
              !stages.isEmpty
        else { return }

        let probe = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var nearest: (index: Int, point: RouteCoordinate, meters: Double)?
        for (index, stage) in stages.enumerated() {
            if let riderLegID, stage.riderLegID != riderLegID { continue }
            guard let response = stage.response,
                  let hit = GeoMath.nearestPointOnPolyline(
                    probe,
                    in: response.coordinates,
                    maxMeters: 2_000
                  )
            else { continue }
            if nearest == nil || hit.meters < nearest!.meters {
                nearest = (index, hit.coordinate, hit.meters)
            }
        }
        guard let nearest else { return }
        let resolvedRiderLegID = stages[nearest.index].riderLegID
        apply(.insert(afterLegID: resolvedRiderLegID, coordinate: nearest.point), source: source)
        guard let insertedIndex = itinerary.legs.firstIndex(where: { $0.id == resolvedRiderLegID }),
              itinerary.waypoints.indices.contains(insertedIndex + 1)
        else { return }
        mapState.selectPlannerPin("wp:\(itinerary.waypoints[insertedIndex + 1].id.uuidString)")
        toast = "Waypoint added — drag it to shape this leg"
        RoutingDebugLog.shared.event(
            "ui route waypoint inserted stage=\(nearest.index) offset=\(Int(nearest.meters))m"
        )
    }

    func handleMapLongPress(_ coordinate: CLLocationCoordinate2D) {
        guard navigation.phase == .idle else { return }
        let point = RouteCoordinate(longitude: coordinate.longitude, latitude: coordinate.latitude)
        switch mode {
        case .plan:
            appendPlanPoint(point)
        case .fromHere:
            // Place or relocate B — coordinate is road-snapped by MapLibre.
            beginFromHereDestination(point)
        case .saved:
            break
        }
    }

    private func beginFromHereDestination(_ point: RouteCoordinate) {
        buildTask?.cancel()
        built = nil
        itinerary = RiderItinerary()
        fromHereResponse = nil
        // New intent — this is not the library route that may have been on the map.
        savedRouteOrigin = nil
        destination = point
        destinationName = nil
        // Keep start override when relocating B; GPS recovery may still need it.
        presentRouteCard = true
        isAssemblingRoute = true
        errorMessage = nil
        toast = Self.calculatingRouteToast
        mapState.selectPlannerPin(nil)
        mapState.fromHereLongPressRelocatesDestination = true
        refreshMap()
        scheduleFromHereRoute()
    }

    /// Off-graph GPS recovery: place or move point 1 on a mapped road, then route point 1→2.
    private func beginFromHereStartOverride(_ point: RouteCoordinate) {
        guard destination != nil else { return }
        buildTask?.cancel()
        built = nil
        itinerary = RiderItinerary()
        fromHereResponse = nil
        fromHereStartOverride = point
        fromHereNeedsStartPin = false
        presentRouteCard = true
        isAssemblingRoute = true
        errorMessage = nil
        toast = Self.calculatingRouteToast
        mapState.selectPlannerPin(nil)
        mapState.fromHereLongPressRelocatesDestination = true
        refreshMap()
        scheduleFromHereRoute()
    }

    /// Wait for pin settles before Dijkstra — rapid retaps were stacking routes.
    private func scheduleFromHereRoute() {
        fromHereRouteDebounceTask?.cancel()
        fromHereRouteDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 380_000_000)
            guard !Task.isCancelled else { return }
            await routeFromHere()
        }
    }

    private func appendPlanPoint(_ point: RouteCoordinate) {
        apply(.append(coordinate: point), source: "longPress")
    }

    /// Per-stage surface mode (each visible hop is its own routing request).
    func setStageProfile(_ newProfile: RouteProfile, at index: Int) {
        guard stages.indices.contains(index) else { return }
        let stage = stages[index]
        if stage.fuelGroupID != nil {
            apply(
                .setHopProfile(
                    id: hopAnchorID(for: stage),
                    riderLegID: stage.riderLegID,
                    sequence: hopSequence(at: index),
                    newProfile
                ),
                source: "card"
            )
        } else {
            apply(.setProfile(legID: stage.riderLegID, newProfile), source: "card")
        }
    }

    /// Per-stage unknown-access policy.
    func setStageAllowUnknown(_ allow: Bool, at index: Int) {
        guard stages.indices.contains(index) else { return }
        let stage = stages[index]
        if stage.fuelGroupID != nil {
            apply(
                .setHopAllowUnknown(
                    id: hopAnchorID(for: stage),
                    riderLegID: stage.riderLegID,
                    sequence: hopSequence(at: index),
                    allow
                ),
                source: "card"
            )
        } else {
            apply(.setAllowUnknown(legID: stage.riderLegID, allow), source: "card")
        }
    }

    private func hopSequence(at index: Int) -> Int {
        let legID = stages[index].riderLegID
        return stages.prefix(index).filter { $0.riderLegID == legID }.count
    }

    private func hopAnchorID(for stage: Stage) -> UUID {
        stage.fuelIdentity ?? stage.riderLegID
    }

    static func fuelProfileFailureMessage(
        requestedProfile: RouteProfile,
        priorProfile: RouteProfile,
        legName: String,
        usableRangeKm: Double,
        allowUnknown: Bool
    ) -> String {
        let unknownHint = allowUnknown ? "" : " Turning on Allow unknown may expose another connected option."
        return "No route-connected \(requestedProfile.title) fuel chain fits the \(Int(usableRangeKm.rounded())) km usable range. \(priorProfile.title) can connect \(legName), so the working \(priorProfile.title) plan was kept. The eligible OSM network may require pavement or a different station. Increase range, reduce reserve, or add a manual fuel stop.\(unknownHint)"
    }


    /// Remove the rider-created leg represented by this row. Fuel-expanded
    /// hops are collapsed first so deleting a leg can never strand an F pin or
    /// promote a generated pump into the route destination.
    func deleteStage(at index: Int) {
        guard canDeleteStage(at: index) else { return }
        guard stages.indices.contains(index),
              let legIndex = itinerary.legs.firstIndex(where: { $0.id == stages[index].riderLegID })
        else { return }
        mapState.selectPlannerPin(nil)
        apply(.delete(waypointID: itinerary.waypoints[legIndex + 1].id), source: "card")
    }

    func canDeleteFuelStop(_ id: UUID) -> Bool {
        _ = id
        return false
    }

    func handleFuelMarkerTap(_ markerID: String) {
        guard let id = Self.fuelStopID(fromMarker: markerID) else { return }
        Task { await beginFuelReplacement(id: id) }
    }

    func beginFuelReplacement(id: UUID) async {
        guard navigation.phase == .idle,
              let context = fuelReplacementContext(id: id)
        else { return }
        replacingFuelStopID = id
        mapState.selectPlannerPin(Self.fuelMarkerID(id))
        let request = FuelAlternateRequest(
            profile: context.profile,
            allowUnknown: context.allowUnknown,
            previous: context.previous,
            next: context.next,
            usableRangeMeters: context.usable,
            previousCapMeters: context.previousCap,
            currentStationID: context.stationID
        )
        let routeReq = RouteRequest(
            profile: context.profile,
            locations: [
                RouteLocation(latitude: context.previous.latitude, longitude: context.previous.longitude, label: "Point 1"),
                RouteLocation(latitude: context.next.latitude, longitude: context.next.longitude, label: "Point 2")
            ],
            allowUnknown: context.allowUnknown
        )
        var candidates: [FuelAlternate] = []
        do {
            candidates = try await routingSourcePolicy.select(for: routeReq).fuelAlternates(request)
        } catch {
            candidates = []
        }
        if candidates.isEmpty, routingSourcePolicy.select(for: routeReq).name != "pack" {
            let pack = PackRoutingSource(packs: graphPacks, cache: RouteResponseCache())
            candidates = (try? await pack.fuelAlternates(request)) ?? []
        }
        guard replacingFuelStopID == id else { return }
        fuelReplacementCandidates = candidates
        toast = candidates.contains(where: \.isValid)
            ? "Select a pulsing station"
            : "No in-range alternate"
        refreshMap()
    }

    func selectFuelAlternate(stationID: String) {
        guard let id = replacingFuelStopID,
              let candidate = fuelReplacementCandidates.first(where: { $0.stationID == stationID }),
              candidate.isValid
        else { return }
        replacingFuelStopID = nil
        fuelReplacementCandidates = []
        apply(
            .replaceFuelStop(
                id: id,
                stationID: candidate.stationID,
                coordinate: candidate.coordinate,
                name: candidate.name
            ),
            source: "fuelReplace"
        )
    }

    func cancelFuelReplacement() {
        guard replacingFuelStopID != nil || !fuelReplacementCandidates.isEmpty else { return }
        replacingFuelStopID = nil
        fuelReplacementCandidates = []
        mapState.selectPlannerPin(nil)
        refreshMap()
    }

    static func fuelMarkerID(_ id: UUID) -> String { "fuel:\(id.uuidString)" }

    static func fuelStopID(fromMarker markerID: String) -> UUID? {
        guard markerID.hasPrefix("fuel:") else { return nil }
        return UUID(uuidString: String(markerID.dropFirst(5)))
    }

    private func syncFuelAnchors(from built: BuiltItinerary) {
        var next: [FuelAnchor] = []
        var sequenceByLeg: [UUID: Int] = [:]
        for leg in built.legs {
            guard let stop = leg.endsAtFuelStop else { continue }
            let sequence = sequenceByLeg[leg.riderLegID, default: 0]
            sequenceByLeg[leg.riderLegID] = sequence + 1
            let pinned = itinerary.fuelAnchors.first { $0.id == stop.id }?.isPinned == true
            next.append(FuelAnchor(
                id: stop.id,
                riderLegID: leg.riderLegID,
                sequence: sequence,
                stationID: stop.stationID ?? "",
                coordinate: stop.coordinate,
                name: stop.name,
                isPinned: pinned
            ))
        }
        guard next != itinerary.fuelAnchors else { return }
        itinerary = RiderItinerary(
            waypoints: itinerary.waypoints,
            legs: itinerary.legs,
            generation: itinerary.generation,
            impassableEdgeIDs: itinerary.impassableEdgeIDs,
            fuelAnchors: next,
            hopOverrides: itinerary.hopOverrides
        )
    }

    private func fuelReplacementContext(id: UUID) -> (
        previous: RouteCoordinate,
        next: RouteCoordinate,
        previousCap: Double,
        usable: Double,
        profile: RouteProfile,
        allowUnknown: Bool,
        stationID: String?
    )? {
        guard let built,
              let hopIndex = built.legs.firstIndex(where: { $0.endsAtFuelStop?.id == id })
        else { return nil }
        let hop = built.legs[hopIndex]
        let next: RouteCoordinate
        if let laterFuel = built.legs.dropFirst(hopIndex + 1).first(where: { $0.endsAtFuelStop != nil }) {
            next = laterFuel.toCoordinate
        } else if let riderIndex = itinerary.legs.firstIndex(where: { $0.id == hop.riderLegID }) {
            next = itinerary.waypoints[riderIndex + 1].coordinate
        } else {
            next = hop.toCoordinate
        }
        let usable = FuelRangePrefs.snapshot.usableMeters
        let carried: Double
        if hopIndex == 0 || built.legs[hopIndex - 1].endsAtFuelStop != nil {
            carried = 0
        } else {
            carried = built.legs[hopIndex - 1].fuelUsedOnArrivalMeters
        }
        let rider = itinerary.legs.first { $0.id == hop.riderLegID }
        return (
            hop.fromCoordinate,
            next,
            max(0, usable - carried),
            usable,
            rider?.profile ?? profile,
            rider?.allowUnknown ?? allowUnknown,
            hop.endsAtFuelStop?.stationID
        )
    }

    // MARK: - Routing

    func routeFromHere() async {
        fromHereIntentGeneration += 1
        let intentGeneration = fromHereIntentGeneration
        let origin = fromHereStartOverride ?? locationService.currentCoordinate
        guard let origin else {
            errorMessage = "Waiting for GPS — allow location access to route from here."
            if toast == Self.calculatingRouteToast { toast = nil }
            return
        }
        guard let requestedDest = destination else { return }
        let requestedStart = fromHereStartOverride

        // GPS / camp far from any pack edge → ask for a road tap for A.
        // Within preferredMatchMeters we soft-stitch onto the road and route.
        let usingGPSStart = requestedStart == nil
        if usingGPSStart {
            let cl = CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude)
            if Self.installedPacksCover(ends: [cl], store: graphPacks) {
                await graphPacks.ensureRoadShapes(for: [cl])
                let distance = await graphPacks.distanceToNearestRoad(
                    from: cl,
                    allowUnknown: allowUnknown,
                    profile: profile
                )
                guard intentGeneration == fromHereIntentGeneration,
                      destination == requestedDest,
                      fromHereStartOverride == requestedStart
                else { return }
                if distance == nil || distance! > OnDeviceRouter.preferredMatchMeters {
                    isAssemblingRoute = false
                    fromHereResponse = nil
                    let meters = distance.map { Int($0.rounded()) }
                    enterFromHereNeedsStartPin(startMeters: meters)
                    toast = nil
                    refreshMap()
                    return
                }
            }
        }

        fromHereResponse = nil
        fromHereNeedsStartPin = false
        errorMessage = nil
        apply(
            .replaceAll(
                waypoints: [origin, requestedDest],
                profile: profile,
                allowUnknown: allowUnknown
            ),
            source: "fromHere"
        )
        mapState.fit([origin, requestedDest])
    }

    private static let offGraphStartMessage =
        "Your start (GPS) isn’t close enough to a mapped road. Tap the nearest road to set point 1 — point 2 stays put."

    private func enterFromHereNeedsStartPin(startMeters: Int? = nil) {
        fromHereNeedsStartPin = true
        // Only use the “about N m / limit 550” copy when the start is actually beyond
        // soft-approach. Within the limit, noPath is a fabric/profile issue — not tap-A.
        if let startMeters, startMeters > Int(OnDeviceRouter.preferredMatchMeters) {
            errorMessage =
                "Your start (GPS) is about \(startMeters) m from the nearest mapped road (limit \(Int(OnDeviceRouter.preferredMatchMeters)) m). Tap the road to set point 1 — point 2 stays put."
        } else {
            errorMessage = Self.offGraphStartMessage
        }
    }

    /// GPS farther than the default match radius, or no road within snap range.
    private func gpsStartLooksOffGraph(_ origin: RouteCoordinate) async -> Bool {
        let cl = CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude)
        guard Self.installedPacksCover(ends: [cl], store: graphPacks) else { return false }
        await graphPacks.ensureRoadShapes(for: [cl])
        guard let distance = await graphPacks.distanceToNearestRoad(
            from: cl,
            allowUnknown: allowUnknown,
            profile: profile
        ) else { return true }
        return distance > OnDeviceRouter.preferredMatchMeters
    }

    private func shouldEnterFromHereStartRecovery(
        error: Error,
        usingGPSStart: Bool,
        origin: RouteCoordinate
    ) async -> Bool {
        if Self.isOffGraphStartFailure(error) {
            // Off-graph copy only when GPS is actually beyond soft-approach.
            return await gpsStartLooksOffGraph(origin)
        }
        guard usingGPSStart else { return false }
        // Spec: no_route with both ends within 550 m → profile / pack / Allow —
        // do NOT force tap-A (that produced the false “84 m / limit 550” dialog).
        if !(await gpsStartLooksOffGraph(origin)) {
            return false
        }
        if Self.isDisconnectedStartFailure(error) { return true }
        if Self.isNoRouteFailure(error) { return true }
        return false
    }

    private static func installedPacksCover(
        ends: [CLLocationCoordinate2D],
        store: GraphPackStore
    ) -> Bool {
        let needed = GraphPackStore.regionIds(containingAny: ends)
        if !needed.isEmpty, needed.allSatisfy({ store.isInstalled($0) }) {
            return true
        }
        let primaries = ends.compactMap { GraphPackStore.primaryRegionId(containing: $0) }
        guard let first = primaries.first, primaries.allSatisfy({ $0 == first }) else {
            return false
        }
        return store.isInstalled(first)
    }

    /// Try Again: clear sticky A override and re-route GPS → B.
    func retryFromHere() {
        fromHereNeedsStartPin = false
        fromHereStartOverride = nil
        errorMessage = nil
        isAssemblingRoute = true
        toast = Self.calculatingRouteToast
        Task { await routeFromHere() }
    }

    /// Start could not join the eligible graph (GPS / override off mapped roads).
    private static func isOffGraphStartFailure(_ error: Error) -> Bool {
        if let routing = error as? RoutingError {
            if case .offGraphStart = routing { return true }
        }
        let msg = error.localizedDescription.lowercased()
        if msg.contains("isn’t close enough to a mapped road")
            || msg.contains("isn't close enough to a mapped road") {
            return true
        }
        if msg.contains("lock onto a road at your gps") { return true }
        if msg.contains("no eligible edge") && msg.contains("start") { return true }
        if msg.contains("of start") && msg.contains("eligible") { return true }
        return false
    }

    private static func isDisconnectedStartFailure(_ error: Error) -> Bool {
        let msg = error.localizedDescription.lowercased()
        return msg.contains("disconnected")
            || msg.contains("different connected components")
            || msg.contains("different networks")
    }

    private static func isNoRouteFailure(_ error: Error) -> Bool {
        let msg = error.localizedDescription.lowercased()
        return msg.contains("no route on the eligible graph")
            || msg.contains("no on-device path")
            || msg.contains("eligible edges do not connect")
    }

    // Superseded by canonical ordering; see docs/itinerary-refactor. Server-side backtrack penalty is the replacement.
    /// Keep a newly shaped leg from tracing the existing itinerary backwards.
    /// A Plan route is a journey, so a fresh leg should form a new continuation
    /// or loop—not consume the road it just arrived on in reverse. Leave the
    /// last two approach edges at the shared pin available for a one-throat
    /// junction, and fall back only when topology proves no alternative exists.
    private func stageContinuityAvoidEdgeIds(at index: Int) -> [String] {
        guard index > 0,
              stages.indices.contains(index),
              stages[index].fuelGroupID == nil
        else { return [] }
        var ordered: [String] = []
        for priorIndex in 0..<index {
            let prior = stages[priorIndex]
            guard prior.fuelGroupID == nil,
                  let segments = prior.response?.segments
            else { continue }
            let ids = segments.compactMap(\.edgeId).filter { !$0.isEmpty }
            if priorIndex == index - 1, ids.count > 2 {
                ordered.append(contentsOf: ids.dropLast(2))
            } else {
                ordered.append(contentsOf: ids)
            }
        }
        guard !ordered.isEmpty else { return [] }
        var seen = Set<String>()
        let result = Array(ordered.reversed().filter { seen.insert($0).inserted }.prefix(5_000))
        if !result.isEmpty {
            RoutingDebugLog.shared.event(
                "route continuity stage=\(index) avoidPriorEdges=\(result.count)"
            )
        }
        return result
    }

    static func profileRouteFailureMessage(
        requestedProfile: RouteProfile,
        legName: String,
        maxRouteMeters: Double?,
        cleanConnects: Bool,
        allowUnknown: Bool
    ) -> String {
        let limit = maxRouteMeters.map {
            " within this leg’s \(Int(($0 / 1000).rounded())) km usable fuel limit"
        } ?? ""
        let unknownHint = allowUnknown ? "" : " You can also try Allow unknown."
        if cleanConnects {
            return "No connected \(requestedProfile.title) route fits \(legName)\(limit). Clean can connect these pins on the available paved network. Use Clean, rebuild the fuel stops for \(requestedProfile.title), or increase usable range.\(unknownHint)"
        }
        return "Neither \(requestedProfile.title) nor Clean can connect \(legName)\(limit) on the eligible OSM network. Move a pin, increase usable range, or add a different fuel stop.\(unknownHint)"
    }

    /// Invalidate every in-flight planner route (clear / mode convert / wipe).
    private func invalidateInFlightRoutes(cancelPlanRebuildTask: Bool = true) {
        fromHereIntentGeneration += 1
        fromHereRouteDebounceTask?.cancel()
        buildTask?.cancel()
        moveDebounceTask?.cancel()
        pendingMove = nil
        itineraryBuilder.cancelCurrentBuild()
        isRouting = false
    }

    private func reroute() {
        if suppressPlannerReroute { return }
        rerouteCoalesceTask?.cancel()
        let capturedMode = mode
        rerouteCoalesceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            switch capturedMode {
            case .fromHere:
                if destination != nil {
                    await routeFromHere()
                }
            case .saved:
                break
            case .plan:
                break
            }
        }
    }

    /// Mid-trip recalculation: rider → preserved destination, same profile/Allow.
    /// Uses the installed `graph.v2` pack.
    /// Offline tiles are kept.
    ///
    /// Plan / multi-stage: re-routes **only the active leg** (rider → that stage’s
    /// end). Later stages’ pins, profiles, and geometry stay intact.
    /// From here / Saved single-leg: rider → final destination (unchanged).
    func recalculateFromRider(networkOnline: Bool = true) {
        guard navigation.phase == .active,
              let rider = locationService.currentCoordinate else { return }

        if shouldPreserveStagesForRecovery,
           let idx = activeStageIndex(near: rider),
           let stageEnd = stages[idx].end {
            Task {
                await rerouteActiveStage(
                    at: idx,
                    from: rider,
                    to: stageEnd,
                    avoidEdgeIds: [],
                    networkOnline: networkOnline,
                    announce: true
                )
            }
            return
        }

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
                let response = try await routeWhileNavigating(
                    from: rider,
                    to: target,
                    networkOnline: networkOnline
                )
                mode = .fromHere
                destination = target
                seedCanonicalBuild(
                    coordinates: [rider, target],
                    profile: profile,
                    allowUnknown: allowUnknown,
                    responses: [response]
                )
                let display = MapState.displaySegments(from: [response])
                navigation.replaceRoute(
                    coordinates: response.coordinates,
                    maneuvers: response.maneuvers ?? [],
                    segments: display,
                    networkSegments: networkSegments(from: [response])
                )
            } catch {
                toast = error.localizedDescription
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
    /// away we use it; otherwise the raw coordinate is kept.  Use loaded
    /// network geometry first, fall back to the raw point when nothing is near
    /// enough.  Full rendered-layer
    /// snapping (like `queryRenderedFeatures`) is not yet available in
    /// MapLibre Native iOS.
    func moveWaypoint(markerID: String, to rawCoordinate: CLLocationCoordinate2D) {
        guard navigation.phase == .idle else { return }
        let raw = RouteCoordinate(longitude: rawCoordinate.longitude, latitude: rawCoordinate.latitude)
        let snapped = snapToRouteNetwork(raw)
        switch mode {
        case .fromHere:
            // B relocates via long-press on the map (road-snapped) — pins are not draggable.
            return
        case .saved:
            // Saved overview: B is movable; A is the stored track start (display only).
            guard markerID == "dest" else { return }
            destination = snapped
            mode = .fromHere
            refreshMap()
            Task { await routeFromHere() }
        case .plan:
            movePlanStyleWaypoint(markerID: markerID, snapped: snapped)
        }
    }

    private func movePlanStyleWaypoint(markerID: String, snapped: RouteCoordinate) {
        guard markerID.hasPrefix("wp:"),
              let waypointID = UUID(uuidString: String(markerID.dropFirst(3))),
              itinerary.waypoints.contains(where: { $0.id == waypointID })
        else { return }
        mapState.selectPlannerPin(nil)
        apply(.move(waypointID: waypointID, to: snapped), source: "drag")
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
    /// Route to this POI.
    func routeToCoordinate(name: String?, latitude: Double, longitude: Double) {
        let point = RouteCoordinate(longitude: longitude, latitude: latitude)
        mode = .fromHere
        itinerary = RiderItinerary()
        built = nil
        fromHereResponse = nil
        destination = point
        destinationName = name
        presentRouteCard = true
        isAssemblingRoute = true
        toast = Self.calculatingRouteToast
        mapState.fromHereLongPressRelocatesDestination = true
        refreshMap()
        Task { await routeFromHere() }
    }

    /// Add a coordinate as the next open plan waypoint.
    /// Add this POI as a plan waypoint.
    func addPlanWaypoint(latitude: Double, longitude: Double) {
        let point = RouteCoordinate(longitude: longitude, latitude: latitude)
        if mode != .plan { mode = .plan }
        appendPlanPoint(point)
    }

    // MARK: - Clear / mode

    /// From here has a pin and/or a calculated route worth confirming before leaving.
    var hasFromHereDraft: Bool {
        destination != nil || !itinerary.waypoints.isEmpty
    }

    /// Plan has at least one waypoint worth confirming before leaving.
    var hasPlanDraft: Bool {
        !itinerary.waypoints.isEmpty
    }


    func clearRoute() {
        if navigation.phase != .idle {
            endNavigation()
        }
        invalidateInFlightRoutes()
        destination = nil
        destinationName = nil
        fromHereResponse = nil
        fromHereNeedsStartPin = false
        fromHereStartOverride = nil
        itinerary = RiderItinerary()
        built = nil
        fuelPlanningStatus = nil
        fuelPreviewStops = []
        replacingFuelStopID = nil
        fuelReplacementCandidates = []
        errorMessage = nil
        routeIdentity = nil
        savedRouteOrigin = nil
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
        guard itinerary.waypoints.count == 2 else {
            switchToPlanClearing()
            return
        }
        let endpoints = itinerary.waypoints.map(\.coordinate)

        destination = nil
        destinationName = nil
        fromHereResponse = nil
        fromHereNeedsStartPin = false
        fromHereStartOverride = nil
        errorMessage = nil
        mode = .plan
        mapState.selectPlannerPin(nil)
        routeIdentity = "plan:\(endpoints[1].latitude),\(endpoints[1].longitude)"
        refreshMap()
        mapState.fit(endpoints)
        RoutingDebugLog.shared.event("ui fromHere→plan itinerary=[2 waypoints] reusedBuild=true")
    }

    /// Saved (imported / opened track) → Plan: keep the track as stage 1 (A→B
    /// geometry unchanged). Rider can then long-press to add C, D, … as routed stages.
    /// Dragging A or B re-routes that leg like any other plan stage.
    @discardableResult
    func continuePlanningFromSavedTrack() -> Bool {
        guard mode == .saved, let response = fromHereResponse else { return false }
        let coords = response.coordinates
        guard let start = coords.first,
              let end = destination ?? coords.last
        else { return false }

        invalidateInFlightRoutes()
        let keptProfile = profile
        let keptAllow = allowUnknown
        let name = destinationName

        destination = nil
        destinationName = nil
        fromHereResponse = nil
        errorMessage = nil
        // savedRouteOrigin is deliberately kept: edits made from here save back to the
        // library record the rider opened, rather than forking a near-identical copy.
        mode = .plan
        seedCanonicalBuild(
            coordinates: [start, end],
            profile: keptProfile,
            allowUnknown: keptAllow,
            responses: [response]
        )
        routeIdentity = "plan:\(end.latitude),\(end.longitude)"
        presentRouteCard = true
        toast = name.map { "Planning from “\($0)”" } ?? "Planning from track"
        refreshMap()
        if coords.count >= 2 {
            mapState.fit(coords)
        } else {
            mapState.fit([start, end])
        }
        return true
    }

    /// From here → Plan: discard the From here draft and open an empty plan.
    func switchToPlanClearing() {
        invalidateInFlightRoutes()
        destination = nil
        destinationName = nil
        fromHereResponse = nil
        fromHereNeedsStartPin = false
        fromHereStartOverride = nil
        itinerary = RiderItinerary()
        built = nil
        errorMessage = nil
        routeIdentity = nil
        savedRouteOrigin = nil
        mapState.selectPlannerPin(nil)
        mode = .plan
        refreshMap()
    }

    /// Plan → From here: use the last plan pin as From here destination B.
    func switchToFromHereUsingLastPin() {
        let lastPin = itinerary.waypoints.last?.coordinate
        let keptProfile = itinerary.legs.last?.profile ?? profile
        let keptAllow = itinerary.legs.last?.allowUnknown ?? false

        invalidateInFlightRoutes()
        itinerary = RiderItinerary()
        built = nil
        errorMessage = nil
        routeIdentity = nil
        savedRouteOrigin = nil
        mapState.selectPlannerPin(nil)
        suppressPlannerReroute = true
        profile = keptProfile
        allowUnknown = keptAllow
        suppressPlannerReroute = false
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
        itinerary = RiderItinerary()
        built = nil
        destination = nil
        destinationName = nil
        fromHereResponse = nil
        errorMessage = nil
        routeIdentity = nil
        savedRouteOrigin = nil
        mapState.selectPlannerPin(nil)
        mode = .fromHere
        refreshMap()
    }

    private func modeChanged(from oldMode: Mode) {
        guard oldMode != mode else { return }
        // Draft clear / convert is explicit via switchTo* helpers or clearRoute.
        // Saved ↔ other tabs only need a repaint.
        errorMessage = nil
        if mode != .fromHere {
            fromHereNeedsStartPin = false
            fromHereStartOverride = nil
        }
        mapState.fromHereLongPressRelocatesDestination = (mode == .fromHere)
        if mode != .fromHere && mode != .plan {
            isAssemblingRoute = false
        }
        refreshMap()
    }

    // MARK: - Map paint

    /// Layers only paints edges the current Allow setting can actually route.
    private func syncNetworkAccessPolicy() {
        let allow: Bool
        if profile == .cleanest {
            allow = false
        } else if !stages.isEmpty {
            allow = stages.contains { $0.allowUnknown && $0.profile != .cleanest }
        } else {
            allow = allowUnknown
        }
        mapState.setNetworkAllowUnknown(allow)
    }

    func refreshMap() {
        syncNetworkAccessPolicy()
        let displayLegIDs: [UUID?]
        if mode == .fromHere || mode == .plan {
            displayLegIDs = (built?.legs ?? []).map { Optional($0.riderLegID) }
        } else {
            displayLegIDs = []
        }
        mapState.isRouteBuilding = isRouting || fuelPlanningStatus != nil
        mapState.setRoute(MapState.displaySegments(from: activeResponses, riderLegIDs: displayLegIDs))
        var markers: [MapState.Marker] = []
        switch mode {
        case .fromHere:
            if itinerary.waypoints.isEmpty, let destination {
                markers.append(
                    MapState.Marker(
                        id: "dest",
                        latitude: destination.latitude,
                        longitude: destination.longitude,
                        label: "2",
                        kind: .destination,
                        isLocked: true
                    )
                )
            } else {
                markers.append(contentsOf: canonicalMarkers(riderPinsLocked: true))
            }
        case .saved:
            // Show both endpoints so a loaded route has visible first + second pins.
            if let start = fromHereResponse?.coordinates.first {
                markers.append(
                    MapState.Marker(
                        id: "start",
                        latitude: start.latitude,
                        longitude: start.longitude,
                        label: "1",
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
                        label: "2",
                        kind: .destination
                    )
                )
            }
        case .plan:
            markers.append(contentsOf: canonicalMarkers(riderPinsLocked: false))
        }
        if fuelPlanningStatus != nil {
            for (index, stop) in fuelPreviewStops.enumerated() {
                markers.append(
                    MapState.Marker(
                        id: "fuel-preview-\(index)",
                        latitude: stop.latitude,
                        longitude: stop.longitude,
                        label: "F\(index + 1)",
                        kind: .fuel,
                        subtitle: "Checking fuel stop",
                        isLocked: true
                    )
                )
            }
        }
        if replacingFuelStopID != nil {
            for candidate in fuelReplacementCandidates {
                markers.append(
                    MapState.Marker(
                        id: "fuel-alt:\(candidate.stationID)",
                        latitude: candidate.coordinate.latitude,
                        longitude: candidate.coordinate.longitude,
                        label: candidate.isValid ? "F" : "·",
                        kind: .fuelCandidate,
                        subtitle: candidate.name,
                        isLocked: true,
                        isPulsing: candidate.isValid
                    )
                )
            }
        }
        let riders = mapState.markers.filter { $0.kind.isGroupOverlay }
        mapState.setMarkers(markers + riders)
    }

    private func canonicalMarkers(riderPinsLocked: Bool) -> [MapState.Marker] {
        var markers = itinerary.waypoints.enumerated().map { index, waypoint in
            MapState.Marker(
                id: "wp:\(waypoint.id.uuidString)",
                latitude: waypoint.coordinate.latitude,
                longitude: waypoint.coordinate.longitude,
                label: "\(index + 1)",
                kind: index == 0 ? .start : (index == itinerary.waypoints.count - 1 ? .destination : .stage),
                isLocked: riderPinsLocked
            )
        }
        var fuelOrdinal = 0
        for leg in built?.legs ?? [] {
            guard let stop = leg.endsAtFuelStop else { continue }
            fuelOrdinal += 1
            markers.append(
                MapState.Marker(
                    id: Self.fuelMarkerID(stop.id),
                    latitude: stop.coordinate.latitude,
                    longitude: stop.coordinate.longitude,
                    label: "F\(fuelOrdinal)",
                    kind: .fuel,
                    subtitle: stop.name,
                    isLocked: true
                )
            )
        }
        return markers
    }

    // MARK: - Save / export

    /// Identifies the library record a displayed route came from.
    struct SavedRouteOrigin: Equatable {
        let id: UUID
        var name: String
    }

    /// What Save should do for whatever is currently on the map.
    enum SaveAffordance: Equatable {
        /// A library route opened with View and not edited. It is already in the library,
        /// so offering Save could only produce a duplicate — the CTA is hidden instead.
        case alreadySaved
        /// Editing a route that came from the library: write back to that record.
        case update(name: String)
        /// A new plan, From here route, or unsaved track.
        case create
    }

    var saveAffordance: SaveAffordance {
        guard let origin = savedRouteOrigin else { return .create }
        return mode == .saved ? .alreadySaved : .update(name: origin.name)
    }

    /// Writes the current line to the library. When the rider is editing a route they
    /// opened from the library this updates that record; it used to insert unconditionally,
    /// so extending a saved route left two near-identical entries behind.
    func saveRoute(named name: String, context: ModelContext, forceNew: Bool = false) {
        guard hasRoute else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let origin = savedRouteOrigin else {
            insertSavedRoute(named: trimmed.isEmpty ? "DIRT route" : trimmed, context: context)
            return
        }

        if forceNew {
            let base = trimmed.isEmpty ? origin.name : trimmed
            // Two library entries under one name is the confusion this change exists to fix.
            insertSavedRoute(named: base == origin.name ? "\(base) (edited)" : base, context: context)
            return
        }

        guard let existing = fetchSavedRoute(id: origin.id, context: context) else {
            // Deleted from the library while it was still open on the map.
            insertSavedRoute(named: trimmed.isEmpty ? origin.name : trimmed, context: context)
            return
        }

        existing.name = trimmed.isEmpty ? origin.name : trimmed
        existing.profile = profile
        existing.coordinates = allCoordinates
        existing.distanceMeters = totalMeters
        existing.dirtPercent = aggregateDirtPercent
        existing.pavedPercent = aggregatePavedPercent
        try? context.save()
        savedRouteOrigin = SavedRouteOrigin(id: existing.id, name: existing.name)
        toast = "Updated “\(existing.name)”"
    }

    private func insertSavedRoute(named name: String, context: ModelContext) {
        let route = SavedRoute(
            name: name,
            profile: profile,
            coordinates: allCoordinates,
            distanceMeters: totalMeters,
            dirtPercent: aggregateDirtPercent,
            pavedPercent: aggregatePavedPercent
        )
        context.insert(route)
        try? context.save()
        // Adopt the new record so a second Save updates it rather than stacking copies.
        savedRouteOrigin = SavedRouteOrigin(id: route.id, name: route.name)
        toast = "Route saved"
    }

    private func fetchSavedRoute(id: UUID, context: ModelContext) -> SavedRoute? {
        var descriptor = FetchDescriptor<SavedRoute>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
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
        // Set after applying geometry — that path clears the origin for imports.
        savedRouteOrigin = SavedRouteOrigin(id: saved.id, name: saved.name)
    }

    /// Reads a GPX file from the document picker or share sheet, displays the
    /// track on the map, and saves it to SwiftData.
    /// When `continueAsPlan` is true, lands in Plan with the track as stage 1
    /// so the rider can keep adding waypoints (A→B kept, then C…).
    func importGPX(from url: URL, context: ModelContext, continueAsPlan: Bool = false) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let parsed = try GPXParser.parse(contentsOf: url)
            if continueAsPlan {
                seedPlanFromTrack(parsed)
            } else {
                applyImportedTrack(parsed)
            }
            saveRoute(named: parsed.name, context: context)
            toast = continueAsPlan
                ? "Planning from “\(parsed.name)”"
                : "Imported “\(parsed.name)”"
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

    /// Import straight into Plan: track geometry = stage 1 (not re-routed).
    private func seedPlanFromTrack(_ track: GPXParser.ParsedTrack) {
        let coords = track.coordinates
        guard coords.count >= 2, let start = coords.first, let end = coords.last else {
            errorMessage = GPXParser.ParseError.noTrackOrRoute.errorDescription
            return
        }
        errorMessage = nil
        invalidateInFlightRoutes()
        destination = nil
        destinationName = nil
        fromHereResponse = nil
        itinerary = RiderItinerary()
        built = nil
        // importGPX saves this track as its own record right after seeding the plan.
        savedRouteOrigin = nil

        let response = makeStoredRouteResponse(
            coordinates: coords,
            distanceMeters: track.distanceMeters,
            dirtPercent: 0,
            pavedPercent: 0,
            imported: true,
            segmentPolylines: track.segments
        )
        mode = .plan
        seedCanonicalBuild(
            coordinates: [start, end],
            profile: profile,
            allowUnknown: allowUnknown,
            responses: [response]
        )
        routeIdentity = "plan:\(end.latitude),\(end.longitude)"
        presentRouteCard = true
        refreshMap()
        mapState.fit(coords)
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
        // Whatever was loaded before is no longer what's on the map; loadSavedRoute
        // re-establishes the link straight after this returns.
        savedRouteOrigin = nil
        destination = coordinates.last
        destinationName = name
        fromHereResponse = makeStoredRouteResponse(
            coordinates: coordinates,
            distanceMeters: distanceMeters,
            dirtPercent: dirtPercent,
            pavedPercent: pavedPercent,
            imported: imported,
            segmentPolylines: segmentPolylines
        )
        routeIdentity = identity
        refreshMap()
        // Fit the first and last points (A/B), not every polyline vertex —
        // long routes still frame the endpoints so both pins stay visible.
        if let first = coordinates.first, let last = coordinates.last {
            mapState.fit([first, last])
        }
    }

    private func makeStoredRouteResponse(
        coordinates: [RouteCoordinate],
        distanceMeters: Double,
        dirtPercent: Int,
        pavedPercent: Int,
        imported: Bool,
        segmentPolylines: [[RouteCoordinate]]? = nil,
        networkSegments: [RouteSegment]? = nil,
        unknownAccessPercent: Int = 0,
        warnings: [RouteWarning]? = nil
    ) -> RouteResponse {
        let segments: [RouteSegment]?
        if let networkSegments, !networkSegments.isEmpty {
            segments = networkSegments
        } else if imported, let segmentPolylines, !segmentPolylines.isEmpty {
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
        return RouteResponse(
            status: "complete",
            error: nil,
            message: nil,
            distanceMeters: distanceMeters,
            estimatedMovingSeconds: nil,
            estimatedElapsedSeconds: nil,
            geometry: coordinates,
            segments: segments,
            stats: RouteStats(
                dirtPercent: dirtPercent,
                pavedPercent: pavedPercent,
                unknownAccessPercent: unknownAccessPercent
            ),
            maneuvers: nil,
            warnings: warnings,
            dirtPercentValue: nil,
            pavedPercentValue: nil
        )
    }

    private func makeOnDeviceRouteResponse(_ local: OnDeviceRouter.Result) -> RouteResponse {
        let coords = local.coordinates.map {
            RouteCoordinate(longitude: $0.longitude, latitude: $0.latitude)
        }
        let segments = local.legs.map { leg in
            RouteSegment(
                surfaceClass: leg.paintSurfaceName,
                trackClass: leg.roadClassName,
                accessClass: leg.accessName,
                distanceMeters: leg.distanceMeters,
                geometry: leg.coordinates.map {
                    RouteCoordinate(longitude: $0.longitude, latitude: $0.latitude)
                },
                coords: nil,
                edgeId: leg.edgeId.isEmpty ? nil : leg.edgeId
            )
        }
        return makeStoredRouteResponse(
            coordinates: coords,
            distanceMeters: local.distanceMeters,
            dirtPercent: local.dirtPercent,
            pavedPercent: local.pavedPercent,
            imported: false,
            networkSegments: segments,
            unknownAccessPercent: local.unknownAccessPercent,
            warnings: {
                var warnings: [RouteWarning] = []
                if local.searchMeta.urbanCoreFallbackUsed {
                    warnings.append(RouteWarning(
                    code: "urban_core_fallback",
                    message: "No route could reach the destination while keeping every urban core as a wall. This Clean route uses an urban crossing only as a last resort."
                    ))
                }
                if local.searchMeta.cleanUnpavedFallbackUsed {
                    warnings.append(RouteWarning(
                        code: "clean_unpaved_fallback",
                        message: "No fully paved route could reach the destination while respecting the current routing walls. Clean used tagged unpaved road only as a last resort."
                    ))
                }
                if local.searchMeta.settlementFallbackUsed {
                    warnings.append(RouteWarning(
                        code: "settlement_fallback",
                        message: "This route could not avoid every mapped town without losing its routing objective. Town travel remains strongly penalized and is used only where the alternatives are worse."
                    ))
                }
                return warnings.isEmpty ? nil : warnings
            }()
        )
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

    // MARK: - Fuel assist

    /// Re-run fuel-stop insertion for the current route after the rider enables
    /// or changes tank range (From here / Plan).
    func reapplyFuelAssist(rangeKm requestedRangeKm: Double? = nil) {
        let rangeKm = requestedRangeKm ?? FuelRangePrefs.kilometers
        guard rangeKm > 0 else { return }
        guard mode == .fromHere || mode == .plan else { return }
        guard itinerary.legs.count > 0 else { return }
        FuelRangePrefs.kilometers = rangeKm
        FuelRangePrefs.lastEnabledKilometers = rangeKm
        fuelPlanNotice = nil

        RoutingDebugLog.shared.event("fuel reapply start mode=\(mode) legs=\(itinerary.legs.count) range=\(Int(rangeKm))km")
        toast = "Looking for fuel stops"
        apply(.rebuild, source: "fuel")
    }

    /// Invalidates an in-flight itinerary as soon as the rider grabs the fuel
    /// slider. The released value starts exactly one replacement job.
    func cancelFuelAssistForRangeEdit() {
        buildTask?.cancel()
        itineraryBuilder.cancelCurrentBuild()
        isAssemblingRoute = false
        fuelPlanningStatus = nil
        fuelPreviewStops = []
        if toast == "Looking for fuel stops" {
            toast = nil
        }
        refreshMap()
    }

    /// Turn fuel assist off even when its last attempt removed the route.
    /// Collapses auto fuel hops back to rider waypoints and immediately restores
    /// an ordinary A→B route, instead of leaving the switch hidden behind error UI.
    func disableFuelAssistAndRestoreRoute() {
        fuelPlanningStatus = nil
        fuelPreviewStops = []
        errorMessage = nil
        toast = Self.calculatingRouteToast
        apply(.rebuild, source: "fuel")
    }


    /// Station beside the already-drawn line, ~0.8 tank along it.
    /// Not the nearest pump to a crow-flies point (that is the 50 km spur).
    static func pickFuelStop(
        fuels: [POIFeature],
        along coordinates: [RouteCoordinate],
        rangeMeters: Double
    ) -> POIFeature? {
        guard !fuels.isEmpty, rangeMeters > 0, coordinates.count >= 2 else { return nil }
        let cumulative = GeoMath.cumulativeMeters(coordinates)
        guard let total = cumulative.last, total > rangeMeters * 1.15 else { return nil }
        let preferredAlong = min(rangeMeters * 0.82, total - 45_000)
        guard preferredAlong > 8_000 else { return nil }
        let alongLo = rangeMeters * 0.40
        let alongHi = min(rangeMeters * 0.95, total - 40_000)
        guard alongHi > alongLo else { return nil }

        func best(inCorridor corridor: Double) -> POIFeature? {
            var winner: POIFeature?
            var bestScore = Double.greatestFiniteMagnitude
            for fuel in fuels {
                let location = CLLocation(latitude: fuel.latitude, longitude: fuel.longitude)
                guard let proj = GeoMath.nearestProjection(
                    to: location, in: coordinates, cumulative: cumulative
                ), proj.offMeters <= corridor else { continue }
                guard proj.alongMeters >= alongLo, proj.alongMeters <= alongHi else { continue }
                let score = abs(proj.alongMeters - preferredAlong) + proj.offMeters * 2
                if score < bestScore {
                    bestScore = score
                    winner = fuel
                }
            }
            return winner
        }
        return best(inCorridor: 12_000) ?? best(inCorridor: 22_000)
    }

    /// One-shot fit of the current planned polyline into the open map
    /// (respects sheet / drawer content insets). From here · Plan · Saved.
    func focusEntirePlannedRoute() {
        guard canFocusEntirePlannedRoute else { return }
        mapState.fit(allCoordinates)
        toast = "Route overview"
    }

    /// True when idle planning has a drawable route worth framing.
    /// Hidden while navigating (nav owns its own overview toggle) and when
    /// there is no polyline yet (prefer hide-when-empty).
    var canFocusEntirePlannedRoute: Bool {
        guard navigation.phase == .idle else { return false }
        return allCoordinates.count >= 2
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

    /// Start Navigation always prefetches the route corridor first. Dual-sport
    /// riders leave cell coverage — maps must be on-device before the trek begins.
    func startNavigation() {
        guard hasRoute else { return }
        let coords = allCoordinates
        guard coords.count > 1 else { return }

        // Lock pin edit for the whole prep → ride window. Pan/zoom stay free.
        // Prevents accidental waypoint moves that invalidate the route and re-download.
        mapState.lockRouteEditingForPrep()

        let identity = routeIdentity ?? "route"
        let keepExisting = (lastNavigationIdentity == identity)
        lastNavigationIdentity = identity

        locationService.requestAlways()
        let windowSize: CGSize = {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            if let size = scene?.screen.bounds.size, size.width > 0, size.height > 0 {
                return size
            }
            return CGSize(width: 390, height: 844)
        }()
        // Tile identity is geographic — profile changes must not wipe corridor cache.
        let tileIdentity = Self.geographicTileIdentity(
            routeIdentity: identity,
            destination: destination,
            stages: stages
        )
        offline.prepareForNavigation(
            identity: tileIdentity,
            coordinates: coords,
            keepExisting: keepExisting,
            viewportSize: windowSize
        )
        // Phase C: lock routing packs with maps when CDN has them for this corridor.
        let clCoords = coords.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        graphPacks.prepareForNavigation(
            coordinates: clCoords,
            keepExisting: keepExisting
        )
        // Refresh published catalog, then quietly prefetch the first missing neighbor.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.graphPacks.refreshCatalogIfStale()
            self.graphPacks.maybeAutoDownloadNeighbors(
                for: clCoords,
                online: self.network.isOnline
            )
        }
    }

    /// Basemap tiles are geography-only; strip profile suffixes from route identity.
    private static func geographicTileIdentity(
        routeIdentity: String,
        destination: RouteCoordinate?,
        stages: [Stage]
    ) -> String {
        if routeIdentity.hasPrefix("here:"), let destination {
            return String(format: "here:%.5f,%.5f", destination.latitude, destination.longitude)
        }
        if routeIdentity.hasPrefix("plan:") {
            let ends = stages.compactMap(\.end)
            if !ends.isEmpty {
                return "plan:" + ends.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }
                    .joined(separator: ";")
            }
        }
        // Drop trailing `:profile` if present on older here: identities.
        if routeIdentity.hasPrefix("here:"),
           let cut = routeIdentity.range(of: ":", options: .backwards) {
            let after = routeIdentity[cut.upperBound...]
            if !after.isEmpty, after.allSatisfy({ $0.isLetter || $0 == "_" }) {
                return String(routeIdentity[..<cut.lowerBound])
            }
        }
        return routeIdentity
    }

    /// Mid-ride: when GPS enters a published region that isn’t installed, fetch that pack.
    private func considerAutoDownloadWhileRiding(at coordinate: CLLocationCoordinate2D) {
        guard navigation.phase == .active else { return }
        graphPacks.maybeAutoDownloadNeighbors(
            for: [coordinate],
            online: network.isOnline
        )
    }

    /// Called when offline prep is ready (or rider confirms after delight).
    func beginRideAfterOfflineReady() {
        guard hasRoute else { return }
        let coords = allCoordinates
        guard coords.count > 1 else { return }

        // Drop the gate immediately — proxy/style work used to run first and left
        // this card frozen on "BEGIN RIDE" for several seconds.
        offline.markPrepConsumed()

        Task { @MainActor in
            await Task.yield()
            do {
                try await offline.engageOfflineBasemap()
            } catch {
                toast = "Offline map proxy failed — riding with live tiles only."
            }

            locationService.requestAlways()
            locationService.setBackgroundUpdates(true)
            locationService.startUpdates()

            let maneuvers = allManeuvers
            let displaySegments = MapState.displaySegments(from: activeResponses)
            navigation.activate(
                coordinates: coords,
                maneuvers: maneuvers,
                segments: displaySegments,
                stageEndMeters: stageEndAlongMeters(),
                networkSegments: networkSegments(from: activeResponses)
            )
            // Seed cue card immediately from last GPS (don't wait for next tick).
            if let fix = locationService.lastLocation {
                navigation.update(with: fix)
            }
            mapState.beginNavigationCamera()
            if let coordinate = locationService.currentCoordinate {
                mapState.recenterOnUser(at: coordinate, detailZoom: MapState.navigationDetailZoom)
            }
        }
    }

    func cancelOfflineMapPrep() {
        offline.cancelPrep()
        graphPacks.cancel()
        if navigation.phase == .idle {
            mapState.unlockRouteEditingAfterPrepCancel()
        }
    }

    /// Along-route meters at each stage destination (for stage ETA labels).
    /// Uses the stage chain whenever present (Plan, or From here fuel hops).
    private func stageEndAlongMeters(fromStage startIndex: Int = 0) -> [Double] {
        if !stages.isEmpty {
            var ends: [Double] = []
            var cursor = 0.0
            for (index, stage) in stages.enumerated() where index >= startIndex {
                guard let response = stage.response else { continue }
                let len = response.distanceMeters ?? GeoMath.lineMeters(response.coordinates)
                cursor += len
                ends.append(cursor)
            }
            return ends
        }
        let total = GeoMath.lineMeters(allCoordinates)
        return total > 0 ? [total] : []
    }

    func skipPrefetch() {
        offline.skip()
    }

    func endNavigation() {
        let cleaned = RideEdgeSequence.sanitize(navigation.riddenEdgeIds)
        let candidate: RideContributionCandidate? =
            cleaned.count >= 3
            ? RideContributionCandidate(
                edgeIds: cleaned,
                distanceMeters: navigation.traveledMeters,
                startedAt: navigation.startedAt
            )
            : nil
        navigation.end()
        mapState.endNavigationCamera()
        locationService.setBackgroundUpdates(false)
        offline.disengageOfflineBasemap()
        graphPacks.cancelQuietDownloads()
        onNavigationEnded?(candidate)
    }

    // MARK: - Incident recovery support

    /// True when Start Nav locked a graph pack for on-device detours.
    var hasOnDeviceRoutingPack: Bool { graphPacks.canRouteOnDevice }

    /// Mid-ride / report recovery A→B. Tries on-device pack first; live `/api/route` if online.
    /// Optional `profile` / `allowUnknown` override the planner defaults (per-stage Plan).
    func routeWhileNavigating(
        from: RouteCoordinate,
        to: RouteCoordinate,
        avoidEdgeIds: [String] = [],
        networkOnline: Bool? = nil,
        profile: RouteProfile? = nil,
        allowUnknown: Bool? = nil
    ) async throws -> RouteResponse {
        let useProfile = profile ?? self.profile
        let useAllow = allowUnknown ?? self.allowUnknown
        let online = networkOnline ?? network.isOnline
        let fromCL = CLLocationCoordinate2D(latitude: from.latitude, longitude: from.longitude)
        let toCL = CLLocationCoordinate2D(latitude: to.latitude, longitude: to.longitude)

        await graphPacks.ensureRoadShapes(for: [fromCL, toCL])
        if let local = await graphPacks.routeOnDevice(
            from: fromCL,
            to: toCL,
            profile: useProfile,
            allowUnknown: useAllow,
            avoidEdgeIds: avoidEdgeIds,
            sessionSeed: planningSessionSeed
        ), local.coordinates.count > 1 {
            return makeOnDeviceRouteResponse(local)
        }

        guard online else {
            if graphPacks.canRouteOnDevice {
                throw RoutingError.server(
                    "On-device routing couldn’t find a detour. Try Backtrack or Return to network."
                )
            }
            throw RoutingError.server(
                "You’re offline and no routing pack is loaded. Reconnect for live routing, or download a province from PACKS before you lose signal."
            )
        }

        let request = RouteRequest(
            profile: useProfile,
            locations: [
                RouteLocation(latitude: from.latitude, longitude: from.longitude, label: "A"),
                RouteLocation(latitude: to.latitude, longitude: to.longitude, label: "B")
            ],
            allowUnknown: useAllow,
            avoidEdgeIds: avoidEdgeIds,
            sessionSeed: planningSessionSeed
        )
        return try await routing.route(request, timeout: 15)
    }

    /// From here / Plan A→B.
    /// Live `/api/route` is the source of truth whenever the phone is online,
    /// even if an offline pack happens to be installed. Packs are used here
    /// only without connectivity; navigation recovery has its own local-first
    /// path in `routeWhileNavigating`.
    var preservedDestination: RouteCoordinate? {
        if shouldPreserveStagesForRecovery,
           let idx = activeStageIndex(near: locationService.currentCoordinate),
           let end = stages[idx].end {
            return end
        }
        switch mode {
        case .fromHere, .saved:
            return destination ?? allCoordinates.last
        case .plan:
            return stages.last?.end ?? allCoordinates.last
        }
    }

    /// Final trip destination (last stage end / From here B) — for labels only.
    var preservedFinalDestination: RouteCoordinate? {
        switch mode {
        case .fromHere, .saved:
            return destination ?? stages.last?.end ?? allCoordinates.last
        case .plan:
            return stages.last?.end ?? allCoordinates.last
        }
    }

    /// Plan / fuel-chain: keep stage pins + later legs; only the active hop re-routes.
    var shouldPreserveStagesForRecovery: Bool {
        stages.contains { $0.response != nil && $0.end != nil }
    }

    /// Stage the rider is on, or the stage nearest `point` (report / off-route focus).
    func activeStageIndex(near point: RouteCoordinate? = nil) -> Int? {
        let routedIndices = stages.indices.filter {
            stages[$0].response != nil && stages[$0].end != nil
        }
        guard !routedIndices.isEmpty else { return nil }

        let probe = point ?? locationService.currentCoordinate
        if let probe {
            let location = CLLocation(latitude: probe.latitude, longitude: probe.longitude)
            var best: (index: Int, meters: Double)?
            for index in routedIndices {
                let coords = stages[index].response!.coordinates
                guard coords.count >= 2 else { continue }
                let cumulative = GeoMath.cumulativeMeters(coords)
                if let proj = GeoMath.nearestProjection(to: location, in: coords, cumulative: cumulative) {
                    if best == nil || proj.offMeters < best!.meters {
                        best = (index, proj.offMeters)
                    }
                } else if let vertex = GeoMath.nearestVertex(to: location, in: coords) {
                    if best == nil || vertex.meters < best!.meters {
                        best = (index, vertex.meters)
                    }
                }
            }
            if let best { return best.index }
        }

        if let stageNumber = navigation.currentStageNumber {
            let idx = stageNumber - 1
            // Only trust HUD stage index when nav still mirrors the full stage chain.
            if routedIndices.contains(idx),
               navigation.stageEndMeters.count == routedIndices.count {
                return idx
            }
        }
        return routedIndices.first
    }

    /// Profile / Allow for the stage that will be re-routed (falls back to planner defaults).
    func activeStageRoutingPolicy(near point: RouteCoordinate? = nil) -> (profile: RouteProfile, allowUnknown: Bool) {
        if let idx = activeStageIndex(near: point) {
            return (stages[idx].profile, stages[idx].allowUnknown)
        }
        return (profile, allowUnknown)
    }

    /// Matches a report position to the nearest routed segment's network edge
    /// (within 150 m). Nil when the route response carried no edge IDs.
    func edgeIdNear(_ point: RouteCoordinate) -> String? {
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        var best: (meters: Double, edgeId: String)?
        let responses: [RouteResponse]
        if let idx = activeStageIndex(near: point), let response = stages[idx].response {
            responses = [response]
        } else {
            responses = activeResponses
        }
        for response in responses {
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
    /// Prefers the active stage when preserving a multi-stage plan; skips
    /// segments whose `edgeId` is in `avoidEdgeIds` when possible.
    func nearestRoutePoint(to point: RouteCoordinate, avoidEdgeIds: [String] = []) -> RouteCoordinate? {
        let avoid = Set(avoidEdgeIds.filter { !$0.isEmpty })
        if shouldPreserveStagesForRecovery,
           let idx = activeStageIndex(near: point),
           let response = stages[idx].response {
            if let onStage = nearestPoint(on: response, to: point, avoidEdgeIds: avoid) {
                return onStage
            }
        }
        let coords = navigation.phase == .active ? navigation.coordinates : allCoordinates
        guard !coords.isEmpty else { return nil }
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        guard let nearest = GeoMath.nearestVertex(to: location, in: coords) else { return nil }
        return coords[nearest.index]
    }

    private func nearestPoint(
        on response: RouteResponse,
        to point: RouteCoordinate,
        avoidEdgeIds: Set<String>
    ) -> RouteCoordinate? {
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        if !avoidEdgeIds.isEmpty, let segments = response.segments, !segments.isEmpty {
            var best: (meters: Double, coordinate: RouteCoordinate)?
            for segment in segments {
                if let edgeId = segment.edgeId, avoidEdgeIds.contains(edgeId) { continue }
                let coords = segment.coordinates
                guard !coords.isEmpty,
                      let nearest = GeoMath.nearestVertex(to: location, in: coords)
                else { continue }
                if best == nil || nearest.meters < best!.meters {
                    best = (nearest.meters, coords[nearest.index])
                }
            }
            if let best { return best.coordinate }
        }
        let coords = response.coordinates
        guard !coords.isEmpty,
              let nearest = GeoMath.nearestVertex(to: location, in: coords)
        else { return nil }
        return coords[nearest.index]
    }

    /// Applies a confirmed recovery route (detour / return-to-network).
    /// Multi-stage: updates only the active leg; later stages stay as planned.
    func applyRecoveryRoute(_ response: RouteResponse, near point: RouteCoordinate? = nil) {
        if shouldPreserveStagesForRecovery,
           let idx = activeStageIndex(near: point ?? locationService.currentCoordinate) {
            applyActiveStageResponse(response, at: idx, isReturnToNetwork: isReturnToNetworkRecovery(response, stageIndex: idx))
            toast = "Route updated"
            return
        }
        let target = preservedFinalDestination
        mode = .fromHere
        destination = target
        if let start = response.coordinates.first,
           let end = target ?? response.coordinates.last {
            seedCanonicalBuild(
                coordinates: [start, end],
                profile: profile,
                allowUnknown: allowUnknown,
                responses: [response]
            )
        }
        let display = MapState.displaySegments(from: [response])
        navigation.replaceRoute(
            coordinates: response.coordinates,
            maneuvers: response.maneuvers ?? [],
            segments: display,
            networkSegments: networkSegments(from: [response])
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

    // MARK: - Active-leg mid-trip helpers

    /// Re-route one stage (rider → stage end) and recompose nav from that stage onward.
    private func rerouteActiveStage(
        at index: Int,
        from: RouteCoordinate,
        to: RouteCoordinate,
        avoidEdgeIds: [String],
        networkOnline: Bool,
        announce: Bool
    ) async {
        guard stages.indices.contains(index) else { return }
        let riderLegID = stages[index].riderLegID
        let useProfile = stages[index].profile
        let useAllow = stages[index].allowUnknown

        do {
            let response = try await routeWhileNavigating(
                from: from,
                to: to,
                avoidEdgeIds: avoidEdgeIds,
                networkOnline: networkOnline,
                profile: useProfile,
                allowUnknown: useAllow
            )
            guard let idx = stages.firstIndex(where: { $0.riderLegID == riderLegID }) else { return }

            applyActiveStageResponse(response, at: idx, isReturnToNetwork: false)
            if announce {
                if hasOnDeviceRoutingPack, !networkOnline {
                    toast = "Rerouted on-device (\(Int((response.distanceMeters ?? 0) / 1000)) km)"
                } else {
                    announceRouteReadyIfComplete()
                }
            }
        } catch {
            toast = error.localizedDescription
        }
    }

    /// Whether `response` ends mid-stage (return-to-network) vs at the stage pin (detour).
    private func isReturnToNetworkRecovery(_ response: RouteResponse, stageIndex: Int) -> Bool {
        guard let stageEnd = stages[stageIndex].end,
              let responseEnd = response.coordinates.last
        else { return false }
        return !roughlyNear(responseEnd, stageEnd, withinMeters: 250)
    }

    private func roughlyNear(_ a: RouteCoordinate, _ b: RouteCoordinate, withinMeters: Double) -> Bool {
        let la = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let lb = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return la.distance(from: lb) <= withinMeters
    }

    /// Writes the new active-leg geometry; pins / profiles / later stages unchanged.
    private func applyActiveStageResponse(
        _ response: RouteResponse,
        at index: Int,
        isReturnToNetwork: Bool
    ) {
        guard stages.indices.contains(index) else { return }

        let applied: RouteResponse
        if isReturnToNetwork {
            applied = spliceReturnPath(response, ontoStageAt: index)
        } else {
            applied = response
        }

        guard let current = built,
              current.legs.indices.contains(index)
        else { return }
        var legs = current.legs
        let old = legs[index]
        legs[index] = BuiltLeg(
            riderLegID: old.riderLegID,
            fromCoordinate: old.fromCoordinate,
            toCoordinate: old.toCoordinate,
            endsAtFuelStop: old.endsAtFuelStop,
            response: applied,
            fuelUsedOnArrivalMeters: old.fuelUsedOnArrivalMeters
        )
        var statuses = current.riderLegStatus
        statuses[old.riderLegID] = .built
        built = BuiltItinerary(generation: current.generation, legs: legs, riderLegStatus: statuses)

        recomposeNavigationFromActiveStage(index)
        refreshMap()
    }

    /// Return-to-network: recovery line + remainder of the active stage from rejoin.
    private func spliceReturnPath(_ returnResponse: RouteResponse, ontoStageAt index: Int) -> RouteResponse {
        guard let existing = stages[index].response,
              let rejoin = returnResponse.coordinates.last
        else { return returnResponse }

        let stageCoords = existing.coordinates
        let rejoinLoc = CLLocation(latitude: rejoin.latitude, longitude: rejoin.longitude)
        guard let nearest = GeoMath.nearestVertex(to: rejoinLoc, in: stageCoords) else {
            return returnResponse
        }

        let remaining = Array(stageCoords[nearest.index...])
        var combined = returnResponse.coordinates
        for coordinate in remaining where coordinate != combined.last {
            combined.append(coordinate)
        }
        guard combined.count > 1 else { return returnResponse }

        let meters = GeoMath.lineMeters(combined)
        // Prefer existing stage surface stats for the remaining corridor.
        let dirt = existing.dirtPercent
        let paved = max(0, 100 - dirt)
        return makeStoredRouteResponse(
            coordinates: combined,
            distanceMeters: meters,
            dirtPercent: dirt,
            pavedPercent: paved,
            imported: false,
            networkSegments: nil
        )
    }

    /// Rebuild nav polyline / cues / stage ends from the active stage through B.
    private func recomposeNavigationFromActiveStage(_ index: Int) {
        let remainingResponses = stages.suffix(from: index).compactMap(\.response)
        guard !remainingResponses.isEmpty else { return }

        var coords: [RouteCoordinate] = []
        for response in remainingResponses {
            for coordinate in response.coordinates where coordinate != coords.last {
                coords.append(coordinate)
            }
        }
        guard coords.count > 1 else { return }

        var maneuvers: [RouteManeuver] = []
        var offset = 0.0
        for response in remainingResponses {
            for maneuver in response.maneuvers ?? [] {
                maneuvers.append(maneuver.shiftingAlong(by: offset))
            }
            offset += response.distanceMeters ?? 0
        }

        let display = MapState.displaySegments(from: remainingResponses)
        navigation.replaceRoute(
            coordinates: coords,
            maneuvers: maneuvers,
            segments: display,
            stageEndMeters: stageEndAlongMeters(fromStage: index),
            networkSegments: networkSegments(from: Array(remainingResponses))
        )
    }

    /// Flatten route segments that carry pack `edgeId`s (for ride contribution).
    private func networkSegments(from responses: [RouteResponse]) -> [RouteSegment] {
        responses.flatMap { $0.segments ?? [] }
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

    /// Brief success confirmation after routing — dirt/paved detail lives in the stats row.
    /// Never celebrate a partial route, a fuel preview, or an assembling itinerary.
    private func announceRouteReadyIfComplete() {
        guard !isAssemblingRoute,
              fuelPlanningStatus == nil,
              routePlanIsCompleteSuccess else {
            if toast == Self.calculatingRouteToast {
                toast = nil
            }
            return
        }
        toast = Self.routeReadyToast
    }

    /// True when every hop that should have geometry succeeded.
    /// Do **not** require `!isRouting` — announce runs before `defer` clears those flags,
    /// which left "Calculating route" stuck on successful From here / Plan hops.
    private var routePlanIsCompleteSuccess: Bool {
        if let built, !itinerary.legs.isEmpty {
            return itinerary.legs.allSatisfy { leg in
                if case .built = built.riderLegStatus[leg.id] { return true }
                return false
            }
        }
        switch mode {
        case .fromHere, .saved:
            return fromHereResponse != nil && errorMessage == nil
        case .plan:
            return false
        }
    }

    /// Mid-nav / single-leg success toast (caller already verified the response).
    private func announceRouteReady() {
        announceRouteReadyIfComplete()
    }
}
