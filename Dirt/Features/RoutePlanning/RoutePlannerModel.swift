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
        let id = UUID()
        var start: RouteCoordinate?
        var end: RouteCoordinate?
        var profile: RouteProfile
        var allowUnknown = false
        var response: RouteResponse?
        var isRouting = false
        var error: String?
        /// Bumped on each on-device routing for this stage; stale responses are ignored.
        var routeGeneration = 0
        /// When true, Plan fuel-assist will not split this stage again.
        var skipFuelAssist = false
        /// End pin is an auto fuel stop (From here / Plan assist). Locked on From here.
        var endsAtFuelStop = false
        /// Packed OSM station carried into the map pin and route-sheet leg label.
        var fuelStopID: String?
        var fuelStopName: String?
        /// Every auto-generated hop from one rider-created stage shares a group.
        /// The group supports range-level rebuilds; leg profile/access edits stay local.
        var fuelGroupID: UUID?
        /// Hard route-length ceiling for an auto fuel leg.
        var maxRouteMeters: Double? = nil

        mutating func setEndsAtFuelStop(
            _ newValue: Bool,
            site: StaticString = #function,
            line: UInt = #line
        ) {
            let previous = endsAtFuelStop
            endsAtFuelStop = newValue
            guard previous != newValue else { return }
            RoutingDebugLog.shared.event(
                "stage fuelflag changed id=\(id.uuidString) from=\(previous) to=\(newValue) site=\(site):\(line)"
            )
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

    // Plan stages
    private(set) var stages: [Stage] = [] {
        didSet {
            RoutingDebugLog.shared.event(
                "stages mutated count=\(stages.count) fuelEnds=\(stages.filter(\.endsAtFuelStop).count) site=\(#function)"
            )
        }
    }

    /// When true, `profile` / `allowUnknown` didSet skips `reroute()`.
    @ObservationIgnored private var suppressPlannerReroute = false
    /// Coalesce profile / Allow toggles so we don't fire 6 parallel Dijkstras.
    @ObservationIgnored private var rerouteCoalesceTask: Task<Void, Never>?
    /// Debounce plan pin moves / rapid long-presses before rebuilding stages.
    @ObservationIgnored private var planRebuildDebounceTask: Task<Void, Never>?
    /// Debounce newly placed plan hops (long-press 1→2→3).
    @ObservationIgnored private var planStageDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPlanStageIndices: Set<Int> = []
    /// Debounce From here point-2/point-1 retaps while the rider is adjusting the pin.
    @ObservationIgnored private var fromHereRouteDebounceTask: Task<Void, Never>?

    private(set) var isRouting = false
    var errorMessage: String?
    /// Non-destructive fuel recovery/status shown in the compact fuel summary.
    private(set) var fuelPlanNotice: String?
    /// Persistent, specific progress for multi-request fuel planning. Unlike a
    /// toast, this remains visible for the full operation and survives tab hops.
    private(set) var fuelPlanningStatus: String?
    /// Tentative, route-connected pumps revealed as the chain search advances.
    private var fuelPreviewStops: [RouteCoordinate] = []
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
    /// Invalidates in-flight From here / Saved routes when the rider changes intent.
    private var fromHereRouteGeneration = 0
    /// Invalidates an in-flight From here route when the rider cancels / changes destination.

    private let routing: RoutingClient
    private let locationService: LocationService
    private let mapState: MapState
    let navigation: NavigationSession
    private let offline: OfflineTileManager
    private let graphPacks: GraphPackStore
    private let network: NetworkPathMonitor
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
        poiManager: POIManager? = nil
    ) {
        self.routing = routing
        self.locationService = locationService
        self.mapState = mapState
        self.navigation = navigation
        self.offline = offline
        self.graphPacks = graphPacks
        self.network = network
        self.poiManager = poiManager

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
        case .fromHere:
            // Fuel assist may promote a From here hop into stages (A→fuel→B).
            if !stages.isEmpty { return stages.compactMap(\.response) }
            return fromHereResponse.map { [$0] } ?? []
        case .saved:
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
        let startName: String
        if index > 0, stages[index - 1].endsAtFuelStop {
            if let prior = stages[index - 1].fuelStopName, !prior.isEmpty {
                startName = prior
            } else {
                let fuelOrdinal = stages.prefix(index).filter(\.endsAtFuelStop).count
                startName = "Fuel stop \(fuelOrdinal)"
            }
        } else {
            let ordinal = 1 + stages.prefix(index).filter { !$0.endsAtFuelStop }.count
            startName = "Point \(ordinal)"
        }
        let endName: String
        if let fuel = stages[index].fuelStopName, !fuel.isEmpty {
            endName = fuel
        } else if stages[index].endsAtFuelStop {
            let fuelOrdinal = stages.prefix(index + 1).filter(\.endsAtFuelStop).count
            endName = "Fuel stop \(fuelOrdinal)"
        } else {
            let ordinal = 1 + stages.prefix(index + 1).filter { !$0.endsAtFuelStop }.count
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

    /// From here drops point 2 as soon as the rider taps — before on-device routing returns.
    static let paintsDestinationImmediatelyOnFromHereTap = true
    static let calculatingRouteToast = "Calculating route"
    static let routeReadyToast = "Route successful"

    /// True while From here / Plan is still building the full route
    /// (including chained fuel stops). Holds calculating toast + spinner.
    private var isAssemblingRoute = false
    /// Invalidates in-flight Overpass picks so two fuel jobs cannot split the same station twice.
    private var fuelAssistGeneration = 0
    /// Stable within this app process; a fresh launch can pick a different near-equal corridor.
    let planningSessionSeed: UInt64 = UInt64.random(in: 1...9_007_199_254_740_991)

    func handleMapTap(_ coordinate: CLLocationCoordinate2D) {
        guard navigation.phase == .idle else { return }
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
    func handleRouteTap(_ coordinate: CLLocationCoordinate2D) {
        guard navigation.phase == .idle,
              mode == .plan,
              !isRouting,
              fuelPlanningStatus == nil,
              !stages.isEmpty
        else { return }

        let probe = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var nearest: (index: Int, point: RouteCoordinate, meters: Double)?
        for (index, stage) in stages.enumerated() {
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
        guard let nearest, splitStage(at: nearest.index, via: nearest.point) else { return }

        mapState.selectPlannerPin(stageMarkerID(stages[nearest.index]))
        toast = "Waypoint added — drag it to shape this leg"
        RoutingDebugLog.shared.event(
            "ui route waypoint inserted stage=\(nearest.index) offset=\(Int(nearest.meters))m"
        )
        schedulePlanRebuild(
            delayNanoseconds: 900_000_000,
            showCalculatingImmediately: false
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
        stages = []
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
        stages = []
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
        // New stages always open as Dirt; rider changes per-stage after.
        let stageProfile: RouteProfile = .dirt
        if stages.isEmpty {
            stages.append(Stage(
                start: point,
                profile: stageProfile,
                allowUnknown: false
            ))
            refreshMap()
            return
        }
        if stages[stages.count - 1].end == nil {
            stages[stages.count - 1].end = point
        } else {
            let previousEnd = stages[stages.count - 1].end
            stages.append(Stage(
                start: previousEnd,
                end: point,
                profile: stageProfile,
                allowUnknown: false
            ))
        }
        let index = stages.count - 1
        stages[index].response = nil
        stages[index].error = nil
        toast = Self.calculatingRouteToast
        refreshMap()
        schedulePlanStageRoute(at: index)
    }

    /// Debounce a single new plan hop so rapid long-presses don't stack Dijkstras.
    private func schedulePlanStageRoute(at index: Int) {
        pendingPlanStageIndices.insert(index)
        planStageDebounceTask?.cancel()
        planStageDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 380_000_000)
            guard !Task.isCancelled else { return }
            let indices = pendingPlanStageIndices.sorted()
            pendingPlanStageIndices.removeAll()
            for i in indices {
                guard stages.indices.contains(i), stages[i].end != nil else { continue }
                await routeStage(at: i)
            }
        }
    }

    /// Per-stage surface mode (each stage is its own on-device routing request).
    func setStageProfile(_ newProfile: RouteProfile, at index: Int) {
        guard stages.indices.contains(index), stages[index].profile != newProfile else { return }
        if stages[index].fuelGroupID != nil, FuelRangePrefs.isEnabled {
            let allow = newProfile == .cleanest ? false : stages[index].allowUnknown
            Task {
                await rerouteFuelLeg(
                    at: index,
                    requestedProfile: newProfile,
                    requestedAllowUnknown: allow
                )
            }
            return
        }
        stages[index].profile = newProfile
        if newProfile == .cleanest { stages[index].allowUnknown = false }
        syncNetworkAccessPolicy()
        if stages[index].end != nil {
            Task { await routeStage(at: index) }
        }
    }

    /// Per-stage unknown-access policy.
    func setStageAllowUnknown(_ allow: Bool, at index: Int) {
        guard stages.indices.contains(index), stages[index].allowUnknown != allow else { return }
        if stages[index].fuelGroupID != nil, FuelRangePrefs.isEnabled {
            let requestedProfile = stages[index].profile
            Task {
                await rerouteFuelLeg(
                    at: index,
                    requestedProfile: requestedProfile,
                    requestedAllowUnknown: allow
                )
            }
            return
        }
        stages[index].allowUnknown = allow
        syncNetworkAccessPolicy()
        if stages[index].end != nil {
            Task { await routeStage(at: index) }
        }
    }

    /// Profile and access edits inside an expanded fuel leg are deliberately
    /// local. The selected stations remain fixed and only that one A→pump or
    /// pump→B hop is searched. A failed replacement restores the working leg.
    private func rerouteFuelLeg(
        at index: Int,
        requestedProfile: RouteProfile,
        requestedAllowUnknown: Bool
    ) async {
        guard stages.indices.contains(index),
              stages[index].fuelGroupID != nil,
              stages[index].start != nil,
              stages[index].end != nil
        else { return }

        let original = stages[index]
        let stageID = original.id
        let legName = stageEndpointTitle(at: index)
        stages[index].profile = requestedProfile
        stages[index].allowUnknown = requestedProfile == .cleanest ? false : requestedAllowUnknown
        fuelPlanNotice = nil
        toast = "Updating \(legName)"
        refreshMap()

        await routeStage(at: index, includeFuelAssist: false)

        guard let currentIndex = stages.firstIndex(where: { $0.id == stageID }),
              stages[currentIndex].profile == requestedProfile,
              stages[currentIndex].allowUnknown == (requestedProfile == .cleanest ? false : requestedAllowUnknown)
        else { return }
        if stages[currentIndex].response != nil, stages[currentIndex].error == nil {
            fuelPlanNotice = "\(legName) updated to \(requestedProfile.title). Other fuel legs were unchanged."
            toast = "Fuel leg updated"
            refreshMap()
            return
        }

        stages[currentIndex] = original
        errorMessage = nil
        fuelPlanNotice = "\(requestedProfile.title) could not connect \(legName). The working \(original.profile.title) leg was kept; other legs were unchanged."
        toast = "Kept the working fuel leg"
        RoutingDebugLog.shared.event(
            "fuel single-leg reroute failed requested=\(requestedProfile.rawValue) kept=\(original.profile.rawValue) leg=\(legName)"
        )
        refreshMap()
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
        mapState.selectPlannerPin(nil)
        errorMessage = nil

        let primaryIndex = stages.prefix(index + 1).filter { !$0.endsAtFuelStop }.count - 1
        var primary = collapsedPrimaryPlanStages()
        guard primary.indices.contains(primaryIndex) else { return }

        _ = beginFuelAssistJob()
        invalidateInFlightRoutes()

        if primary.count == 1 {
            stages = []
            routeIdentity = nil
            refreshMap()
            return
        }

        if primaryIndex < primary.count - 1 {
            primary[primaryIndex + 1].start = primary[primaryIndex].start
            primary[primaryIndex + 1].response = nil
            primary[primaryIndex + 1].error = nil
        }

        primary.remove(at: primaryIndex)
        stages = primary

        routeIdentity = "plan:" + stages.compactMap { stage in
            stage.end.map { "\($0.latitude),\($0.longitude)" }
        }.joined(separator: ";")

        refreshMap()
        RoutingDebugLog.shared.event(
            "ui rider leg deleted expanded=\(index) primary=\(primaryIndex) remaining=\(stages.count)"
        )
        schedulePlanRebuild(delayNanoseconds: 120_000_000)
    }

    // MARK: - Routing

    func routeFromHere() async {
        let origin = fromHereStartOverride ?? locationService.currentCoordinate
        guard let origin else {
            errorMessage = "Waiting for GPS — allow location access to route from here."
            if toast == Self.calculatingRouteToast { toast = nil }
            return
        }
        guard let requestedDest = destination else { return }
        let requestedStart = fromHereStartOverride

        // Fuel assist promotes From here into `stages` (A→fuel→B). Profile /
        // Allow Unknown / destination retaps must drop that chain first —
        // otherwise `activeResponses` keeps painting stale stage geometry while
        // this method only rewrites `fromHereResponse` (line looks frozen).
        if mode == .fromHere, !stages.isEmpty {
            for index in stages.indices {
                stages[index].routeGeneration += 1
                stages[index].isRouting = false
            }
            stages = []
        }

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

        // GPS / camp far from any pack edge → ask for a road tap for A.
        // Within preferredMatchMeters we soft-stitch onto the road and route.
        let usingGPSStart = requestedStart == nil
        if usingGPSStart {
            let cl = CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude)
            if Self.installedPacksCover(ends: [cl], store: graphPacks) {
                await graphPacks.ensureRoadShapes(for: [cl])
                let distance = await graphPacks.distanceToNearestRoad(
                    from: cl,
                    allowUnknown: requestedAllow,
                    profile: requestedProfile
                )
                if distance == nil || distance! > OnDeviceRouter.preferredMatchMeters {
                    guard generation == fromHereRouteGeneration else { return }
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

        do {
            if FuelRangePrefs.isEnabled, FuelRangePrefs.kilometers > 0 {
                stages = [Stage(
                    start: origin,
                    end: requestedDest,
                    profile: requestedProfile,
                    allowUnknown: requestedAllow
                )]
                fromHereResponse = nil
                refreshMap()
                let job = beginFuelAssistJob()
                // Fuel is an ordered waypoint constraint, not a detour off a
                // finished route. Build forward: start → fuel → destination.
                // Each fuel stop therefore becomes the next routing origin
                // instead of a spur that returns to an earlier random ride.
                await expandStageIntoFuelItinerary(at: 0, job: job)
                guard generation == fromHereRouteGeneration,
                      mode == requestedMode,
                      profile == requestedProfile,
                      allowUnknown == requestedAllow,
                      destinationMatches(requestedDest),
                      coordinateMatches(fromHereStartOverride, requestedStart)
                else { return }
                fromHereNeedsStartPin = false
                if let last = stages.last?.end {
                    destination = last
                }
                let finalDest = destination ?? requestedDest
                routeIdentity = "here:\(finalDest.latitude),\(finalDest.longitude):\(requestedProfile.rawValue)"
                refreshMap()
                if let last = stages.last?.end {
                    mapState.fit([origin, last])
                }
                isAssemblingRoute = false
                if let last = stages.last {
                    mapState.selectPlannerPin(stageMarkerID(last))
                } else {
                    mapState.selectPlannerPin("dest")
                }
                announceRouteReadyIfComplete()
                return
            }

            let response = try await routeForPlanning(
                from: origin,
                to: requestedDest,
                profile: requestedProfile,
                allowUnknown: requestedAllow
            )
            // Drop stale replies — rapid retap / profile / mode / clear can outrun search.
            guard generation == fromHereRouteGeneration,
                  mode == requestedMode,
                  profile == requestedProfile,
                  allowUnknown == requestedAllow,
                  destinationMatches(requestedDest),
                  coordinateMatches(fromHereStartOverride, requestedStart)
            else { return }

            fromHereResponse = response
            fromHereNeedsStartPin = false
            // Move pins to geometry endpoints after the pack snaps to the road.
            // so markers sit on the road, not at the raw tap coordinate.
            // GPS From-here keeps the puck as A — do not sticky-override onto a
            // pack edge (that forced Allow-unknown snaps and false “tap A” recovery).
            if fromHereStartOverride != nil, let snappedStart = response.coordinates.first {
                fromHereStartOverride = snappedStart
            }
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
            isAssemblingRoute = false
            announceRouteReadyIfComplete()
            guard generation == fromHereRouteGeneration else { return }
            isAssemblingRoute = false
            // Select B so it’s obvious; relocate is long-press only (pin is locked).
            if let last = stages.last {
                mapState.selectPlannerPin(stageMarkerID(last))
            } else {
                mapState.selectPlannerPin("dest")
            }
            announceRouteReadyIfComplete()
        } catch is CancellationError {
            // A newer drag, profile, or fuel job superseded this request.
            // Keep the current route visible; the replacement owns the UI.
            return
        } catch let error as NSError
            where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            return
        } catch {
            guard generation == fromHereRouteGeneration else { return }
            isAssemblingRoute = false
            fromHereResponse = nil
            RoutingDebugLog.shared.routeFailure(error, context: "fromHere")
            mapState.unlockAfterRouteFailure()
            if await shouldEnterFromHereStartRecovery(
                error: error,
                usingGPSStart: usingGPSStart,
                origin: origin
            ) {
                let cl = CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude)
                await graphPacks.ensureRoadShapes(for: [cl])
                let meters = await graphPacks.distanceToNearestRoad(
                    from: cl,
                    allowUnknown: allowUnknown,
                    profile: profile
                ).map { Int($0.rounded()) }
                enterFromHereNeedsStartPin(startMeters: meters)
                RoutingDebugLog.shared.event(
                    "recovery needsStartPin meters=\(meters.map(String.init) ?? "nil")"
                )
            } else {
                fromHereNeedsStartPin = false
                errorMessage = error.localizedDescription
            }
            toast = nil
            refreshMap()
        }
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

    /// URLSession cancellation can arrive bridged as NSError, particularly
    /// when a pin drag supersedes a live-pack request. That is normal control
    /// flow, never a rider-facing routing failure.
    private static func isRequestCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    func routeStage(at index: Int, includeFuelAssist: Bool = true) async {
        guard stages.indices.contains(index),
              let start = stages[index].start,
              let end = stages[index].end else { return }

        let fuelUpFront = includeFuelAssist
            && FuelRangePrefs.isEnabled
            && (mode == .plan || mode == .fromHere)
            && !stages[index].skipFuelAssist
        if fuelUpFront {
            let job = beginFuelAssistJob()
            if mode == .plan {
                // A shaping waypoint is not a petrol station. Plan the entire
                // rider itinerary so the tank budget carries through ordinary
                // A→via→B boundaries instead of resetting at every pin.
                await rebuildPrimaryPlanThenFuelAssist(job: job)
            } else {
                await expandStageIntoFuelItinerary(at: index, job: job)
            }
            return
        }

        let stageID = stages[index].id
        stages[index].routeGeneration += 1
        let generation = stages[index].routeGeneration
        let requestedProfile = stages[index].profile
        let requestedAllow = stages[index].allowUnknown
        let requestedMaxRouteMeters = stages[index].maxRouteMeters
        let requestedLegName = stageEndpointTitle(at: index)
        let continuityAvoidEdgeIds = stageContinuityAvoidEdgeIds(at: index)

        stages[index].isRouting = true
        stages[index].error = nil
        isRouting = true
        errorMessage = nil
        defer {
            if let idx = stages.firstIndex(where: { $0.id == stageID }),
               stages[idx].routeGeneration == generation {
                stages[idx].isRouting = false
            }
            isRouting = stages.contains(where: \.isRouting)
        }
        do {
            let response: RouteResponse
            do {
                response = try await routeForPlanning(
                    from: start,
                    to: end,
                    profile: requestedProfile,
                    allowUnknown: requestedAllow,
                    maxRouteMeters: requestedMaxRouteMeters,
                    avoidEdgeIds: continuityAvoidEdgeIds
                )
            } catch {
                if Self.isRequestCancellation(error) {
                    throw CancellationError()
                }
                guard !continuityAvoidEdgeIds.isEmpty,
                      Self.isNoRouteFailure(error)
                else { throw error }
                // Backtracking is a fallback, never the first choice. If the
                // graph has no alternate exit from this waypoint, remove the
                // continuity wall rather than declaring a false no-route.
                RoutingDebugLog.shared.event(
                    "route continuity fallback stage=\(index) — prior-edge wall disconnected"
                )
                response = try await routeForPlanning(
                    from: start,
                    to: end,
                    profile: requestedProfile,
                    allowUnknown: requestedAllow,
                    maxRouteMeters: requestedMaxRouteMeters
                )
            }
            // Resolve by stable stage id — index may have shifted (delete / reorder).
            guard let idx = stages.firstIndex(where: { $0.id == stageID }),
                  stages[idx].routeGeneration == generation,
                  stages[idx].profile == requestedProfile,
                  stages[idx].allowUnknown == requestedAllow,
                  stages[idx].maxRouteMeters == requestedMaxRouteMeters,
                  coordinateMatches(stages[idx].start, start),
                  coordinateMatches(stages[idx].end, end)
            else { return }

            // Snap stage pins to geometry endpoints so markers sit on the road
            // after waypoints snap to the nearest graph edge.
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
            stages[idx].error = nil
            // Prior leg failures leave a sticky banner; clear unless another stage is still broken.
            errorMessage = stages.first(where: { $0.error != nil })?.error
            routeIdentity = "plan:" + stages.compactMap { stage in
                stage.end.map { "\($0.latitude),\($0.longitude)" }
            }.joined(separator: ";")
            refreshMap()
            if let fitStart = stages[idx].start, let fitEnd = stages[idx].end {
                mapState.fit([fitStart, fitEnd])
            }

            announceRouteReadyIfComplete()
        } catch let error where Self.isRequestCancellation(error) {
            // A newer pin position or route choice owns the replacement work.
            return
        } catch {
            let displayError = await explainedStageRouteFailure(
                error,
                from: start,
                to: end,
                legName: requestedLegName,
                requestedProfile: requestedProfile,
                requestedAllowUnknown: requestedAllow,
                maxRouteMeters: requestedMaxRouteMeters
            )
            guard let idx = stages.firstIndex(where: { $0.id == stageID }),
                  stages[idx].routeGeneration == generation else { return }
            stages[idx].response = nil
            stages[idx].error = displayError
            errorMessage = displayError
            toast = nil
            RoutingDebugLog.shared.routeFailure(error, context: "stage[\(idx)]")
            mapState.unlockAfterRouteFailure()
            refreshMap()
        }
    }

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

    private func explainedStageRouteFailure(
        _ error: Error,
        from: RouteCoordinate,
        to: RouteCoordinate,
        legName: String,
        requestedProfile: RouteProfile,
        requestedAllowUnknown: Bool,
        maxRouteMeters: Double?
    ) async -> String {
        guard requestedProfile != .cleanest, Self.isNoRouteFailure(error) else {
            return error.localizedDescription
        }
        let cleanConnects: Bool
        do {
            _ = try await routeForPlanning(
                from: from,
                to: to,
                profile: .cleanest,
                allowUnknown: false,
                maxRouteMeters: maxRouteMeters
            )
            cleanConnects = true
        } catch {
            cleanConnects = false
        }
        return Self.profileRouteFailureMessage(
            requestedProfile: requestedProfile,
            legName: legName,
            maxRouteMeters: maxRouteMeters,
            cleanConnects: cleanConnects,
            allowUnknown: requestedAllowUnknown
        )
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
    private func invalidateInFlightRoutes(cancelPlanRebuildTask: Bool = true) {
        fromHereRouteGeneration += 1
        fromHereRouteDebounceTask?.cancel()
        if cancelPlanRebuildTask {
            planRebuildDebounceTask?.cancel()
        }
        planStageDebounceTask?.cancel()
        pendingPlanStageIndices.removeAll()
        for index in stages.indices {
            stages[index].routeGeneration += 1
            stages[index].isRouting = false
        }
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
                if !stages.isEmpty {
                    await rebuildFromHereWithFuelAssist()
                } else if destination != nil {
                    await routeFromHere()
                }
            case .saved:
                if destination != nil {
                    await routeFromHere()
                }
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
                fromHereResponse = response
                mode = .fromHere
                destination = target
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
            refreshMap()
            Task { await routeFromHere() }
        case .plan:
            movePlanStyleWaypoint(markerID: markerID, snapped: snapped)
        }
    }

    private func movePlanStyleWaypoint(markerID: String, snapped: RouteCoordinate) {
        if markerID == "s0" {
            guard !stages.isEmpty else { return }
            stages[0].start = snapped
            stages[0].response = nil
        } else if let index = stages.firstIndex(where: { stageMarkerID($0) == markerID }) {
            // Fuel pins are locked — only primary waypoints move.
            if stages[index].endsAtFuelStop {
                return
            }
            stages[index].end = snapped
            stages[index].response = nil
            if stages.indices.contains(index + 1) {
                stages[index + 1].start = snapped
                stages[index + 1].response = nil
            }
        } else {
            return
        }

        // Collapse auto fuel stops, re-route primary hops, then re-seat fuel.
        // Debounce: dragging/nudging pins was firing rebuilds immediately.
        mapState.selectPlannerPin(nil)
        schedulePlanRebuild()
    }

    private func schedulePlanRebuild(
        delayNanoseconds: UInt64 = 420_000_000,
        showCalculatingImmediately: Bool = true
    ) {
        planRebuildDebounceTask?.cancel()
        if showCalculatingImmediately { toast = Self.calculatingRouteToast }
        planRebuildDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            toast = Self.calculatingRouteToast
            await rebuildPrimaryPlanThenFuelAssist()
        }
    }

    /// Drop F-pins, keep rider-placed A / vias / B, re-route, then re-apply fuel.
    private func rebuildPrimaryPlanThenFuelAssist(
        rangeKm requestedRangeKm: Double? = nil,
        job existingFuelJob: Int? = nil
    ) async {
        let rebuilt = collapsedPrimaryPlanStages()
        guard !rebuilt.isEmpty else {
            refreshMap()
            return
        }
        // This method can run inside `planRebuildDebounceTask`. Cancelling that
        // task here cancelled its own live fuel request and surfaced a false
        // “live fuel unavailable” error after every shaping-pin move.
        invalidateInFlightRoutes(cancelPlanRebuildTask: false)
        stages = rebuilt
        refreshMap()
        isAssemblingRoute = true
        toast = Self.calculatingRouteToast
        if FuelRangePrefs.isEnabled {
            let job = existingFuelJob ?? beginFuelAssistJob()
            // Fuel stops define a fresh, forward itinerary. Do not first lock
            // each rider leg to a random full-distance route and then force a
            // pump spur to return to it.
            for index in stages.indices {
                stages[index].response = nil
                stages[index].error = nil
            }
            // Fuel pins are committed only if the entire chain succeeds; a
            // later failure must never leave partial F pins behind.
            let primaryBaseline = stages
            let rangeKm = requestedRangeKm ?? FuelRangePrefs.kilometers
            let tankMeters = FuelRangePrefs.usableKilometers(for: rangeKm) * 1_000
            RoutingDebugLog.shared.event(
                "fuel primary itinerary stages=\(primaryBaseline.count) usable=\(Int(tankMeters))m"
            )
            var usedSinceFuelMeters = 0.0
            var i = 0
            while i < stages.count {
                guard job == fuelAssistGeneration, !Task.isCancelled else { return }
                let before = stages.count
                let currentMeters = stages[i].response?.distanceMeters ?? 0
                let nextPrimaryMeters = stages[(i + 1)...].first(where: {
                    !$0.endsAtFuelStop
                })?.response?.distanceMeters
                let arrivalUse = usedSinceFuelMeters + currentMeters
                // If this leg consumes essentially the whole tank and another
                // rider leg follows, refuel before the waypoint. Otherwise the
                // next leg would begin with an impossible near-empty tank.
                let refuelBeforeWaypoint = nextPrimaryMeters != nil
                    && arrivalUse <= tankMeters + 1
                    && arrivalUse + (nextPrimaryMeters ?? 0) > tankMeters
                    && arrivalUse >= tankMeters * HopSearchPolicy.fuelPreferTank
                await expandStageIntoFuelItinerary(
                    at: i,
                    job: job,
                    rangeKm: requestedRangeKm,
                    startingFuelUsedMeters: usedSinceFuelMeters,
                    requireFuelStopBeforeEnd: refuelBeforeWaypoint
                )
                guard job == fuelAssistGeneration, !Task.isCancelled else { return }
                let blockCount = max(1, stages.count - before + 1)
                let blockEnd = min(stages.count, i + blockCount)
                let block = Array(stages[i..<blockEnd])
                guard block.allSatisfy({ $0.response != nil && $0.error == nil }) else {
                    let failure = stages[i...].first(where: { $0.error != nil })?.error
                    stages = primaryBaseline
                    if stages.indices.contains(i) {
                        stages[i].error = failure ?? "Fuel planning could not complete this itinerary."
                    }
                    errorMessage = failure
                    isAssemblingRoute = false
                    refreshMap()
                    return
                }
                if let lastFuelOffset = block.lastIndex(where: \.endsAtFuelStop) {
                    usedSinceFuelMeters = block[(lastFuelOffset + 1)...].reduce(0) {
                        $0 + ($1.response?.distanceMeters ?? 0)
                    }
                } else {
                    usedSinceFuelMeters += block.reduce(0) {
                        $0 + ($1.response?.distanceMeters ?? 0)
                    }
                }
                RoutingDebugLog.shared.event(
                    "fuel carried past waypoint used=\(Int(usedSinceFuelMeters))m tank=\(Int(tankMeters))m"
                )
                i += blockCount
            }
        } else {
            for index in stages.indices {
                await routeStage(at: index, includeFuelAssist: false)
            }
        }
        isAssemblingRoute = false
        refreshMap()
        announceRouteReadyIfComplete()
    }

    /// Collapse only auto-generated fuel hops. Rider-created stage boundaries
    /// retain their own profile and Allow setting when tank range changes.
    private func collapsedPrimaryPlanStages() -> [Stage] {
        guard let firstStart = stages.first?.start else { return [] }
        var start = firstStart
        var result: [Stage] = []
        for stage in stages {
            guard let end = stage.end else { continue }
            if stage.endsAtFuelStop { continue }
            var collapsed = Stage(
                start: start,
                end: end,
                profile: stage.profile,
                allowUnknown: stage.allowUnknown
            )
            if coordinateMatches(stage.start, start) {
                collapsed.response = stage.response
            }
            result.append(collapsed)
            start = end
        }
        return result
    }

    /// Rider-placed waypoints only (A, vias, B) — excludes auto fuel ends.
    private func primaryPlanWaypoints() -> [RouteCoordinate] {
        guard !stages.isEmpty else { return [] }
        var points: [RouteCoordinate] = []
        if let start = stages[0].start {
            points.append(start)
        }
        for stage in stages {
            guard let end = stage.end else { continue }
            if !stage.endsAtFuelStop {
                points.append(end)
            }
        }
        if let last = stages.last?.end,
           points.last.map({ !coordinateMatches($0, last) }) ?? true {
            points.append(last)
        }
        return points
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
        stages = []
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
        fromHereNeedsStartPin = false
        fromHereStartOverride = nil
        stages = []
        fuelPlanningStatus = nil
        fuelPreviewStops = []
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
        // Do not let a From-here fuel search keep probing stations after the
        // rider has changed intent to Plan. The newly chosen plan owns any
        // later fuel work.
        _ = beginFuelAssistJob()
        invalidateInFlightRoutes()

        // A fuel-assisted From here route already contains a complete A→F…→B
        // itinerary. Keep it instead of making the same live requests again.
        if !stages.isEmpty {
            let finalEnd = stages.last?.end
            destination = nil
            destinationName = nil
            fromHereResponse = nil
            fromHereNeedsStartPin = false
            fromHereStartOverride = nil
            errorMessage = nil
            mode = .plan
            // From-here leaves B selected because it is locked in that mode.
            // Plan uses an unselected route tap to create a shaping waypoint;
            // carrying B's selection across would move B instead.
            mapState.selectPlannerPin(nil)
            routeIdentity = "plan:" + stages.compactMap { stage in
                stage.end.map { "\($0.latitude),\($0.longitude)" }
            }.joined(separator: ";")
            refreshMap()
            if let start = stages.first?.start, let finalEnd {
                mapState.fit([start, finalEnd])
            }
            toast = "Fuel plan kept"
            RoutingDebugLog.shared.event("ui fromHere→plan preserved fuel hops=\(stages.count)")
            return
        }

        let end = destination ?? fromHereResponse?.coordinates.last
        let start = fromHereResponse?.coordinates.first
            ?? fromHereStartOverride
            ?? locationService.currentCoordinate
        let keptResponse = fromHereResponse
        let keptProfile = profile
        let keptAllow = allowUnknown

        destination = nil
        destinationName = nil
        fromHereResponse = nil
        fromHereNeedsStartPin = false
        fromHereStartOverride = nil
        errorMessage = nil
        stages = []

        mode = .plan
        mapState.selectPlannerPin(nil)

        guard let start, let end else {
            refreshMap()
            return
        }
        var stage = Stage(
            start: start,
            end: end,
            profile: keptProfile,
            allowUnknown: keptAllow
        )
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
        stages = []

        // savedRouteOrigin is deliberately kept: edits made from here save back to the
        // library record the rider opened, rather than forking a near-identical copy.
        mode = .plan
        var stage = Stage(
            start: start,
            end: end,
            profile: keptProfile,
            allowUnknown: keptAllow
        )
        stage.response = response
        stages = [stage]
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
        stages = []
        errorMessage = nil
        routeIdentity = nil
        savedRouteOrigin = nil
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
        stages = []
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
        mapState.setRoute(MapState.displaySegments(from: activeResponses))
        var markers: [MapState.Marker] = []
        switch mode {
        case .fromHere:
            if !stages.isEmpty {
                var fuelOrdinal = 0
                for (index, stage) in stages.enumerated() {
                    if let start = stage.start, index == 0 {
                        markers.append(
                            MapState.Marker(
                                id: "s0",
                                latitude: start.latitude,
                                longitude: start.longitude,
                                label: "1",
                                kind: .start,
                                isLocked: true
                            )
                        )
                    }
                    if let end = stage.end {
                        // Do not present a provisional fuel chain as committed.
                        // Preview pumps remain visible while it is being checked;
                        // actual F pins appear together after the whole chain wins.
                        if stage.endsAtFuelStop && isAssemblingRoute { continue }
                        let isLast = index == stages.count - 1
                        let label: String
                        if stage.endsAtFuelStop {
                            fuelOrdinal += 1
                            label = "F\(fuelOrdinal)"
                        } else if isLast {
                            label = "2"
                        } else {
                            label = "\(index + 2)"
                        }
                        markers.append(
                            MapState.Marker(
                                id: stageMarkerID(stage),
                                latitude: end.latitude,
                                longitude: end.longitude,
                                label: label,
                                kind: isLast ? .destination : (stage.endsAtFuelStop ? .fuel : .stage),
                                subtitle: stage.fuelStopName,
                                // From here: long-press relocates B — no pin dragging.
                                isLocked: true
                            )
                        )
                    }
                }
            } else if let destination {
                if let start = fromHereResponse?.coordinates.first ?? fromHereStartOverride {
                    markers.append(
                        MapState.Marker(
                            id: "s0",
                            latitude: start.latitude,
                            longitude: start.longitude,
                            label: "1",
                            kind: .start,
                            isLocked: true
                        )
                    )
                }
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
            var fuelOrdinal = 0
            var waypointOrdinal = 1
            for (index, stage) in stages.enumerated() {
                if let start = stage.start, index == 0 {
                markers.append(MapState.Marker(id: "s0", latitude: start.latitude, longitude: start.longitude, label: "1", kind: .start))
                }
                if let end = stage.end {
                    if stage.endsAtFuelStop && isAssemblingRoute { continue }
                    let isLast = index == stages.count - 1
                    let label: String
                    if stage.endsAtFuelStop {
                        fuelOrdinal += 1
                        label = "F\(fuelOrdinal)"
                    } else {
                        // Plan is one ordered waypoint sequence. Its labels
                        // always match stage order, including the final point.
                        waypointOrdinal += 1
                        label = "\(waypointOrdinal)"
                    }
                    markers.append(
                        MapState.Marker(
                            id: stageMarkerID(stage),
                            latitude: end.latitude,
                            longitude: end.longitude,
                            label: label,
                            kind: isLast ? .destination : (stage.endsAtFuelStop ? .fuel : .stage),
                            subtitle: stage.fuelStopName,
                            isLocked: stage.endsAtFuelStop
                        )
                    )
                }
            }
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
        let riders = mapState.markers.filter { $0.kind.isGroupOverlay }
        mapState.setMarkers(markers + riders)
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
        stages = []
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
        var stage = Stage(
            start: start,
            end: end,
            profile: profile,
            allowUnknown: allowUnknown
        )
        stage.response = response
        stages = [stage]
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
        guard hasRoute || fromHereResponse != nil || !stages.isEmpty else { return }
        FuelRangePrefs.kilometers = rangeKm
        FuelRangePrefs.lastEnabledKilometers = rangeKm
        fuelPlanNotice = nil

        RoutingDebugLog.shared.event(
            "fuel reapply start mode=\(mode) stages=\(stages.count) range=\(Int(rangeKm))km"
        )
        toast = "Looking for fuel stops"
        let job = beginFuelAssistJob()
        planRebuildDebounceTask?.cancel()
        Task { @MainActor in
            guard job == fuelAssistGeneration else { return }
            switch mode {
            case .fromHere:
                await rebuildFromHereWithFuelAssist()
            case .plan:
                await rebuildPrimaryPlanThenFuelAssist(rangeKm: rangeKm, job: job)
            case .saved:
                break
            }
            guard job == fuelAssistGeneration else { return }
            RoutingDebugLog.shared.event("fuel reapply done stages=\(stages.count)")
        }
    }

    /// Invalidates an in-flight itinerary as soon as the rider grabs the fuel
    /// slider. The released value starts exactly one replacement job.
    func cancelFuelAssistForRangeEdit() {
        _ = beginFuelAssistJob()
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
        _ = beginFuelAssistJob()
        fuelPlanningStatus = nil
        fuelPreviewStops = []
        errorMessage = nil
        toast = Self.calculatingRouteToast
        for index in stages.indices {
            stages[index].error = nil
            stages[index].skipFuelAssist = true
        }

        Task { @MainActor in
            switch mode {
            case .fromHere:
                await routeFromHere()
            case .plan:
                await rebuildPrimaryPlanThenFuelAssist()
            case .saved:
                break
            }
        }
    }

    /// From here: wipe any fuel chain, re-route start→B, then insert fuel stops.
    private func rebuildFromHereWithFuelAssist() async {
        guard mode == .fromHere else { return }
        let dest = destination ?? stages.last?.end ?? fromHereResponse?.coordinates.last
        guard let dest else { return }
        stages = []
        fromHereResponse = nil
        destination = dest
        isAssemblingRoute = true
        toast = Self.calculatingRouteToast
        mapState.selectPlannerPin(nil)
        refreshMap()
        await routeFromHere()
    }

    private func beginFuelAssistJob() -> Int {
        fuelAssistGeneration += 1
        return fuelAssistGeneration
    }

    /// Build A → F₁ → … → B from graph reach + progress, then route each hop.
    /// Never draws a full A→B line first and sprinkles pumps on it.
    private func expandStageIntoFuelItinerary(
        at index: Int,
        job: Int,
        rangeKm requestedRangeKm: Double? = nil,
        startingFuelUsedMeters: Double = 0,
        requireFuelStopBeforeEnd: Bool = false
    ) async {
        guard job == fuelAssistGeneration else { return }
        guard stages.indices.contains(index),
              let start = stages[index].start,
              let end = stages[index].end
        else { return }
        fuelPlanningStatus = "Finding a connected fuel chain…"
        fuelPreviewStops = []
        refreshMap()
        defer {
            if job == fuelAssistGeneration {
                fuelPlanningStatus = nil
                fuelPreviewStops = []
                refreshMap()
            }
        }
        let rangeKm = requestedRangeKm ?? FuelRangePrefs.kilometers
        let profile = stages[index].profile
        let allow = stages[index].allowUnknown
        stages[index].error = nil
        errorMessage = nil
        guard rangeKm > 0 else {
            stages[index].skipFuelAssist = true
            await routeStage(at: index, includeFuelAssist: false)
            return
        }
        let usableRangeKm = FuelRangePrefs.usableKilometers(for: rangeKm)
        let tank = usableRangeKm * 1000
        let firstHopCap = max(0, tank - max(0, startingFuelUsedMeters))
        let startCL = CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude)
        let endCL = CLLocationCoordinate2D(latitude: end.latitude, longitude: end.longitude)
        let localFuelGraphAvailable = !network.isOnline && Self.installedPacksCover(
            ends: [startCL, endCL], store: graphPacks
        )

        if localFuelGraphAvailable,
           let startRegion = GraphPackStore.primaryRegionId(containing: startCL),
           let endRegion = GraphPackStore.primaryRegionId(containing: endCL),
           startRegion != endRegion {
            let message = "Fuel assist currently needs each stage to stay inside one regional pack. Add a waypoint near the \(startRegion.uppercased())–\(endRegion.uppercased()) boundary."
            stages[index].response = nil
            stages[index].error = message
            errorMessage = message
            toast = message
            isAssemblingRoute = false
            RoutingDebugLog.shared.event(
                "fuel itinerary stopped — cross-pack stage \(startRegion)->\(endRegion)"
            )
            mapState.unlockAfterRouteFailure()
            refreshMap()
            return
        }

        // Online, same-region fuel planning is one bounded graph operation.
        // It returns only the ordered pumps; we then build and reveal the final
        // ride linearly as point 1 → F1 → … → point 2. No disposable full route
        // is generated and no candidate pump triggers its own route search.
        if network.isOnline {
            do {
                try await buildLiveFuelChain(
                    at: index,
                    job: job,
                    start: start,
                    end: end,
                    profile: profile,
                    allowUnknown: allow,
                    tankMeters: tank,
                    firstHopCapMeters: firstHopCap,
                    requireFuelStopBeforeEnd: requireFuelStopBeforeEnd
                )
            } catch is CancellationError {
                return
            } catch let error as NSError
                where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                return
            } catch {
                guard job == fuelAssistGeneration, stages.indices.contains(index) else { return }
                let message = error.localizedDescription
                stages[index].response = nil
                stages[index].error = message
                errorMessage = message
                toast = message
                isAssemblingRoute = false
                RoutingDebugLog.shared.event("fuel forward planner failed — \(message)")
                mapState.unlockAfterRouteFailure()
                refreshMap()
            }
            return
        }

        let remaining = localFuelGraphAvailable
            ? await graphPacks.shortestGraphMeters(
                from: startCL, to: endCL,
                maxMeters: firstHopCap * HopSearchPolicy.fuelSkipIfWithin,
                profile: profile, allowUnknown: allow
            )
            : nil
        if let remaining,
           remaining <= firstHopCap * HopSearchPolicy.fuelSkipIfWithin,
           !requireFuelStopBeforeEnd {
            RoutingDebugLog.shared.event(
                "fuel itinerary hop within tank m=\(Int(remaining)) tank=\(Int(rangeKm))km"
            )
            stages[index].skipFuelAssist = true
            await routeStage(at: index, includeFuelAssist: false)
            return
        }

        guard let poiManager else {
            toast = "Fuel assist unavailable"
            RoutingDebugLog.shared.event("fuel itinerary skipped — no POI manager")
            stages[index].skipFuelAssist = true
            await routeStage(at: index, includeFuelAssist: false)
            return
        }

        RoutingDebugLog.shared.event(
            "fuel itinerary start stage[\(index)] tank=\(Int(rangeKm))km remaining=\(remaining.map { String(Int($0)) } ?? "nil")"
        )
        let fuels: [POIFeature]
        do {
            fuels = try await poiManager.fuelCandidates(
                from: start,
                to: end,
                preferLive: network.isOnline
            )
        } catch is CancellationError {
            // A newer pin position superseded this job. Keep the last complete
            // route visible; the replacement rebuild owns the UI status.
            return
        } catch {
            guard job == fuelAssistGeneration, stages.indices.contains(index) else { return }
            let message = error.localizedDescription
            stages[index].error = message
            errorMessage = message
            toast = message
            isAssemblingRoute = false
            RoutingDebugLog.shared.event("fuel itinerary source failed — \(message)")
            mapState.unlockAfterRouteFailure()
            refreshMap()
            return
        }
        guard job == fuelAssistGeneration else { return }
        RoutingDebugLog.shared.event("fuel itinerary candidates=\(fuels.count)")

        // Search complete pump chains. The old loop remembered a rejected pump
        // globally, so backtracking from F2 could accidentally ban a pump that
        // was valid after a different F1. Each branch now owns its visited set.
        var searchStates = 0
        let maxSearchStates = 48
        let maxFuelStops = 12
        let fuelSearchDeadline = Date().addingTimeInterval(25)
        var verifiedLiveLegs: [String: RouteResponse] = [:]

        func liveLegKey(_ a: RouteCoordinate, _ b: RouteCoordinate) -> String {
            String(format: "%.6f,%.6f>%.6f,%.6f", a.latitude, a.longitude, b.latitude, b.longitude)
        }

        // A corridor request within one tank is already a verified final leg.
        // Reusing it avoids the duplicate A→B request visible in short-route logs.
        if !localFuelGraphAvailable,
           let corridor = stages[index].response,
           let meters = corridor.distanceMeters,
           meters <= tank + 1 {
            verifiedLiveLegs[liveLegKey(start, end)] = corridor
        }

        func verifiedLiveLeg(
            from a: RouteCoordinate,
            to b: RouteCoordinate,
            capMeters: Double
        ) async -> RouteResponse? {
            let key = liveLegKey(a, b)
            if let cached = verifiedLiveLegs[key],
               let meters = cached.distanceMeters,
               meters <= capMeters + 1 {
                return cached
            }
            guard network.isOnline else { return nil }
            do {
                let response = try await routeForPlanning(
                    from: a,
                    to: b,
                    profile: profile,
                    allowUnknown: allow,
                    maxRouteMeters: capMeters
                )
                guard let meters = response.distanceMeters, meters <= capMeters + 1 else {
                    RoutingDebugLog.shared.event(
                        "fuel live reject over-range m=\(Int(response.distanceMeters ?? 0)) cap=\(Int(capMeters))"
                    )
                    return nil
                }
                verifiedLiveLegs[key] = response
                return response
            } catch {
                RoutingDebugLog.shared.event(
                    "fuel live reject \(a.latitude),\(a.longitude)->\(b.latitude),\(b.longitude): \(error.localizedDescription)"
                )
                return nil
            }
        }

        func findFuelChain(
            from current: RouteCoordinate,
            visited: Set<String>,
            depth: Int,
            previewPath: [RouteCoordinate]
        ) async -> [RouteCoordinate]? {
            guard job == fuelAssistGeneration,
                  depth <= maxFuelStops,
                  searchStates < maxSearchStates,
                  Date() < fuelSearchDeadline
            else { return nil }
            searchStates += 1
            let hopCap = depth == 0 ? firstHopCap : tank
            guard hopCap > 0 else { return nil }

            fuelPlanningStatus = depth == 0
                ? "Mapping your first fuel leg…"
                : "Mapping onward from fuel stop \(depth)…"
            refreshMap()

            let curCL = CLLocationCoordinate2D(
                latitude: current.latitude, longitude: current.longitude
            )
            let rem: Double?
            // Crow-flies distance is a safe lower bound. If it already exceeds
            // one tank, avoid a guaranteed-to-fail live route request.
            if GeoMath.meters(current, end) > hopCap {
                rem = nil
            } else if localFuelGraphAvailable {
                rem = await graphPacks.shortestGraphMeters(
                    from: curCL, to: endCL,
                    maxMeters: hopCap,
                    profile: profile, allowUnknown: allow
                )
            } else {
                if let response = await verifiedLiveLeg(
                    from: current,
                    to: end,
                    capMeters: hopCap
                ) {
                    rem = response.distanceMeters
                } else {
                    rem = nil
                }
            }
            guard job == fuelAssistGeneration else { return nil }
            if let rem,
               rem <= hopCap,
               !(depth == 0 && requireFuelStopBeforeEnd) {
                fuelPlanningStatus = depth == 0
                    ? "Route fits within one tank"
                    : "Connecting the final leg…"
                if depth > 0 { mapState.fit([current, end]) }
                RoutingDebugLog.shared.event(
                    "fuel itinerary finish depth=\(depth) remaining=\(Int(rem))m"
                )
                return [end]
            }
            guard depth < maxFuelStops else { return nil }

            let reach: [String: Double]
            let ranked: [POIFeature]
            if localFuelGraphAvailable {
                reach = await graphPacks.reachableFuelMeters(
                    from: curCL, toward: endCL, pumps: fuels,
                    maxMeters: hopCap * HopSearchPolicy.fuelMaxTank,
                    profile: profile, allowUnknown: allow
                )
                ranked = FuelItinerary.rankedProgressFuel(
                    fuels: fuels,
                    from: current,
                    to: end,
                    reachableMeters: reach,
                    tankMeters: hopCap,
                    sessionSeed: planningSessionSeed,
                    excluding: visited
                )
            } else {
                reach = FuelItinerary.approximateReachableMeters(
                    fuels: fuels,
                    from: current,
                    tankMeters: hopCap * HopSearchPolicy.fuelMaxTank,
                    excluding: visited
                )
                let progressRanked = FuelItinerary.rankedProgressFuel(
                    fuels: fuels,
                    from: current,
                    to: end,
                    reachableMeters: reach,
                    tankMeters: hopCap,
                    sessionSeed: planningSessionSeed,
                    excluding: visited
                )
                // The next pump is chosen for forward progress toward the
                // rider's next waypoint—not for proximity to a discarded,
                // randomly generated route geometry.
                ranked = progressRanked
            }
            guard job == fuelAssistGeneration else { return nil }
            RoutingDebugLog.shared.event(
                "fuel reach depth=\(depth) from=\(current.latitude),\(current.longitude) candidates=\(fuels.count) reachable=\(reach.count) cap=\(Int(hopCap * HopSearchPolicy.fuelMaxTank))m"
            )
            let branchLimit = localFuelGraphAvailable ? 16 : 18
            for pick in ranked.prefix(branchLimit) {
                guard searchStates < maxSearchStates else { break }
                let gas = RouteCoordinate(longitude: pick.longitude, latitude: pick.latitude)
                guard GeoMath.meters(current, gas) >= 800,
                      GeoMath.meters(gas, end) >= 800
                else { continue }
                RoutingDebugLog.shared.event(
                    "fuel itinerary try depth=\(depth + 1) id=\(pick.id) name=\(pick.name ?? "-") graph=\(Int(reach[pick.id] ?? 0))m"
                )
                fuelPlanningStatus = "Checking fuel stop \(depth + 1)…"
                if !localFuelGraphAvailable {
                    let verified = await verifiedLiveLeg(
                        from: current,
                        to: gas,
                        capMeters: hopCap
                    )
                    // Mode switch, slider move, or waypoint drag superseded
                    // this search. Stop immediately instead of cycling every
                    // remaining pump after URLSession reports cancellation.
                    guard job == fuelAssistGeneration else { return nil }
                    guard verified != nil else { continue }
                }
                fuelPreviewStops = previewPath + [gas]
                refreshMap()
                mapState.fit([current, gas])
                await Task.yield()
                var nextVisited = visited
                nextVisited.insert(pick.id)
                if let tail = await findFuelChain(
                    from: gas,
                    visited: nextVisited,
                    depth: depth + 1,
                    previewPath: previewPath + [gas]
                ) {
                    return [gas] + tail
                }
                fuelPreviewStops = previewPath
                refreshMap()
                RoutingDebugLog.shared.event(
                    "fuel itinerary backtrack depth=\(depth + 1) skip=\(pick.id)"
                )
            }
            return nil
        }

        guard let chain = await findFuelChain(
            from: start,
            visited: Set<String>(),
            depth: 0,
            previewPath: []
        ),
              job == fuelAssistGeneration,
              chain.last.map({ coordinateMatches($0, end) }) == true
        else {
            guard job == fuelAssistGeneration, stages.indices.contains(index) else { return }
            let reserve = Int(FuelRangePrefs.reservePercent.rounded())
            let message = fuels.isEmpty
                ? (network.isOnline
                    ? "No live packed fuel stations were found for this stage."
                    : "No downloaded fuel stations were found for this stage.")
                : "No route-connected fuel chain fits \(Int(usableRangeKm.rounded())) km usable range (\(Int(rangeKm)) km tank with \(reserve)% reserve). Increase the range, reduce the reserve, change profile, or add a fuel stop manually."
            stages[index].error = message
            errorMessage = message
            toast = message
            isAssemblingRoute = false
            RoutingDebugLog.shared.event(
                "fuel itinerary failed states=\(searchStates) limited=\(searchStates >= maxSearchStates || Date() >= fuelSearchDeadline ? 1 : 0) — destination not appended"
            )
            mapState.unlockAfterRouteFailure()
            refreshMap()
            return
        }
        let waypoints = [start] + chain

        UserDefaults.standard.set(true, forKey: "dirt.layers.fuel")
        mapState.bumpLayerPrefs()

        let fuelGroupID = stages[index].fuelGroupID ?? UUID()
        var rebuilt: [Stage] = []
        for i in 0..<(waypoints.count - 1) {
            var hop = Stage(
                start: waypoints[i],
                end: waypoints[i + 1],
                profile: profile,
                allowUnknown: allow
            )
            hop.skipFuelAssist = true
            hop.setEndsAtFuelStop(i < waypoints.count - 2)
            hop.fuelGroupID = fuelGroupID
            if hop.endsAtFuelStop {
                let endPoint = waypoints[i + 1]
                if let station = fuels.first(where: {
                    coordinateMatches(
                        RouteCoordinate(longitude: $0.longitude, latitude: $0.latitude),
                        endPoint
                    )
                }) {
                    hop.fuelStopID = station.id
                    hop.fuelStopName = station.displayName
                } else {
                    hop.fuelStopName = "Fuel stop \(i + 1)"
                }
            }
            hop.maxRouteMeters = i == 0 ? firstHopCap : tank
            if !localFuelGraphAvailable {
                hop.response = verifiedLiveLegs[liveLegKey(waypoints[i], waypoints[i + 1])]
            }
            rebuilt.append(hop)
        }
        guard job == fuelAssistGeneration, stages.indices.contains(index), !rebuilt.isEmpty else { return }
        fuelPreviewStops = []
        stages.remove(at: index)
        RoutingDebugLog.shared.event("fuel itinerary hops=\(rebuilt.count)")
        isAssemblingRoute = true
        for i in 0..<rebuilt.count {
            let hopIndex = index + i
            guard job == fuelAssistGeneration else { return }
            stages.insert(rebuilt[i], at: hopIndex)
            fuelPlanningStatus = "Building leg \(i + 1) of \(rebuilt.count)…"
            refreshMap()
            if let hopStart = rebuilt[i].start, let hopEnd = rebuilt[i].end {
                mapState.fit([hopStart, hopEnd])
            }
            if !UIAccessibility.isReduceMotionEnabled, rebuilt[i].response != nil {
                try? await Task.sleep(for: .milliseconds(140))
            } else {
                await Task.yield()
            }
            guard stages.indices.contains(hopIndex) else { return }
            if stages[hopIndex].response == nil {
                await routeStage(at: hopIndex, includeFuelAssist: false)
            }
        }
        isAssemblingRoute = false
        fuelPlanNotice = nil
        refreshMap()
        announceRouteReadyIfComplete()
    }

    /// Online fuel construction has two deliberately separate phases:
    /// 1. one graph pass chooses the reachable forward pumps;
    /// 2. only those final legs are routed and revealed in order.
    /// This keeps candidate count out of the expensive route-search budget and
    /// restores the rider-visible point → pump → pump → destination build.
    private func buildLiveFuelChain(
        at index: Int,
        job: Int,
        start: RouteCoordinate,
        end: RouteCoordinate,
        profile: RouteProfile,
        allowUnknown: Bool,
        tankMeters: Double,
        firstHopCapMeters: Double,
        requireFuelStopBeforeEnd: Bool
    ) async throws {
        fuelPlanningStatus = "Finding every reachable pump in this tank…"
        refreshMap()
        let request = FuelChainRequest(
            profile: profile,
            from: start,
            to: end,
            allowUnknown: allowUnknown,
            usableRangeMeters: tankMeters,
            firstLegMaxMeters: firstHopCapMeters,
            requireFuelStopBeforeEnd: requireFuelStopBeforeEnd
        )
        let response = try await routing.fuelChain(request)
        guard job == fuelAssistGeneration, stages.indices.contains(index) else {
            throw CancellationError()
        }

        let stops = response.stops ?? []
        let diagnostics = response.diagnostics
        RoutingDebugLog.shared.event(
            "fuel forward chain stops=\(stops.count) states=\(diagnostics?.states ?? 0) " +
            "pops=\(diagnostics?.dijkstraPops ?? 0) planMs=\(diagnostics?.elapsedMs ?? 0)"
        )

        let waypoints = [start] + stops.map(\.coordinate) + [end]
        guard waypoints.count >= 2 else {
            throw RoutingError.invalidResponse
        }

        UserDefaults.standard.set(true, forKey: "dirt.layers.fuel")
        mapState.bumpLayerPrefs()

        let fuelGroupID = stages[index].fuelGroupID ?? UUID()
        var rebuilt: [Stage] = []
        rebuilt.reserveCapacity(waypoints.count - 1)
        for legIndex in 0..<(waypoints.count - 1) {
            var hop = Stage(
                start: waypoints[legIndex],
                end: waypoints[legIndex + 1],
                profile: profile,
                allowUnknown: allowUnknown
            )
            hop.skipFuelAssist = true
            hop.setEndsAtFuelStop(legIndex < stops.count)
            hop.fuelGroupID = fuelGroupID
            hop.maxRouteMeters = legIndex == 0 ? firstHopCapMeters : tankMeters
            if hop.endsAtFuelStop {
                let station = stops[legIndex]
                hop.fuelStopID = station.id
                hop.fuelStopName = station.displayName
            }
            rebuilt.append(hop)
        }

        guard job == fuelAssistGeneration, stages.indices.contains(index) else {
            throw CancellationError()
        }
        stages.remove(at: index)
        isAssemblingRoute = true

        for legIndex in rebuilt.indices {
            guard job == fuelAssistGeneration else { throw CancellationError() }
            let stageIndex = index + legIndex
            let hop = rebuilt[legIndex]
            stages.insert(hop, at: stageIndex)
            if hop.endsAtFuelStop {
                fuelPlanningStatus = "Building leg \(legIndex + 1) to fuel stop \(legIndex + 1)…"
            } else {
                fuelPlanningStatus = "Building the final leg to point 2…"
            }
            refreshMap()
            if let hopStart = hop.start, let hopEnd = hop.end {
                mapState.fit([hopStart, hopEnd])
            }
            await routeStage(at: stageIndex, includeFuelAssist: false)
            guard job == fuelAssistGeneration else { throw CancellationError() }
            guard stages.indices.contains(stageIndex),
                  stages[stageIndex].response != nil,
                  stages[stageIndex].error == nil
            else {
                isAssemblingRoute = false
                let message = stages.indices.contains(stageIndex)
                    ? (stages[stageIndex].error ?? "A selected fuel leg could not be routed.")
                    : "A selected fuel leg could not be routed."
                errorMessage = message
                toast = message
                RoutingDebugLog.shared.event(
                    "fuel committed leg failed leg=\(legIndex + 1)/\(rebuilt.count) msg=\(message)"
                )
                mapState.unlockAfterRouteFailure()
                refreshMap()
                return
            }
            // Let the completed line and pump land visibly before starting the
            // next final leg. This is progress, not a decorative fake delay.
            if !UIAccessibility.isReduceMotionEnabled {
                try? await Task.sleep(for: .milliseconds(180))
            } else {
                await Task.yield()
            }
        }

        isAssemblingRoute = false
        fuelPlanNotice = nil
        refreshMap()
        announceRouteReadyIfComplete()
    }

    /// Splits stage `index` (A→B) into A→via and via→B. Caller re-routes.
    private func splitStage(at index: Int, via: RouteCoordinate, viaIsFuel: Bool = false) -> Bool {
        guard stages.indices.contains(index),
              let start = stages[index].start,
              let end = stages[index].end
        else { return false }
        if GeoMath.meters(start, via) < 800 || GeoMath.meters(via, end) < 800 {
            RoutingDebugLog.shared.event("fuel split skipped — via on top of A or B")
            return false
        }

        let original = stages[index]
        let profile = original.profile
        let allow = original.allowUnknown
        stages[index].routeGeneration += 1

        var first = Stage(
            start: start, end: via, profile: profile, allowUnknown: allow
        )
        first.skipFuelAssist = true
        first.setEndsAtFuelStop(viaIsFuel)
        first.fuelGroupID = original.fuelGroupID
        first.maxRouteMeters = original.maxRouteMeters
        var second = Stage(
            start: via, end: end, profile: profile, allowUnknown: allow
        )
        second.skipFuelAssist = true
        second.setEndsAtFuelStop(original.endsAtFuelStop)
        second.fuelStopID = original.fuelStopID
        second.fuelStopName = original.fuelStopName
        second.fuelGroupID = original.fuelGroupID
        second.maxRouteMeters = original.maxRouteMeters
        // Second leg may still be long — allow another fuel assist after it routes.

        stages.remove(at: index)
        stages.insert(contentsOf: [first, second], at: index)
        refreshMap()
        return true
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
    private func routeForPlanning(
        from: RouteCoordinate,
        to: RouteCoordinate,
        profile: RouteProfile,
        allowUnknown: Bool,
        maxRouteMeters: Double? = nil,
        avoidEdgeIds: [String] = []
    ) async throws -> RouteResponse {
        let fromCL = CLLocationCoordinate2D(latitude: from.latitude, longitude: from.longitude)
        let toCL = CLLocationCoordinate2D(latitude: to.latitude, longitude: to.longitude)
        let ends = [fromCL, toCL]
        let needed = GraphPackStore.regionIds(containingAny: ends)
        let packsCoverEnds = Self.installedPacksCover(ends: ends, store: graphPacks)
        // One pack = one graph. Two adjacent installed packs chain on-device.
        let singleRegion = needed.count <= 1

        let routeStarted = Date()
        RoutingDebugLog.shared.routeAttempt(
            mode: String(describing: mode),
            from: (from.latitude, from.longitude),
            to: (to.latitude, to.longitude),
            profile: profile.rawValue,
            allowUnknown: allowUnknown
        )
        RoutingDebugLog.shared.event(
            "policy packsCover=\(packsCoverEnds) singleRegion=\(singleRegion) "
                + "installed=[\(needed.filter { graphPacks.isInstalled($0) }.joined(separator: ","))] "
                + "path=\(needed.first.flatMap { graphPacks.installedGraphPath(regionId: $0) } ?? "nil") "
                + "manifest=\(graphPacks.lastManifestVersion) "
                + "online=\(network.isOnline)"
        )

        if packsCoverEnds, !network.isOnline {
            await graphPacks.ensureRoadShapes(for: ends)
            let primary = await attemptOnDeviceRoute(
                from: fromCL,
                to: toCL,
                profile: profile,
                allowUnknown: allowUnknown,
                maxRouteMeters: maxRouteMeters,
                avoidEdgeIds: avoidEdgeIds
            )
            if singleRegion {
                switch primary {
                case .success(let local) where local.coordinates.count > 1:
                    let ms = Int(Date().timeIntervalSince(routeStarted) * 1000)
                    RoutingDebugLog.shared.routeResult(
                        "on-device ok edges≈\(local.edgeIds.count) m=\(Int(local.distanceMeters)) "
                            + "dirt%=\(local.dirtPercent) paved%=\(local.pavedPercent) "
                            + "unk%=\(local.unknownAccessPercent) ms=\(ms)"
                            + (local.debugNote.isEmpty ? "" : " \(local.debugNote)")
                    )
                    return makeOnDeviceRouteResponse(local)
                case .success:
                    RoutingDebugLog.shared.routeResult("on-device empty geometry → noPath")
                    throw RoutingError.server(
                        graphPacks.onDeviceRouteFailureMessage(for: ends, reason: .noPath)
                    )
                case .failure(let reason):
                    RoutingDebugLog.shared.routeResult("on-device failure \(reason)")
                    // Offline, the installed same-province pack is authoritative.
                    let recovery = await recoverOnDeviceFailure(
                        reason: reason,
                        from: fromCL,
                        to: toCL,
                        ends: ends,
                        profile: profile,
                        allowUnknown: allowUnknown
                    )
                    switch recovery {
                    case .routed(let local):
                        return makeOnDeviceRouteResponse(local)
                    case .liveFallback:
                        throw RoutingError.server(
                            graphPacks.onDeviceRouteFailureMessage(for: ends, reason: reason)
                        )
                    case .failed(let error):
                        throw error
                    }
                }
            } else if case .success(let local) = primary, local.coordinates.count > 1 {
                let ms = Int(Date().timeIntervalSince(routeStarted) * 1000)
                RoutingDebugLog.shared.routeResult(
                    "on-device chain ok edges≈\(local.edgeIds.count) m=\(Int(local.distanceMeters)) "
                        + "unk%=\(local.unknownAccessPercent) ms=\(ms)"
                )
                return makeOnDeviceRouteResponse(local)
            } else {
                RoutingDebugLog.shared.routeResult("on-device chain missed — no live fallback")
                throw RoutingError.server(
                    "Couldn't join \(Self.regionClause(for: ends, store: graphPacks)) on the downloaded packs. Drop a via near the border, or keep both pins in one pack."
                )
            }
        } else if !packsCoverEnds, singleRegion, network.isOnline {
            // Primary says NS but pack has no eligible edge at B (Amherst / border gaps).
            // Still try live — basemap snap ≠ pack coverage.
            let endDist = await graphPacks.distanceToNearestRoad(
                from: toCL, allowUnknown: allowUnknown, profile: profile
            )
            let endDistUnknown = await graphPacks.distanceToNearestRoad(
                from: toCL, allowUnknown: true, profile: profile
            )
            RoutingDebugLog.shared.event(
                "packsCover=false singleRegion endDist=\(endDist.map { String(format: "%.0f", $0) } ?? "nil") "
                    + "endDistUnknown=\(endDistUnknown.map { String(format: "%.0f", $0) } ?? "nil")"
            )
        }

        if network.isOnline {
            let liveTimeout = needed.count > 1
                ? RoutingClient.longHaulTimeout
                : RoutingClient.defaultTimeout
            RoutingDebugLog.shared.event(
                "live /api/route needed=[\(needed.joined(separator: ","))] timeout=\(Int(liveTimeout))s"
            )
            let request = RouteRequest(
                profile: profile,
                locations: [
                    RouteLocation(latitude: from.latitude, longitude: from.longitude, label: "A"),
                    RouteLocation(latitude: to.latitude, longitude: to.longitude, label: "B")
                ],
                allowUnknown: allowUnknown,
                avoidEdgeIds: avoidEdgeIds,
                sessionSeed: planningSessionSeed,
                maxPathMeters: maxRouteMeters
            )
            do {
                let response = try await routing.route(request, timeout: liveTimeout)
                let ms = Int(Date().timeIntervalSince(routeStarted) * 1000)
                let unk = response.stats?.unknownAccessPercent ?? 0
                let liveMeta: String
                if let debug = response.debug {
                    let search = debug.searchMeta
                    liveMeta = " rev=\(debug.routingRevision ?? "legacy")"
                        + " objective=\(search?.rideObjective ?? "legacy")"
                        + " outcome=\(search?.pass2Outcome ?? "-")"
                        + " timedOut=\((search?.timedOut ?? false) ? 1 : 0)"
                        + " pops=\(search?.pops ?? 0)"
                        + " corridor=\(Int(search?.corridorMeters ?? 0))m"
                        + " maxXT=\(Int(search?.maxCrossTrackMeters ?? 0))m"
                        + " widened=\((search?.corridorWidened ?? false) ? 1 : 0)"
                        + " urbanFallback=\((search?.urbanCoreFallbackUsed ?? false) ? 1 : 0)"
                        + " settlementFallback=\((search?.settlementFallbackUsed ?? false) ? 1 : 0)"
                } else {
                    liveMeta = " rev=legacy"
                }
                RoutingDebugLog.shared.routeResult(
                    "live ok status=\(response.status) m=\(Int(response.distanceMeters ?? 0)) "
                        + "dirt%=\(response.dirtPercent) paved%=\(response.pavedPercent) "
                        + "unk%=\(unk) ms=\(ms)" + liveMeta
                )
                return response
            } catch {
                RoutingDebugLog.shared.routeFailure(error, context: "live")
                throw rewriteLiveRoutingError(error, needed: needed)
            }
        }

        throw RoutingError.server(graphPacks.offlinePlanningMessage(for: ends))
    }

    private enum OnDeviceRecovery {
        case routed(OnDeviceRouter.Result)
        case liveFallback(hint: String)
        case failed(Error)
    }

    private func attemptOnDeviceRoute(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        profile: RouteProfile,
        allowUnknown: Bool,
        maxRouteMeters: Double? = nil,
        avoidEdgeIds: [String] = []
    ) async -> Result<OnDeviceRouter.Result, OnDeviceRouter.Failure> {
        await graphPacks.ensureRoadShapes(for: [from, to])
        return await graphPacks.routeOnDeviceDetailed(
            from: from,
            to: to,
            profile: profile,
            allowUnknown: allowUnknown,
            avoidEdgeIds: avoidEdgeIds,
            sessionSeed: planningSessionSeed,
            maxRouteMeters: maxRouteMeters
        )
    }

    /// Recovery ladder when the primary on-device attempt fails:
    /// Recovery when the installed home-province pack is SoT (packsCover + single region).
    /// Capillary retry only surfaces an Allow hint — never silently opens purple.
    /// Missing-pack and multi-region hops fail above; this ladder only retries the installed pack.
    private func recoverOnDeviceFailure(
        reason: OnDeviceRouter.Failure,
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        ends: [CLLocationCoordinate2D],
        profile: RouteProfile,
        allowUnknown: Bool
    ) async -> OnDeviceRecovery {
        let startDist = await graphPacks.distanceToNearestRoad(
            from: from, allowUnknown: allowUnknown, profile: profile
        )
        let endDist = await graphPacks.distanceToNearestRoad(
            from: to, allowUnknown: allowUnknown, profile: profile
        )
        let startDistUnknown = await graphPacks.distanceToNearestRoad(
            from: from, allowUnknown: true, profile: profile
        )
        let endDistUnknown = await graphPacks.distanceToNearestRoad(
            from: to, allowUnknown: true, profile: profile
        )
        RoutingDebugLog.shared.event(
            "snapDist start=\(startDist.map { String(format: "%.0f", $0) } ?? "nil")m "
                + "end=\(endDist.map { String(format: "%.0f", $0) } ?? "nil")m "
                + "startU=\(startDistUnknown.map { String(format: "%.0f", $0) } ?? "nil")m "
                + "endU=\(endDistUnknown.map { String(format: "%.0f", $0) } ?? "nil")m "
                + "active=\(graphPacks.activePack?.regionId ?? "?")"
        )

        // If Allow is off but unknown capillary would connect, tell the rider — don't cheat.
        if !allowUnknown, profile != .cleanest,
           reason == .noPath || reason == .cannotSnapEnd || reason == .cannotSnapStart {
            let unknownHelpsEnd = (endDist == nil || endDist! > OnDeviceRouter.preferredMatchMeters)
                && (endDistUnknown.map { $0 <= OnDeviceRouter.preferredMatchMeters } ?? false)
            let unknownHelpsStart = (startDist == nil || startDist! > OnDeviceRouter.preferredMatchMeters)
                && (startDistUnknown.map { $0 <= OnDeviceRouter.preferredMatchMeters } ?? false)
            var capillaryWouldRoute = false
            if reason == .noPath || unknownHelpsEnd || unknownHelpsStart {
                switch await attemptOnDeviceRoute(
                    from: from, to: to, profile: profile, allowUnknown: true
                ) {
                case .success(let local) where local.coordinates.count > 1:
                    capillaryWouldRoute = true
                    RoutingDebugLog.shared.event(
                        "on-device would succeed with Allow unknown m=\(Int(local.distanceMeters)) — not auto-applied"
                    )
                default:
                    break
                }
            }
            if capillaryWouldRoute {
                return .failed(
                    RoutingError.server(
                        "No route under Dirt with Allow unknown off — those points need gated forest/track roads. Turn on Allow unknown, or pick another profile / pin."
                    )
                )
            }
        }

        do {
            try throwOnDeviceSnapOrPathFailure(
                reason: reason,
                ends: ends,
                startDist: startDist,
                endDist: endDist
            )
            return .failed(RoutingError.server("On-device routing failed."))
        } catch {
            return .failed(error)
        }
    }

    private func throwOnDeviceSnapOrPathFailure(
        reason: OnDeviceRouter.Failure,
        ends: [CLLocationCoordinate2D],
        startDist: Double?,
        endDist: Double?
    ) throws {
        let limit = Int(OnDeviceRouter.preferredMatchMeters)
        let region = Self.regionClause(for: ends, store: graphPacks)

        if mode == .fromHere, reason == .cannotSnapStart {
            throw RoutingError.offGraphStart
        }

        switch reason {
        case .cannotSnapStart:
            if let meters = startDist.map({ Int($0.rounded()) }) {
                throw RoutingError.server(
                    "Your start is about \(meters) m from the nearest mapped road in \(region) (limit \(limit) m). Move closer or drop A on the road."
                )
            }
            throw RoutingError.server(
                graphPacks.onDeviceRouteFailureMessage(for: ends, reason: reason)
            )
        case .cannotSnapEnd:
            if let meters = endDist.map({ Int($0.rounded()) }) {
                throw RoutingError.server(
                    "Point B is about \(meters) m from the nearest mapped road in \(region) (limit \(limit) m). Nudge B closer to the roadway."
                )
            }
            throw RoutingError.server(
                "Point B isn’t on a road in the downloaded \(region) pack. Nudge B onto a pack roadway, or download a bordering pack."
            )
        case .noPath:
            let startFar = startDist == nil || startDist! > OnDeviceRouter.preferredMatchMeters
            let endFar = endDist == nil || endDist! > OnDeviceRouter.preferredMatchMeters
            if startFar, !endFar {
                let meters = startDist.map { Int($0.rounded()) }
                throw RoutingError.server(
                    meters.map {
                        "Your start is about \($0) m from the nearest mapped road (limit \(limit) m). Tap the road to set A — B stays put."
                    } ?? "Your start isn’t close enough to a mapped road. Tap the road to set A — B stays put."
                )
            }
            if endFar, !startFar {
                let meters = endDist.map { Int($0.rounded()) }
                throw RoutingError.server(
                    meters.map {
                        "Point B is about \($0) m from the nearest mapped road (limit \(limit) m). Nudge B closer to the roadway."
                    } ?? "Point B isn’t close enough to a mapped road. Nudge B closer to the roadway."
                )
            }
            if startFar, endFar {
                let sm = startDist.map { Int($0.rounded()) } ?? -1
                let em = endDist.map { Int($0.rounded()) } ?? -1
                throw RoutingError.server(
                    "Both ends are far from mapped roads (start ~\(sm) m, B ~\(em) m; limit \(limit) m). Move closer or drop pins on the roadway."
                )
            }
            // Snaps OK — fabric/policy disconnect under current Allow + profile.
            throw RoutingError.server(
                "No on-device path between those points in \(region) under this profile. Try another profile, turn on Allow unknown if you need forest/track roads, or move a pin."
            )
        default:
            throw RoutingError.server(
                graphPacks.onDeviceRouteFailureMessage(for: ends, reason: reason)
            )
        }
    }

    /// True when every endpoint’s primary region has an installed pack (or both
    /// ends share one installed region).
    private static func installedPacksCover(
        ends: [CLLocationCoordinate2D],
        store: GraphPackStore
    ) -> Bool {
        let needed = GraphPackStore.regionIds(containingAny: ends)
        if !needed.isEmpty, needed.allSatisfy({ store.isInstalled($0) }) {
            return true
        }
        // Same downloaded province for rider + pin even if bbox noise differs.
        let primaries = ends.compactMap { GraphPackStore.primaryRegionId(containing: $0) }
        guard let first = primaries.first, primaries.allSatisfy({ $0 == first }) else {
            return false
        }
        return store.isInstalled(first)
    }

    private static func regionClause(
        for coordinates: [CLLocationCoordinate2D],
        store: GraphPackStore
    ) -> String {
        let needed = GraphPackStore.regionIds(containingAny: coordinates)
        let titles = needed.map { store.displayTitle(forRegionId: $0) }
        if titles.isEmpty { return "this area" }
        if titles.count == 1 { return titles[0] }
        return titles.joined(separator: " / ")
    }

    /// Live `/api/route` failures often say "Invalid URL" when a CDN pack is missing.
    private func rewriteLiveRoutingError(_ error: Error, needed: [String]) -> Error {
        let msg = error.localizedDescription
        let lower = msg.lowercased()
        let titles = needed.map { graphPacks.displayTitle(forRegionId: $0) }.joined(separator: " / ")
        let nsCode = (error as NSError).code
        if nsCode == NSURLErrorTimedOut
            || lower.contains("timed out")
            || lower.contains("timeout") {
            return RoutingError.server(
                "Live cross-country routing is still working (loads several map packs on the server). Wait a bit and try again — long routes can take up to a few minutes."
            )
        }
        if lower.contains("invalid url")
            || lower.contains("graph pack not on live server")
            || lower.contains("graph pack missing on cdn")
            || lower.contains("graph_load_failed")
            || lower.contains("graph fetch http") {
            return RoutingError.server(
                "Live routing can’t load \(titles.isEmpty ? "that region" : titles) from the map CDN right now. Check Wi‑Fi and try again — you shouldn’t need to download a pack just to route online."
            )
        }
        if lower.contains("disconnected networks") || lower.contains("disconnected_components") {
            return RoutingError.server(
                "Live routing snapped both ends but they’re on disconnected networks (\(titles)). Often a ferry / bridge gap in the thinned longhaul packs. Try a pin on the mainland approach, turn on Allow unknown, or stage via a bordering region."
            )
        }
        return error
    }

    /// The destination the active route is preserving (recovery keeps it).
    /// Single-leg: final B. Multi-stage: **active stage end** (not the whole-trip B).
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
        fromHereResponse = response
        mode = .fromHere
        destination = target
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
        let stageID = stages[index].id
        let useProfile = stages[index].profile
        let useAllow = stages[index].allowUnknown
        stages[index].routeGeneration += 1
        let generation = stages[index].routeGeneration

        do {
            let response = try await routeWhileNavigating(
                from: from,
                to: to,
                avoidEdgeIds: avoidEdgeIds,
                networkOnline: networkOnline,
                profile: useProfile,
                allowUnknown: useAllow
            )
            guard let idx = stages.firstIndex(where: { $0.id == stageID }),
                  stages[idx].routeGeneration == generation
            else { return }

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

        // Preserve stage start/end pins and profile — only replace geometry.
        stages[index].response = applied
        stages[index].error = nil

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
        if !stages.isEmpty {
            let hops = stages.filter { $0.end != nil }
            guard !hops.isEmpty else { return false }
            return hops.allSatisfy { $0.error == nil && $0.response != nil }
        }
        switch mode {
        case .fromHere, .saved:
            return fromHereResponse != nil && errorMessage == nil
        case .plan:
            return false
        }
    }

    /// Marker IDs must remain stable while stage arrays are inserted, removed,
    /// or re-seated with fuel hops. Labels are human order; IDs are identity.
    private func stageMarkerID(_ stage: Stage) -> String {
        "stage-\(stage.id.uuidString)"
    }

    /// Mid-nav / single-leg success toast (caller already verified the response).
    private func announceRouteReady() {
        announceRouteReadyIfComplete()
    }
}
