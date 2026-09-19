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
        let avoidMotorways: Bool
        let preferBackRoads: Bool
        let response: RouteResponse?
        let isRouting: Bool
        let error: String?
        let fuelGap: FuelGap?
        let fuelUnknown: String?
        let endsAtFuelStop: Bool
        let fuelStopID: String?
        let fuelStopName: String?
        let departureFuelStopID: String?
        let fuelGroupID: UUID?
        let maxRouteMeters: Double?
        let builtLegIndex: Int?

        init(
            builtLeg: BuiltLeg,
            riderLeg: RiderLeg,
            status: LegStatus,
            isFuelExpanded: Bool,
            departureFuelStopID: String?,
            builtLegIndex: Int
        ) {
            riderLegID = riderLeg.id
            start = builtLeg.fromCoordinate
            end = builtLeg.toCoordinate
            let departureID = departureFuelStopID ?? riderLeg.from.uuidString
            // Stage controls follow rider intent (leg / hop override), not the
            // last committed geometry — otherwise a pending rebuild can make the
            // Dirt/Balanced/Clean control lie about what the next search will use.
            let effectiveProfile = riderLeg.effectiveProfile(departingFrom: departureID)
            profile = effectiveProfile
            allowUnknown = riderLeg.allowsUnknown(
                departingFrom: departureID,
                effectiveProfile: effectiveProfile
            )
            avoidMotorways = riderLeg.avoidsMajorHighways(
                departingFrom: departureID,
                effectiveProfile: effectiveProfile
            )
            preferBackRoads = riderLeg.preferBackRoads
            response = builtLeg.response
            if case .pending = status { isRouting = true } else { isRouting = false }
            if case .failed(let message) = status { error = message } else { error = nil }
            if case .gap(let gap) = status { fuelGap = gap } else { fuelGap = nil }
            if case .fuelUnknown(let message) = status { fuelUnknown = message } else { fuelUnknown = nil }
            endsAtFuelStop = builtLeg.endsAtFuelStop != nil
            fuelStopID = builtLeg.endsAtFuelStop?.stationID
            fuelStopName = builtLeg.endsAtFuelStop?.name
            self.departureFuelStopID = departureFuelStopID
            fuelGroupID = isFuelExpanded ? riderLeg.id : nil
            maxRouteMeters = nil
            self.builtLegIndex = builtLegIndex
            let suffix = builtLeg.endsAtFuelStop?.stationID
                ?? "\(builtLeg.toCoordinate.latitude),\(builtLeg.toCoordinate.longitude)"
            // builtLegIndex is unique within the built itinerary — stationID alone
            // repeats when a replan revisits the same pump and SwiftUI ForEach faults.
            id = "\(riderLeg.id.uuidString)#\(builtLegIndex):\(suffix)"
        }

        init(
            riderLeg: RiderLeg,
            start: RouteCoordinate,
            end: RouteCoordinate,
            status: LegStatus
        ) {
            id = "\(riderLeg.id.uuidString):unbuilt"
            riderLegID = riderLeg.id
            self.start = start
            self.end = end
            profile = riderLeg.profile
            allowUnknown = riderLeg.allowsUnknown(
                departingFrom: riderLeg.from.uuidString,
                effectiveProfile: riderLeg.profile
            )
            avoidMotorways = riderLeg.avoidsMajorHighways(
                departingFrom: riderLeg.from.uuidString,
                effectiveProfile: riderLeg.profile
            )
            preferBackRoads = riderLeg.preferBackRoads
            response = nil
            if case .pending = status { isRouting = true } else { isRouting = false }
            if case .failed(let message) = status { error = message } else { error = nil }
            if case .gap(let gap) = status { fuelGap = gap } else { fuelGap = nil }
            if case .fuelUnknown(let message) = status { fuelUnknown = message } else { fuelUnknown = nil }
            endsAtFuelStop = false
            fuelStopID = nil
            fuelStopName = nil
            departureFuelStopID = riderLeg.from.uuidString
            fuelGroupID = nil
            maxRouteMeters = nil
            builtLegIndex = nil
        }
    }

    struct FuelCoverageNotice: Identifiable, Equatable {
        enum Kind: Equatable {
            case gap
            case unverified
        }

        let id: String
        let stageIndex: Int
        let kind: Kind
        let title: String
        let scope: String
        let message: String
    }

    var mode: Mode = .fromHere {
        didSet { modeChanged(from: oldValue) }
    }
    var showingLoop = false
    var loopFar: RouteCoordinate?
    var loopSummary: String?
    private var loopRunID: UUID?

    func selectLoop() {
        switchToPlanClearing()
        showingLoop = true
        loopFar = nil
        fuelPlanningStatus = nil
        isAssemblingRoute = false
        loopSummary = nil
        locationService.requestWhenInUse()
        locationService.startUpdates()
        refreshMap()
    }

    func generateLoop() {
        guard navigation.phase == .idle, !isRouting else { return }
        guard locationService.isAuthorized else {
            locationService.requestWhenInUse()
            errorMessage = "Allow location access in Settings to create a loop from where you are."
            return
        }
        guard let start = locationService.currentCoordinate else {
            locationService.startUpdates()
            errorMessage = "Waiting for your location. Try again in a moment."
            return
        }
        guard let far = loopFar else {
            errorMessage = "Drop a pin to define distance and direction of loop."
            return
        }
        invalidateInFlightRoutes()
        let runID = UUID()
        loopRunID = runID
        isRouting = true
        isAssemblingRoute = true
        errorMessage = nil
        loopSummary = nil
        fuelPlanningStatus = "Creating loop"
        let target = loopTargetMeters(start: start, far: far)
        let selectedProfile = profile, selectedAllow = allowUnknown
        var preferences = displayedRidePreferences
        preferences.preferDifferentRoads = true
        let policy = routingSourcePolicy
        let dummy = RouteRequest(
            profile: selectedProfile,
            locations: [RouteLocation(latitude: start.latitude, longitude: start.longitude, label: "start"),
                        RouteLocation(latitude: far.latitude, longitude: far.longitude, label: "far")],
            allowUnknown: selectedAllow)
        buildTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.loopRunID == runID {
                    self.isRouting = false
                    self.isAssemblingRoute = false
                    self.fuelPlanningStatus = nil
                }
            }
            do {
                let source = policy.select(for: dummy)
                let result = try await source.planLoop(PlannedLoopRequest(
                    start: start, far: far, targetMeters: target,
                    profile: selectedProfile, allowUnknown: selectedAllow,
                    wander: preferences.normalized.wander, avoidCities: preferences.avoidCities,
                    avoidMotorways: self.avoidMotorways, preferBackRoads: self.preferBackRoads,
                    seed: UInt64.random(in: 1...9_007_199_254_740_991)))
                guard !Task.isCancelled, self.loopRunID == runID, self.showingLoop else { return }
                let itinerary = reduce(RiderItinerary(), .replaceAll(
                    waypoints: [start, far, start],
                    profile: selectedProfile, allowUnknown: selectedAllow,
                    avoidMotorways: self.avoidMotorways, preferBackRoads: self.preferBackRoads)).itinerary
                guard itinerary.legs.count == 2, itinerary.legs.allSatisfy({ $0.profile == selectedProfile }),
                      itinerary.legs.allSatisfy({ $0.allowUnknown == selectedAllow }) else {
                    self.errorMessage = "Loop legs must keep the selected riding style."
                    self.refreshMap()
                    return
                }
                let responses = [result.outbound, result.inbound]
                let builtLegs = itinerary.legs.enumerated().map { index, leg in
                    BuiltLeg(riderLegID: leg.id,
                             fromCoordinate: itinerary.waypoints[index].coordinate,
                             toCoordinate: itinerary.waypoints[index + 1].coordinate,
                             endsAtFuelStop: nil, response: responses[index],
                             fuelUsedOnArrivalMeters: 0, routeProfile: selectedProfile)
                }
                let built = BuiltItinerary(
                    generation: itinerary.generation, legs: builtLegs,
                    riderLegStatus: Dictionary(uniqueKeysWithValues: itinerary.legs.map { ($0.id, LegStatus.built) }),
                    riderRoutes: Dictionary(uniqueKeysWithValues: zip(itinerary.legs.map(\.id), responses)))
                let inboundMeters = result.inbound.distanceMeters ?? 0
                let outAndBack = inboundMeters > 0 && result.reriddenMeters > inboundMeters * 0.5
                RoutingDebugLog.shared.event(
                    "loop distance=\(Int(result.distanceMeters)) reridden=\(Int(result.reriddenMeters)) return=\(Int(result.returnMeters)) style=\(selectedProfile.rawValue) allowUnknown=\(selectedAllow) outAndBack=\(outAndBack)")
                self.ridePreferences = preferences
                self.itinerary = itinerary
                self.built = built
                self.destination = start
                self.routeIdentity = "loop:\(runID.uuidString)"
                if outAndBack {
                    self.loopSummary = "Ride \(Int(result.distanceMeters / 1000)) km · only way back is the way you came, \(Int((result.reriddenMeters / 1000).rounded())) km repeated"
                } else {
                    self.loopSummary = "Ride \(Int(result.distanceMeters / 1000)) km · \(Int(result.reriddenMeters)) m re-ridden"
                }
                self.toast = "Loop ready"
                self.mapState.fit(built.legs.flatMap { $0.response.coordinates })
            } catch is CancellationError {
                return
            } catch {
                guard self.loopRunID == runID else { return }
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            self.refreshMap()
        }
    }

    /// There-and-back geodesic to the far pin. Loop has no rider target km;
    /// `LoopPlanner` still takes `targetMeters`, so this is the pin as distance.
    private func loopTargetMeters(start: RouteCoordinate, far: RouteCoordinate) -> Double {
        let thereAndBack = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: far.latitude, longitude: far.longitude)) * 2
        return max(1, thereAndBack)
    }

    var profile: RouteProfile = .dirt {
        didSet {
            guard oldValue != profile else { return }
            if !suppressPlannerReroute, profile == .cleanest {
                suppressPlannerReroute = true
                allowUnknown = false
                avoidMotorways = true
                preferBackRoads = false
                suppressPlannerReroute = false
            }
            syncNetworkAccessPolicy()
            if showingLoop, loopFar != nil, hasRoute {
                generateLoop()
            } else {
                reroute()
            }
        }
    }
    var allowUnknown = false {
        didSet {
            if oldValue != allowUnknown {
                syncNetworkAccessPolicy()
                if showingLoop, loopFar != nil, hasRoute {
                    generateLoop()
                } else {
                    reroute()
                }
            }
        }
    }
    /// Internal inverse of the rider-facing "Allow major highways" switch.
    /// Clean defaults to avoiding motorway + trunk + primary; other profiles ignore it.
    var avoidMotorways = true {
        didSet {
            guard oldValue != avoidMotorways else { return }
            guard !suppressPlannerReroute else { return }
            if itinerary.legs.isEmpty {
                reroute()
            } else {
                apply(.setAvoidMotorways(legID: nil, avoidMotorways), source: "avoidMotorways")
            }
        }
    }
    /// Phase E4 — prefer back roads (penalize arterial). Default off.
    var preferBackRoads = false {
        didSet {
            guard oldValue != preferBackRoads else { return }
            guard !suppressPlannerReroute else { return }
            if itinerary.legs.isEmpty {
                reroute()
            } else {
                apply(.setPreferBackRoads(legID: nil, preferBackRoads), source: "preferBackRoads")
            }
        }
    }
    var ridePreferences: RidePreferences?

    var displayedRidePreferences: RidePreferences {
        ridePreferences ?? RidePreferences(avoidHighways: profile == .cleanest && avoidMotorways)
    }

    func applyRidePreferences(_ preferences: RidePreferences) {
        guard navigation.phase == .idle else { return }
        let next = preferences.normalized
        guard next != displayedRidePreferences else { return }
        ridePreferences = next
        apply(.rebuild, source: "ridePreferences")
    }

    var showUnknownAck = false

    /// A pin-triggered build gets one spatial story: first anchor, then each
    /// newly committed fuel leg. Routine option reroutes do not replay it.
    private var cameraBuildGeneration: Int?
    private var cameraBuildLegKeys: Set<String> = []

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
    private(set) var acknowledgedFuelGapIDs = Set<String>()
    var stages: [Stage] {
        guard let built else { return [] }
        let counts = Dictionary(grouping: built.legs, by: \.riderLegID).mapValues(\.count)
        var result: [Stage] = []
        for (riderLegIndex, riderLeg) in itinerary.legs.enumerated() {
            let matches = built.legs.enumerated().filter { $0.element.riderLegID == riderLeg.id }
            var departure = riderLeg.from.uuidString
            let riderLegStatus = built.riderLegStatus[riderLeg.id] ?? .pending
            for (matchIndex, match) in matches.enumerated() {
                let (builtLegIndex, builtLeg) = match
                result.append(Stage(
                    builtLeg: builtLeg,
                    riderLeg: riderLeg,
                    status: Self.projectedStatus(
                        riderLegStatus,
                        builtStageIndex: matchIndex,
                        builtStageCount: matches.count
                    ),
                    isFuelExpanded: (counts[riderLeg.id] ?? 0) > 1,
                    departureFuelStopID: departure,
                    builtLegIndex: builtLegIndex
                ))
                if let stationID = builtLeg.endsAtFuelStop?.stationID {
                    departure = stationID
                }
            }
            if matches.isEmpty,
               itinerary.waypoints.indices.contains(riderLegIndex + 1) {
                result.append(Stage(
                    riderLeg: riderLeg,
                    start: itinerary.waypoints[riderLegIndex].coordinate,
                    end: itinerary.waypoints[riderLegIndex + 1].coordinate,
                    status: built.riderLegStatus[riderLeg.id] ?? .pending
                ))
            }
        }
        return result
    }

    /// A fuel warning belongs to the first unverified section, not to every
    /// pump hop generated inside its parent rider leg. Earlier built stages
    /// remain independently usable and must keep showing their route metrics.
    static func projectedStatus(
        _ riderLegStatus: LegStatus,
        builtStageIndex: Int,
        builtStageCount: Int
    ) -> LegStatus {
        guard builtStageIndex == builtStageCount - 1 else { return .built }
        return riderLegStatus
    }

    /// When true, `profile` / `allowUnknown` didSet skips `reroute()`.
    @ObservationIgnored private var suppressPlannerReroute = false
    /// Coalesce profile / Allow toggles so we don't fire 6 parallel Dijkstras.
    @ObservationIgnored private var rerouteCoalesceTask: Task<Void, Never>?
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPackBuild: (
        from: Int,
        through: Int?,
        reuse: BuiltItinerary?,
        replanFromStationID: String?
    )?
    @ObservationIgnored private var moveDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var pendingMove: (waypointID: UUID, coordinate: RouteCoordinate, source: String)?
    @ObservationIgnored private(set) var canonicalBuildStartCount = 0
    @ObservationIgnored private(set) var lastCanonicalBuildFromLegIndex: Int?
    /// Debounce From here point-2/point-1 retaps while the rider is adjusting the pin.
    @ObservationIgnored private var fromHereRouteDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var fromHereIntentGeneration = 0
    @ObservationIgnored private var navigationRerouteTask: Task<Void, Never>?
    @ObservationIgnored private var navigationRerouteGeneration = 0
    private struct PendingGroupTracking {
        let groupID: String
        let userID: String
        let displayName: String
        let routedCoordinate: RouteCoordinate
        var latestTarget: GroupMemberRouteTarget
    }
    private struct ActiveGroupTracking {
        let groupID: String
        let userID: String
        let displayName: String
        var routedCoordinate: RouteCoordinate
        var latestTarget: GroupMemberRouteTarget
        var deferredCoordinate: RouteCoordinate?
    }
    @ObservationIgnored private var pendingGroupTracking: PendingGroupTracking?
    @ObservationIgnored private var activeGroupTracking: ActiveGroupTracking?
    @ObservationIgnored private var groupRouteUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var groupRouteUpdateGeneration = 0
    @ObservationIgnored private var groupFollowerStoppedSince: Date?
    @ObservationIgnored private var groupFollowerIsStopped = false
    private(set) var groupNavigationNotice: GroupNavigationNotice?
    /// While navigating, Route to rider waits here until the rider confirms replace.
    private(set) var pendingMemberRouteReplacement: GroupMemberRouteTarget?

    private(set) var isRouting = false
    var errorMessage: String?
    /// Non-destructive fuel recovery/status shown in the compact fuel summary.
    private(set) var fuelPlanNotice: String?
    private var fuelTargetMarkers: [MapState.Marker] = []
    private var activeFuelDragMarkerID: String?
    private var fuelReplacementTask: Task<Void, Never>?
    private var fuelReplacementRunID: UUID?
    private var checkedFuelReplacements: [String: (original: RiderItinerary, proposed: RiderItinerary, built: BuiltItinerary)] = [:]

    private func cancelFuelReplacement() {
        fuelReplacementTask?.cancel()
        fuelReplacementTask = nil
        fuelReplacementRunID = nil
        checkedFuelReplacements = [:]
        fuelTargetMarkers = []
        activeFuelDragMarkerID = nil
        mapState.selectPlannerPin(nil)
    }

    /// Current fuel-build milestone. The primary toast is its only animated UI.
    private(set) var fuelPlanningStatus: String?
    /// Tentative, route-connected pumps revealed as the chain search advances.
    private var fuelPreviewStops: [RouteCoordinate] = []
    /// Transient status capsule. Non-calculating toasts auto-clear.
    var toast: String? {
        didSet {
            guard toast != oldValue else { return }
            toastDismissTask?.cancel()
            toastDismissTask = nil
            guard let message = toast, !Self.isPersistentProgressToast(message) else { return }
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
    @ObservationIgnored private var lastQueuedTileLookaheadStageIndex: Int?
    @ObservationIgnored private var navigationStartTask: Task<Void, Never>?
    private let routing: RoutingClient
    private let locationService: LocationService
    private let mapState: MapState
    let navigation: NavigationSession
    private let offline: OfflineTileManager
    private let graphPacks: GraphPackStore
    private let network: NetworkPathMonitor
    private let itineraryBuilder: ItineraryBuilder
    private let routingSourcePolicy: RoutingSourcePolicy
    private let packAcquisition: PackAcquisitionCoordinator
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
        itineraryBuilder: ItineraryBuilder? = nil,
        packAcquisition: PackAcquisitionCoordinator? = nil
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
        self.packAcquisition = packAcquisition ?? PackAcquisitionCoordinator(store: graphPacks)

        navigation.onRerouteNeeded = { [weak self] in
            guard let self else { return }
            self.recalculateFromRider(networkOnline: self.network.isOnline)
        }
        navigation.onRouteRecovered = { [weak self] in
            self?.cancelNavigationReroute()
        }
        locationService.onLocation = { [weak self] location in
            guard let self else { return }
            self.navigation.update(with: location)
            self.prefetchNextNavigationTileStageIfNeeded()
            self.prepareCurrentNavigationRoutingPackIfNeeded(at: location.coordinate)
            self.handleGroupTrackingLocation(location)
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
        surfaceComposition.dirtPercent
    }

    var aggregatePavedPercent: Int {
        hasRoute ? surfaceComposition.pavedPercent : 0
    }

    var surfaceComposition: RouteSurfaceComposition {
        RouteSurfaceComposition.from(responses: activeResponses)
    }

    var ferrySummary: RouteFerrySummary {
        RouteFerrySummary.from(responses: activeResponses)
    }

    private var activeSurfaceFamilyMode: String? {
        guard !activeResponses.isEmpty,
              activeResponses.allSatisfy({ $0.stats?.surfaceFamilyMode == "leaf-v3" })
        else { return nil }
        return "leaf-v3"
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
        guard let riderLegIndex = itinerary.legs.firstIndex(where: { $0.id == stage.riderLegID })
        else { return "Leg \(index + 1)" }
        let from: String
        if index > 0,
           stages[index - 1].riderLegID == stage.riderLegID,
           stages[index - 1].endsAtFuelStop {
            from = "F\(fuelOrdinal(endingAt: index - 1))"
        } else {
            from = "Point \(riderLegIndex + 1)"
        }

        let to: String
        if stage.endsAtFuelStop {
            to = "F\(fuelOrdinal(endingAt: index))"
        } else {
            to = "Point \(riderLegIndex + 2)"
        }
        return "\(from) → \(to)"
    }

    func stageEndpointIsFuelStation(at index: Int) -> Bool {
        guard stages.indices.contains(index) else { return false }
        if stages[index].endsAtFuelStop { return true }
        guard let riderLegIndex = itinerary.legs.firstIndex(where: {
            $0.id == stages[index].riderLegID
        }) else { return false }
        return built?.waypointFuelStops[itinerary.waypoints[riderLegIndex + 1].id] != nil
    }

    func stageFuelStationSubtitle(at index: Int) -> String? {
        guard stages.indices.contains(index) else { return nil }
        let stage = stages[index]
        if stage.endsAtFuelStop {
            return stage.fuelStopName
        }
        guard let riderLegIndex = itinerary.legs.firstIndex(where: {
            $0.id == stage.riderLegID
        }),
        let station = built?.waypointFuelStops[itinerary.waypoints[riderLegIndex + 1].id]
        else { return nil }
        return station.name
    }

    private func fuelOrdinal(endingAt stageIndex: Int) -> Int {
        stages.prefix(stageIndex + 1).reduce(0) { count, stage in
            count + (stage.endsAtFuelStop ? 1 : 0)
        }
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
              let meters = stages[index].response?.distanceMeters
        else { return nil }
        let margin = FuelRangePrefs.usableKilometers(for: FuelRangePrefs.kilometers) - meters / 1000
        if margin >= 0 {
            return "\(Int(margin.rounded())) km br"
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
            offset += response.distanceMeters ?? GeoMath.lineMeters(response.coordinates)
        }
        return result
    }

    // MARK: - Map interaction

    /// The only mutation door for rider-owned route intent.
    func apply(_ action: ItineraryAction, source: String) {
        if case .move(let waypointID, let coordinate) = action {
            // Map frameworks may report several drag-end positions while the
            // pin settles. Route only the final coordinate; rebuilding every
            // intermediate position caused cancellation storms and lost fuel
            // projections on multi-waypoint plans.
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
        cancelFuelReplacement()
        let before = itinerary
        let change = reduce(before, action)
        guard change.itinerary != before else { return }
        switch action {
        case .replaceAll, .clear:
            routingSessionSeed = UInt64.random(in: 1...9_007_199_254_740_991)
            // A prior "Not now" must not permanently block route-touch download
            // after the rider changes pins or wipes packs.
            packAcquisition.clearDownloadDeclines()
        default:
            break
        }
        itinerary = change.itinerary
        RoutingDebugLog.shared.event(
            ItineraryLog.line(action: action, before: before, after: itinerary, source: source)
        )
        if isRouting {
            RoutingDebugLog.shared.event(
                "build cancel requested gen=\(before.generation) "
                    + "replacementGen=\(itinerary.generation) source=\(source)"
            )
        }
        buildTask?.cancel()
        itineraryBuilder.setCurrentGeneration(itinerary.generation)

        if showingLoop {
            switch action {
            case .move(let id, let to):
                if itinerary.waypoints.indices.contains(1), itinerary.waypoints[1].id == id {
                    loopFar = to
                }
                generateLoop()
                return
            case .setProfile, .setAllowUnknown, .setAvoidMotorways, .setPreferBackRoads,
                 .setHopProfile, .setHopAllowUnknown, .setHopAvoidMotorways:
                generateLoop()
                return
            case .replaceAll, .clear, .markImpassable:
                break
            default:
                generateLoop()
                return
            }
        }

        // Navigation recovery already owns the rider-position → active-leg-end
        // request. Record the blocked edges canonically, preserve the visible
        // itinerary, and let applyRecoveryRoute commit that current-position leg.
        if case .markImpassable = action, navigation.phase == .active {
            if let current = built {
                built = BuiltItinerary(
                    generation: itinerary.generation,
                    legs: current.legs,
                    riderLegStatus: current.riderLegStatus,
                    riderRoutes: current.riderRoutes,
                    waypointFuelStops: current.waypointFuelStops
                )
            }
            isRouting = false
            refreshMap()
            return
        }

        guard let fromLeg = change.rebuildFromLegIndex else {
            cameraBuildGeneration = nil
            cameraBuildLegKeys = []
            mapState.cancelRouteBuildCamera()
            built = BuiltItinerary.empty(for: itinerary)
            isRouting = false
            refreshMap()
            return
        }
        if shouldChoreographCamera(for: action, source: source),
           let first = itinerary.waypoints.first?.coordinate {
            cameraBuildGeneration = itinerary.generation
            cameraBuildLegKeys = []
            mapState.beginRouteBuildCamera(at: first)
            RoutingDebugLog.shared.event(
                "camera build begin gen=\(itinerary.generation) source=\(source)"
            )
        } else {
            cameraBuildGeneration = nil
            cameraBuildLegKeys = []
            mapState.cancelRouteBuildCamera()
        }
        startCanonicalBuild(
            from: fromLeg,
            through: change.rebuildThroughLegIndex,
            reuse: built,
            replanFromStationID: change.replanFromStationID
        )
    }

    var packConsent: PackConsentPrompt? { packAcquisition.consent }
    var packRoutingWarnings: [PackRoutingWarning] { packAcquisition.warnings }

    func acceptPackConsent() async {
        do {
            try await packAcquisition.acceptConsent()
            resumePendingPackBuild()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isRouting = false
            isAssemblingRoute = false
            if toast == Self.calculatingRouteToast { toast = nil }
        }
    }

    func declinePackConsent() {
        packAcquisition.declineConsent()
        resumePendingPackBuild()
    }

    func notePackRemoved(_ regionID: String) {
        packAcquisition.notePackRemoved(regionID)
    }

    private func resumePendingPackBuild() {
        guard let pending = pendingPackBuild else { return }
        pendingPackBuild = nil
        startCanonicalBuild(
            from: pending.from,
            through: pending.through,
            reuse: pending.reuse,
            replanFromStationID: pending.replanFromStationID
        )
    }

    private func startCanonicalBuild(
        from legIndex: Int,
        through throughLegIndex: Int? = nil,
        reuse: BuiltItinerary?,
        replanFromStationID: String? = nil
    ) {
        let requested = itinerary
        let preferences = ridePreferences
        let fuel = FuelRangePrefs.snapshot
        let initialProgress = Self.initialBuildProgressToast(for: fuel)
        canonicalBuildStartCount += 1
        lastCanonicalBuildFromLegIndex = legIndex
        isRouting = true
        isAssemblingRoute = true
        fuelPlanNotice = nil
        fuelPlanningStatus = initialProgress
        toast = initialProgress
        refreshMap()
        buildTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let coords = requested.waypoints.map(\.coordinate.locationCoordinate)
            let primaries = coords.compactMap { GraphPackStore.primaryRegionId(containing: $0) }
            let geographic = GraphPackStore.requiredRoutingRegions(for: coords)
            let catalog = self.graphPacks.requiredCatalogRoutingRegions(for: coords)
            #if DIRT_DEVELOPMENT
            let fabric = AppConfig.v4CandidateReleaseId
            #else
            let fabric = "production"
            #endif
            RoutingDebugLog.shared.event(
                "pack acquisition begin stamp=\(RoutingDebugLog.diagnosticStamp) " +
                    "fabric=\(fabric) primaries=\(primaries.joined(separator: ",")) " +
                    "geographic=\(geographic.joined(separator: ",")) " +
                    "catalog=\(catalog.joined(separator: ","))"
            )
            let acquisition = self.packAcquisition.evaluate(
                coordinates: coords,
                protectInstalledRevisions: self.graphPacks.protectInstalledRevisions)
            switch acquisition {
            case .requestConsent(let prompt):
                RoutingDebugLog.shared.event(
                    "pack consent requested kind=\(prompt.kind == .update ? "update" : "download") " +
                        "regions=\(prompt.regionIDs.joined(separator: ","))"
                )
                self.pendingPackBuild = (from: legIndex,through: throughLegIndex,reuse: reuse,replanFromStationID: replanFromStationID)
                self.isRouting = false; self.isAssemblingRoute = false; self.toast = nil
                return
            case .unavailable(let warning):
                RoutingDebugLog.shared.event(
                    "pack acquisition unavailable reason=\(warning.reason == .declinedDownload ? "declined" : "missing") " +
                        "regions=\(warning.regionIDs.joined(separator: ","))"
                )
                self.isRouting = false; self.isAssemblingRoute = false
                self.errorMessage = warning.message; self.toast = nil
                return
            case .useInstalledPacks:
                RoutingDebugLog.shared.event(
                    "pack acquisition useInstalled catalog=\(catalog.joined(separator: ","))"
                )
            }

            self.itineraryBuilder.mapZoom = self.mapState.mapZoom
            let result = await RidePreferenceContext.$current.withValue(preferences) {
                await RoutingSessionContext.$seed.withValue(self.routingSessionSeed) {
                    await self.itineraryBuilder.build(
                        requested,
                        from: legIndex,
                        through: throughLegIndex,
                        reuse: reuse,
                        fuel: fuel,
                        source: self.routingSourcePolicy,
                        replanFromStationID: replanFromStationID,
                        onFuelStatus: { [weak self] _ in
                            guard let self, self.itinerary.generation == requested.generation else { return }
                            // Keep the map toast on craft hype — never surface fuel-planning copy.
                            self.fuelPlanningStatus = Self.craftingRouteToast
                            self.toast = Self.craftingRouteToast
                        },
                        onProgress: { [weak self] progress in
                            guard let self, self.itinerary.generation == progress.generation else { return }
                            self.built = progress
                            self.advanceRouteBuildCamera(with: progress)
                            self.refreshMap()
                        }
                    )
                }
            }
            guard !Task.isCancelled else {
                RoutingDebugLog.shared.event(
                    "build result discarded requestedGen=\(requested.generation) "
                        + "resultGen=\(result.generation) currentGen=\(self.itinerary.generation) "
                        + "reason=cancelled"
                )
                return
            }
            guard self.itinerary.generation == result.generation else {
                RoutingDebugLog.shared.event(
                    "build result discarded requestedGen=\(requested.generation) "
                        + "resultGen=\(result.generation) currentGen=\(self.itinerary.generation) "
                        + "reason=stale"
                )
                return
            }
            self.built = result
            self.syncSnappedDestinationPin(from: result)
            self.advanceRouteBuildCamera(with: result)
            let currentGapIDs = Set(result.riderLegStatus.values.compactMap { status -> String? in
                if case .gap(let gap) = status { return gap.id }
                return nil
            })
            self.acknowledgedFuelGapIDs.formIntersection(currentGapIDs)
            var activeStations: [UUID: Set<String>] = [:]
            for leg in result.legs {
                if let stationID = leg.endsAtFuelStop?.stationID {
                    activeStations[leg.riderLegID, default: []].insert(stationID)
                }
            }
            for riderLeg in self.itinerary.legs {
                if case .gap = result.riderLegStatus[riderLeg.id] {
                    activeStations[riderLeg.id, default: []]
                        .formUnion(riderLeg.fuelStopOverrides.values)
                    activeStations[riderLeg.id, default: []]
                        .formUnion(riderLeg.fuelStopOverrides.keys)
                }
            }
            self.itinerary.pruneHopOverrides(to: activeStations)
            self.itinerary.pruneFuelStopOverrides(to: activeStations)
            self.isRouting = false
            self.isAssemblingRoute = false
            self.fuelPlanningStatus = nil
            let hardFailure = result.riderLegStatus.values.compactMap {
                if case .failed(let message) = $0 { return message }
                return nil
            }.first
            let fuelFailure = result.riderLegStatus.values.compactMap {
                if case .fuelUnknown(let message) = $0 { return message }
                return nil
            }.first
            // Fuel proof is advisory once road geometry exists. Only a route
            // geometry failure belongs in the blocking error channel.
            self.errorMessage = hardFailure
            if self.errorMessage == nil {
                self.routeIdentity = "plan:" + self.itinerary.waypoints.dropFirst().map {
                    "\($0.coordinate.latitude),\($0.coordinate.longitude)"
                }.joined(separator: ";")
                if self.toast != Self.legCompleteToast {
                    self.announceRouteReadyIfComplete()
                }
            } else if let error = self.errorMessage {
                self.toast = error
            }
            if let gap = result.riderLegStatus.values.compactMap({ status -> FuelGap? in
                if case .gap(let gap) = status { return gap }
                return nil
            }).first {
                self.toast = gap.message
            } else if let fuelFailure {
                self.toast = Self.userFacingFuelFailureMessage(fuelFailure)
            } else {
                let requestedProfiles = Dictionary(uniqueKeysWithValues: self.itinerary.legs.map {
                    ($0.id, $0.profile)
                })
                let defaultedCleanCount = result.legs.filter {
                    $0.routeProfile == .cleanest && requestedProfiles[$0.riderLegID] != .cleanest
                }.count
                if defaultedCleanCount > 3 {
                    let notice = "Long route — planned as Clean between fuel stops. Tap any leg to make it Dirt."
                    self.fuelPlanNotice = notice
                    self.toast = notice
                }
            }
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
            .replaceAll(
                waypoints: coordinates,
                profile: profile,
                allowUnknown: allowUnknown,
                avoidMotorways: avoidMotorways,
                preferBackRoads: preferBackRoads
            )
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
            }),
            riderRoutes: Dictionary(uniqueKeysWithValues: legs.map { ($0.riderLegID, $0.response) })
        )
        RoutingDebugLog.shared.event(
            ItineraryLog.line(
                action: .replaceAll(
                    waypoints: coordinates,
                    profile: profile,
                    allowUnknown: allowUnknown,
                    avoidMotorways: avoidMotorways,
                    preferBackRoads: preferBackRoads
                ),
                before: before,
                after: itinerary,
                source: "seed"
            )
        )
    }

    func waitForCanonicalBuildForTesting() async {
        // A drag may still be inside its settle window. Await the pending move
        // first so the test hook never observes the previous completed build.
        await moveDebounceTask?.value
        await buildTask?.value
    }

    var pendingGroupMemberUserIDForTesting: String? { pendingGroupTracking?.userID }
    var activeGroupMemberUserIDForTesting: String? { activeGroupTracking?.userID }

    func installActiveGroupTrackingForTesting(_ target: GroupMemberRouteTarget) {
        activeGroupTracking = ActiveGroupTracking(
            groupID: target.groupID,
            userID: target.userID,
            displayName: target.displayName,
            routedCoordinate: target.coordinate,
            latestTarget: target,
            deferredCoordinate: nil
        )
    }

    /// From here drops point 2 as soon as the rider taps — before on-device routing returns.
    static let paintsDestinationImmediatelyOnFromHereTap = true
    static let calculatingRouteToast = "Calculating route"
    static let routeReadyToast = "Route successful"
    static let calculatingFuelRangeToast = "Checking fuel range"
    /// Stable build-progress key. ToastView rotates rider-facing hype over this — never show raw.
    static let craftingRouteToast = "Crafting your route"
    static let noFuelStopRequiredToast = "No fuel stop required"
    static let legCompleteToast = "Leg complete"

    struct ProgressToastContent: Equatable {
        let title: String
        let detail: String
    }

    /// Rotating build lines — outdoor-legible, rider hype, zero fuel/corporate planning speak.
    static let routeBuildHypeLines: [ProgressToastContent] = [
        ProgressToastContent(
            title: "Creating the time of your life…",
            detail: "Scouting roads worth the ride"
        ),
        ProgressToastContent(
            title: "Adding twisty pavement…",
            detail: "Dirt's lining up the good miles"
        ),
        ProgressToastContent(
            title: "Stitching a proper adventure…",
            detail: "One turn at a time"
        ),
        ProgressToastContent(
            title: "Hunting the sweet line…",
            detail: "Almost ready to twist the throttle"
        ),
        ProgressToastContent(
            title: "Loading up the fun…",
            detail: "Crafting something you'll want again"
        )
    ]

    static func initialBuildProgressToast(for _: FuelRangePrefs.Snapshot) -> String {
        craftingRouteToast
    }

    /// True when the map progress toast should rotate craft hype instead of raw status.
    static func usesRotatingBuildHype(for message: String) -> Bool {
        switch message {
        case craftingRouteToast, calculatingRouteToast:
            return true
        default:
            return false
        }
    }

    static func progressToastContent(for message: String) -> ProgressToastContent? {
        switch message {
        case calculatingRouteToast, craftingRouteToast:
            return routeBuildHypeLines[0]
        case calculatingFuelRangeToast,
             "Checking fuel after destination",
             noFuelStopRequiredToast:
            // Fuel-chain internals may still emit these; rider toast stays on craft hype.
            return routeBuildHypeLines[0]
        default:
            if message.hasPrefix("Finding loop") {
                return ProgressToastContent(
                    title: message,
                    detail: "Comparing roads for your round trip"
                )
            }
            if message.hasPrefix("Creating fuel stop ")
                || (message.hasPrefix("Fuel stop ") && message.hasSuffix(" added"))
                || message.hasPrefix("Checking range after fuel stop ") {
                return routeBuildHypeLines[0]
            }
            return nil
        }
    }

    static func isPersistentProgressToast(_ message: String) -> Bool {
        progressToastContent(for: message) != nil
    }

    static func activeRouteProgressMessage(
        fuelPlanningStatus: String?,
        isRouting: Bool,
        toast: String?
    ) -> String? {
        if let fuelPlanningStatus { return fuelPlanningStatus }
        guard isRouting else { return nil }
        if let toast, isPersistentProgressToast(toast) { return toast }
        return calculatingRouteToast
    }

    /// Route-build progress is independent from transient tap feedback. A map
    /// interaction may replace `toast`, but it must never hide the active job.
    var activeRouteProgressMessage: String? {
        Self.activeRouteProgressMessage(
            fuelPlanningStatus: fuelPlanningStatus,
            isRouting: isRouting,
            toast: toast
        )
    }

    /// True while From here / Plan is still building the full route
    /// (including chained fuel stops). Holds the indeterminate progress notice.
    private var isAssemblingRoute = false
    /// Fresh create mints a new seed; saved/resume/nav freeze it.
    private(set) var routingSessionSeed: UInt64 = UInt64.random(in: 1...9_007_199_254_740_991)
    /// Stable within this app process; a fresh launch can pick a different near-equal corridor.
    var planningSessionSeed: UInt64 { routingSessionSeed }

    func handleMapTap(_ coordinate: CLLocationCoordinate2D) {
        guard navigation.phase == .idle else { return }
        let point = RouteCoordinate(longitude: coordinate.longitude, latitude: coordinate.latitude)
        if showingLoop { return }
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
              mode == .plan || mode == .fromHere,
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
        waypointMove = nil
        waypointPlacement = (resolvedRiderLegID, nearest.point)
        showsWaypointPlacementConfirmation = false
        refreshMap()
        mapState.selectPlannerPin("waypoint-draft")
        RoutingDebugLog.shared.event("ui waypoint placement draft leg=\(resolvedRiderLegID)")
    }

    var waypointPlacement: (legID: UUID, coordinate: RouteCoordinate)?
    var waypointMove: (id: UUID, coordinate: RouteCoordinate)?
    var showsWaypointPlacementConfirmation = false

    func keepMovingWaypoint() {
        showsWaypointPlacementConfirmation = false
        toast = "Drag the waypoint to your preferred location"
    }

    func confirmWaypointPlacement() {
        guard showsWaypointPlacementConfirmation, navigation.phase == .idle, !isRouting else { return }
        if let move = waypointMove {
            waypointMove = nil
            showsWaypointPlacementConfirmation = false
            mapState.selectPlannerPin(nil)
            apply(.move(waypointID: move.id, to: move.coordinate), source: "confirmedMove")
            return
        }
        guard let draft = waypointPlacement, navigation.phase == .idle, !isRouting,
              itinerary.legs.contains(where: { $0.id == draft.legID }) else { return }
        waypointPlacement = nil
        waypointMove = nil
        showsWaypointPlacementConfirmation = false
        if mode == .fromHere { switchToPlanKeepingFromHere() }
        apply(.insert(afterLegID: draft.legID, coordinate: draft.coordinate), source: "confirmedPlacement")
        RoutingDebugLog.shared.event("ui waypoint placement confirmed leg=\(draft.legID)")
    }

    func handleMapLongPress(_ coordinate: CLLocationCoordinate2D) {
        guard navigation.phase == .idle else { return }
        let point = RouteCoordinate(longitude: coordinate.longitude, latitude: coordinate.latitude)
        if showingLoop {
            loopFar = point
            errorMessage = nil
            if hasRoute, itinerary.waypoints.count >= 3 {
                apply(.move(waypointID: itinerary.waypoints[1].id, to: point), source: "loopFar")
            } else {
                generateLoop()
            }
            return
        }
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
        pendingGroupTracking = nil
        buildTask?.cancel()
        mapState.cancelRouteBuildCamera()
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
        mapState.cancelRouteBuildCamera()
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
        pendingGroupTracking = nil
        apply(.append(coordinate: point), source: "longPress")
    }

    private func shouldChoreographCamera(
        for action: ItineraryAction,
        source: String
    ) -> Bool {
        switch action {
        case .append, .insert:
            return true
        case .replaceAll:
            return source == "fromHere"
        default:
            return false
        }
    }

    private func advanceRouteBuildCamera(with progress: BuiltItinerary) {
        guard cameraBuildGeneration == progress.generation else { return }
        for leg in progress.legs {
            let key = routeBuildCameraKey(for: leg)
            let coordinates = leg.response.coordinates
            guard coordinates.count >= 2 else { continue }
            guard cameraBuildLegKeys.insert(key).inserted else { continue }
            mapState.appendCompletedRouteBuildLeg(coordinates)
            RoutingDebugLog.shared.event(
                "camera build leg gen=\(progress.generation) "
                    + "number=\(cameraBuildLegKeys.count) points=\(coordinates.count)"
            )
        }
    }

    private func routeBuildCameraKey(for leg: BuiltLeg) -> String {
        let meters = Int((leg.response.distanceMeters ?? 0).rounded())
        let station = leg.endsAtFuelStop?.stationID ?? "waypoint"
        return "\(leg.riderLegID.uuidString)|\(leg.fromCoordinate.latitude),\(leg.fromCoordinate.longitude)"
            + ">\(leg.toCoordinate.latitude),\(leg.toCoordinate.longitude)|\(station)|\(meters)"
    }

    /// Per-stage surface mode (each stage is its own on-device routing request).
    func setStageProfile(_ newProfile: RouteProfile, at index: Int) {
        guard stages.indices.contains(index) else { return }
        apply(.setProfile(legID: stages[index].riderLegID, newProfile), source: "card")
    }

    func setFuelHopProfile(_ newProfile: RouteProfile, at index: Int) {
        guard stages.indices.contains(index) else { return }
        let stage = stages[index]
        guard let leg = itinerary.legs.first(where: { $0.id == stage.riderLegID }) else { return }
        // A pump departure keeps a hop override. Departing from the rider
        // waypoint (or an unbuilt stage) owns the whole span — same path as
        // setStageProfile — so Plan Clean → Dirt/Balanced actually rebuilds.
        if let stationID = stage.departureFuelStopID,
           stationID != leg.from.uuidString {
            guard leg.effectiveProfile(departingFrom: stationID) != newProfile else { return }
            RoutingDebugLog.shared.event(
                "fuel leg override departure=\(stationID) profile=\(newProfile.rawValue) " +
                    "replanFrom=\(stationID)"
            )
            apply(
                .setHopProfile(
                    legID: stage.riderLegID,
                    stationID: stationID,
                    newProfile
                ),
                source: "card-hop"
            )
        } else {
            apply(.setProfile(legID: stage.riderLegID, newProfile), source: "card-hop-first")
        }
    }

    func acknowledgeFuelGap(_ gap: FuelGap) {
        acknowledgedFuelGapIDs.insert(gap.id)
        toast = "Fuel gap marked: rider will carry auxiliary fuel"
        RoutingDebugLog.shared.event("fuel gap acknowledged id=\(gap.id)")
    }

    func isFuelGapAcknowledged(_ gap: FuelGap) -> Bool {
        acknowledgedFuelGapIDs.contains(gap.id)
    }

    func hasFuelStopOverride(for riderLegID: UUID) -> Bool {
        itinerary.legs.first(where: { $0.id == riderLegID })?.fuelStopOverrides.isEmpty == false
    }

    func revertFuelStopOverrides(for riderLegID: UUID) {
        apply(.clearFuelStopOverrides(legID: riderLegID), source: "fuel-gap-revert")
    }

    var fuelGaps: [FuelGap] {
        guard let built else { return [] }
        return itinerary.legs.compactMap { leg in
            guard case .gap(let gap) = built.riderLegStatus[leg.id] else { return nil }
            return gap
        }
    }

    var unacknowledgedFuelGaps: [FuelGap] {
        fuelGaps.filter { !acknowledgedFuelGapIDs.contains($0.id) }
    }

    var fuelUnknownMessages: [String] {
        guard let built else { return [] }
        return itinerary.legs.compactMap { leg in
            guard case .fuelUnknown(let message) = built.riderLegStatus[leg.id] else { return nil }
            return message
        }
    }

    /// Fuel confidence is route-level information. It identifies the exact
    /// generated span without replacing that span's valid route metrics.
    var fuelCoverageNotices: [FuelCoverageNotice] {
        stages.enumerated().compactMap { index, stage in
            let scope = "Leg \(index + 1) · \(stageEndpointTitle(at: index))"
            if let gap = stage.fuelGap {
                return FuelCoverageNotice(
                    id: "\(stage.id):fuel-gap",
                    stageIndex: index,
                    kind: .gap,
                    title: "Fuel range gap",
                    scope: scope,
                    message: gap.message
                )
            }
            if let message = stage.fuelUnknown {
                return FuelCoverageNotice(
                    id: "\(stage.id):fuel-unverified",
                    stageIndex: index,
                    kind: .unverified,
                    title: "Fuel coverage unverified",
                    scope: scope,
                    message: message
                )
            }
            return nil
        }
    }

    func prepareToMoveWaypoint(for riderLegID: UUID) {
        guard let index = itinerary.legs.firstIndex(where: { $0.id == riderLegID }),
              itinerary.waypoints.indices.contains(index + 1)
        else { return }
        let waypointID = itinerary.waypoints[index + 1].id
        mapState.selectPlannerPin("wp:\(waypointID.uuidString)")
        toast = "Move Point \(index + 2) to shorten the fuel gap"
        focusStage(at: stages.firstIndex(where: { $0.riderLegID == riderLegID }) ?? 0)
    }

    /// Per-stage unknown-access policy.
    func setStageAllowUnknown(_ allow: Bool, at index: Int) {
        guard stages.indices.contains(index) else { return }
        let stage = stages[index]
        guard let leg = itinerary.legs.first(where: { $0.id == stage.riderLegID }) else { return }
        if let departureID = stage.departureFuelStopID,
           departureID != leg.from.uuidString {
            apply(
                .setHopAllowUnknown(
                    legID: stage.riderLegID,
                    stationID: departureID,
                    allow
                ),
                source: "card-hop-unknown"
            )
        } else {
            apply(
                .setAllowUnknown(legID: stage.riderLegID, allow),
                source: "card-hop-unknown-first"
            )
        }
    }

    func setStageAvoidMotorways(_ on: Bool, at index: Int) {
        guard stages.indices.contains(index) else { return }
        let stage = stages[index]
        if let departureID = stage.departureFuelStopID {
            apply(
                .setHopAvoidMotorways(
                    legID: stage.riderLegID,
                    stationID: departureID,
                    on
                ),
                source: "card-hop-highway"
            )
        } else {
            apply(.setAvoidMotorways(legID: stage.riderLegID, on), source: "card")
        }
    }

    func setStagePreferBackRoads(_ on: Bool, at index: Int) {
        guard stages.indices.contains(index) else { return }
        apply(.setPreferBackRoads(legID: stages[index].riderLegID, on), source: "card")
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
                if distance == nil || distance! > NativeRoutingAdapter.maximumMatchMeters {
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
                allowUnknown: allowUnknown,
                avoidMotorways: avoidMotorways,
                preferBackRoads: preferBackRoads
            ),
            source: "fromHere"
        )
    }

    private static let offGraphStartMessage =
        "Your start (GPS) isn’t close enough to a mapped road. Tap the nearest road to set point 1 — point 2 stays put."

    private func enterFromHereNeedsStartPin(startMeters: Int? = nil) {
        fromHereNeedsStartPin = true
        // Only use the “about N m / limit 550” copy when the start is actually beyond
        // soft-approach. Within the limit, noPath is a fabric/profile issue — not tap-A.
        if let startMeters, startMeters > Int(NativeRoutingAdapter.maximumMatchMeters) {
            errorMessage =
                "Your start (GPS) is about \(startMeters) m from the nearest mapped road (limit \(Int(NativeRoutingAdapter.maximumMatchMeters)) m). Tap the road to set point 1 — point 2 stays put."
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
        return distance > NativeRoutingAdapter.maximumMatchMeters
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
        if !needed.isEmpty, needed.allSatisfy({ store.hasCompleteNativePack($0) }) {
            return true
        }
        let primaries = ends.compactMap { GraphPackStore.primaryRegionId(containing: $0) }
        guard let first = primaries.first, primaries.allSatisfy({ $0 == first }) else {
            return false
        }
        return store.hasCompleteNativePack(first)
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
        waypointPlacement = nil
        waypointMove = nil
        showsWaypointPlacementConfirmation = false
        cancelFuelReplacement()
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

        cancelGroupRouteUpdate(resetStopState: false)
        cancelNavigationReroute()
        navigationRerouteGeneration += 1
        let requestGeneration = navigationRerouteGeneration

        if shouldPreserveStagesForRecovery,
           let idx = activeStageIndex(near: rider),
           let stageEnd = stages[idx].end {
            navigationRerouteTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.rerouteActiveStage(
                    at: idx,
                    from: rider,
                    to: stageEnd,
                    avoidEdgeIds: [],
                    networkOnline: networkOnline,
                    announce: true,
                    requestGeneration: requestGeneration
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

        navigationRerouteTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await self.routeWhileNavigating(
                    from: rider,
                    to: target,
                    networkOnline: networkOnline
                )
                guard !Task.isCancelled,
                      self.navigationRerouteGeneration == requestGeneration,
                      self.navigation.phase == .active
                else { return }
                self.mode = .fromHere
                self.destination = target
                self.seedCanonicalBuild(
                    coordinates: [rider, target],
                    profile: self.profile,
                    allowUnknown: self.allowUnknown,
                    responses: [response]
                )
                let display = MapState.displaySegments(from: [response])
                self.navigation.replaceRoute(
                    coordinates: response.coordinates,
                    maneuvers: response.maneuvers ?? [],
                    segments: display,
                    networkSegments: self.networkSegments(from: [response])
                )
            } catch {
                guard !Task.isCancelled,
                      self.navigationRerouteGeneration == requestGeneration
                else { return }
                self.toast = error.localizedDescription
            }
        }
    }

    private func cancelNavigationReroute() {
        navigationRerouteTask?.cancel()
        navigationRerouteTask = nil
        navigationRerouteGeneration += 1
    }

    // MARK: - Waypoint drag (map pin drag-to-move)

    /// The map snaps a drag-release to its nearest visible road. Keep the
    /// proposed coordinate separate until the rider confirms; never project
    /// the pin back onto the old route or start a search during placement.
    func moveWaypoint(markerID: String, to rawCoordinate: CLLocationCoordinate2D) {
        guard navigation.phase == .idle, !isRouting else { return }
        if markerID.hasPrefix("fuel:") {
            moveFuelStop(markerID: markerID, to: rawCoordinate)
            return
        }
        if markerID == "waypoint-draft", let draft = waypointPlacement {
            waypointPlacement = (draft.legID, RouteCoordinate(longitude: rawCoordinate.longitude, latitude: rawCoordinate.latitude))
            showsWaypointPlacementConfirmation = true
            refreshMap()
            mapState.selectPlannerPin(markerID)
            return
        }
        let raw = RouteCoordinate(longitude: rawCoordinate.longitude, latitude: rawCoordinate.latitude)
        // Map coordinator already snaps the drop to a visible road; do not pull
        // it back onto the old route the rider is deliberately reshaping.
        let snapped = raw
        if showingLoop {
            if markerID == "loop-far" {
                loopFar = snapped
                generateLoop()
                return
            }
            movePlanStyleWaypoint(markerID: markerID, snapped: snapped)
            return
        }
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

    func beginPlannerPinDrag(markerID: String) {
        guard navigation.phase == .idle, !isRouting else { return }
        if markerID.hasPrefix("fuel-target:") {
            selectFuelTarget(markerID: markerID)
            return
        }
        // MapLibre re-selects the active annotation after markers are redrawn.
        // Treat that callback as idempotent; toggling here made replacement
        // candidates flash briefly and then disappear before a rider could tap.
        if activeFuelDragMarkerID == markerID {
            return
        }
        guard markerID.hasPrefix("fuel:"),
              let context = fuelMoveContext(markerID: markerID)
        else {
            // Do not redraw/reselect the annotation while its pan is beginning.
            // The selected waypoint already has its editing chrome.
            if activeFuelDragMarkerID != nil {
                cancelFuelReplacement()
            }
            return
        }
        cancelFuelReplacement()
        activeFuelDragMarkerID = markerID
        mapState.selectPlannerPin(markerID)
        fuelTargetMarkers = context.leg.validFuelTargets.compactMap { candidate in
            guard candidate.validForward == true,
                  let latitude = candidate.latitude,
                  let longitude = candidate.longitude
            else { return nil }
            return MapState.Marker(
                id: "fuel-target:\(candidate.id)",
                latitude: latitude,
                longitude: longitude,
                label: "•",
                kind: .fuel,
                subtitle: candidate.name ?? "Valid fuel stop",
                isLocked: true
            )
        }
        if fuelTargetMarkers.isEmpty {
            loadFuelReplacements(markerID: markerID)
        }
        refreshMap()
    }

    private func loadFuelReplacements(markerID: String) {
        guard let context = fuelMoveContext(markerID: markerID), let original = built,
              let stop = context.leg.endsAtFuelStop,
              let legIndex = itinerary.legs.firstIndex(where: { $0.id == context.riderLeg.id }),
              let stopIndex = original.legs.firstIndex(where: { $0 == context.leg }) else { return }
        let runID = UUID(), requested = itinerary, preferences = ridePreferences
        let fuel = FuelRangePrefs.snapshot, zoom = mapState.mapZoom
        fuelReplacementRunID = runID
        toast = "Checking nearby fuel stops"
        fuelReplacementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let padLat = 25_000.0/111_000
                let padLon = padLat/max(0.01,cos(stop.coordinate.latitude * .pi/180))
                try Task.checkCancellation()
                let stations = self.graphPacks.fuelStations(minLat: stop.coordinate.latitude-padLat,maxLat: stop.coordinate.latitude+padLat,
                    minLon: stop.coordinate.longitude-padLon,maxLon: stop.coordinate.longitude+padLon)
                    .filter { $0.id != stop.stationID }.sorted {
                        GeoMath.meters(stop.coordinate,RouteCoordinate(longitude: $0.longitude,latitude: $0.latitude)) <
                        GeoMath.meters(stop.coordinate,RouteCoordinate(longitude: $1.longitude,latitude: $1.latitude))
                    }.prefix(6)
                for station in stations {
                    guard !Task.isCancelled, self.fuelReplacementRunID == runID,
                          self.itinerary == requested, self.navigation.phase == .idle else { return }
                    let change = reduce(requested, .setFuelStopOverride(legID: context.riderLeg.id,
                        departureAnchorID: context.departureAnchorID, stationID: station.id))
                    let builder = ItineraryBuilder()
                    builder.mapZoom = zoom
                    let result = await RidePreferenceContext.$current.withValue(preferences) {
                        await RoutingSessionContext.$seed.withValue(self.routingSessionSeed) {
                            await builder.build(
                                change.itinerary,
                                from: legIndex,
                                reuse: original,
                                fuel: fuel,
                                source: self.routingSourcePolicy,
                                replanFromStationID: change.replanFromStationID,
                                onProgress: { _ in }
                            )
                        }
                    }
                    guard !Task.isCancelled, self.fuelReplacementRunID == runID,
                          self.itinerary == requested, self.navigation.phase == .idle else { return }
                    guard change.itinerary.legs.allSatisfy({ result.riderLegStatus[$0.id] == .built }),
                          result.legs.count > stopIndex,
                          Array(result.legs.prefix(stopIndex)) == Array(original.legs.prefix(stopIndex)),
                          result.legs[stopIndex].endsAtFuelStop?.stationID == station.id else { continue }
                    self.checkedFuelReplacements[station.id] = (requested, change.itinerary, result)
                    self.fuelTargetMarkers.append(MapState.Marker(id: "fuel-target:\(station.id)",
                        latitude: station.latitude, longitude: station.longitude, label: "•", kind: .fuel,
                        subtitle: station.displayName, isLocked: true))
                    self.toast = "Choose a highlighted pump"
                    self.refreshMap()
                    self.mapState.fit([stop.coordinate] + self.fuelTargetMarkers.map {
                        RouteCoordinate(longitude: $0.longitude, latitude: $0.latitude)
                    })
                }
                guard self.fuelReplacementRunID == runID else { return }
                self.toast = self.fuelTargetMarkers.isEmpty
                    ? "No verified alternatives nearby" : "Choose a highlighted pump"
            } catch {
                guard !Task.isCancelled, self.fuelReplacementRunID == runID else { return }
                self.toast = "Couldn’t check nearby fuel stops. Tap another pin, then try again."
            }
        }
    }

    func canReplaceFuelStop(at stageIndex: Int) -> Bool {
        guard stages.indices.contains(stageIndex),
              let builtLegIndex = stages[stageIndex].builtLegIndex
        else { return false }
        return stages[stageIndex].endsAtFuelStop
            && built?.legs.indices.contains(builtLegIndex) == true
            && navigation.phase == .idle && !isRouting
    }

    func selectFuelWaypoint(at stageIndex: Int) {
        guard stages.indices.contains(stageIndex),
              let builtLegIndex = stages[stageIndex].builtLegIndex,
              let built,
              built.legs.indices.contains(builtLegIndex),
              built.legs[builtLegIndex].endsAtFuelStop != nil
        else { return }
        let markerID = "fuel:\(built.legs[builtLegIndex].riderLegID.uuidString):\(builtLegIndex)"
        mapState.selectPlannerPin(markerID)
        beginPlannerPinDrag(markerID: markerID)
        if !fuelTargetMarkers.isEmpty { toast = "Choose a highlighted pump" }
    }

    func selectFuelTarget(markerID: String) {
        guard markerID.hasPrefix("fuel-target:"),
              let activeFuelDragMarkerID,
              let context = fuelMoveContext(markerID: activeFuelDragMarkerID)
        else { return }
        let stationID = String(markerID.dropFirst("fuel-target:".count))
        guard navigation.phase == .idle, !isRouting else { return }
        if let checked = checkedFuelReplacements[stationID], checked.original == itinerary {
            cancelFuelReplacement()
            itinerary = checked.proposed
            built = checked.built
            syncSnappedDestinationPin(from: checked.built)
            errorMessage = nil
            fuelPlanNotice = nil
            acknowledgedFuelGapIDs = []
            mapState.selectPlannerPin(nil)
            toast = "Fuel stop updated"
            refreshMap()
            RoutingDebugLog.shared.event("fuel replacement committed station=\(stationID) gen=\(itinerary.generation)")
            return
        }
        guard context.leg.validFuelTargets.contains(where: {
            $0.id == stationID && $0.validForward == true
        }) else { return }
        RoutingDebugLog.shared.event(
            "fuel stop override riderLeg=\(context.riderLeg.id) from=\(context.departureAnchorID) " +
                "to=\(stationID) source=tap"
        )
        fuelTargetMarkers = []
        self.activeFuelDragMarkerID = nil
        mapState.selectPlannerPin(nil)
        apply(
            .setFuelStopOverride(
                legID: context.riderLeg.id,
                departureAnchorID: context.departureAnchorID,
                stationID: stationID
            ),
            source: "fuel-tap"
        )
    }

    private func moveFuelStop(markerID: String, to coordinate: CLLocationCoordinate2D) {
        defer {
            fuelTargetMarkers = []
            activeFuelDragMarkerID = nil
            mapState.selectPlannerPin(nil)
            refreshMap()
        }
        guard let context = fuelMoveContext(markerID: markerID) else { return }
        let dropped = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let targets = context.leg.validFuelTargets.compactMap { candidate -> (FuelStationCandidate, Double)? in
            guard candidate.validForward == true,
                  let latitude = candidate.latitude,
                  let longitude = candidate.longitude
            else { return nil }
            let meters = dropped.distance(from: CLLocation(latitude: latitude, longitude: longitude))
            return (candidate, meters)
        }
        guard let nearest = targets.min(by: { $0.1 < $1.1 }), nearest.1 <= 5_000 else {
            toast = "Drop the fuel pin on one of the highlighted stations."
            return
        }
        RoutingDebugLog.shared.event(
            "fuel stop override riderLeg=\(context.riderLeg.id) from=\(context.departureAnchorID) " +
                "to=\(nearest.0.id) validTargets=\(targets.count)"
        )
        apply(
            .setFuelStopOverride(
                legID: context.riderLeg.id,
                departureAnchorID: context.departureAnchorID,
                stationID: nearest.0.id
            ),
            source: "fuel-drag"
        )
    }

    private func fuelMoveContext(markerID: String) -> (
        leg: BuiltLeg, riderLeg: RiderLeg, departureAnchorID: String
    )? {
        let parts = markerID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let index = Int(parts[2]),
              let built, built.legs.indices.contains(index),
              UUID(uuidString: String(parts[1])) == built.legs[index].riderLegID,
              built.legs[index].endsAtFuelStop != nil,
              let riderLeg = itinerary.legs.first(where: { $0.id == built.legs[index].riderLegID })
        else { return nil }
        let previousStop = index > 0 && built.legs[index - 1].riderLegID == riderLeg.id
            ? built.legs[index - 1].endsAtFuelStop?.stationID
            : nil
        return (built.legs[index], riderLeg, previousStop ?? riderLeg.from.uuidString)
    }

    private func movePlanStyleWaypoint(markerID: String, snapped: RouteCoordinate) {
        guard markerID.hasPrefix("wp:"),
              let waypointID = UUID(uuidString: String(markerID.dropFirst(3))),
              itinerary.waypoints.contains(where: { $0.id == waypointID })
        else { return }
        waypointPlacement = nil
        waypointMove = (waypointID, snapped)
        showsWaypointPlacementConfirmation = true
        refreshMap()
        mapState.selectPlannerPin(markerID)
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
        pendingGroupTracking = nil
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
        pendingGroupTracking = nil
        let point = RouteCoordinate(longitude: longitude, latitude: latitude)
        if mode != .plan { mode = .plan }
        appendPlanPoint(point)
    }

    var canCloseLoop: Bool {
        (mode == .plan || mode == .fromHere) && navigation.phase == .idle && Self.loopReturnPoint(in: itinerary) != nil
    }

    static func loopReturnPoint(in itinerary: RiderItinerary) -> RouteCoordinate? {
        guard itinerary.waypoints.count >= 2,
              let first = itinerary.waypoints.first?.coordinate,
              let last = itinerary.waypoints.last?.coordinate else { return nil }
        let distance = CLLocation(latitude: first.latitude, longitude: first.longitude)
            .distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
        return distance > 25 ? first : nil
    }

    func closeLoop() {
        guard canCloseLoop, let start = Self.loopReturnPoint(in: itinerary) else { return }
        if mode == .fromHere { switchToPlanKeepingFromHere() }
        var preferences = displayedRidePreferences
        preferences.preferDifferentRoads = true
        ridePreferences = preferences
        apply(.append(coordinate: start), source: "returnRoute")
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
        waypointPlacement = nil
        waypointMove = nil
        showsWaypointPlacementConfirmation = false
        if navigation.phase != .idle {
            endNavigation()
        }
        invalidateInFlightRoutes()
        loopRunID = nil
        loopSummary = nil
        destination = nil
        destinationName = nil
        fromHereResponse = nil
        fromHereNeedsStartPin = false
        fromHereStartOverride = nil
        itinerary = RiderItinerary()
        built = nil
        fuelPlanningStatus = nil
        fuelPreviewStops = []
        toast = nil
        isRouting = false
        isAssemblingRoute = false
        errorMessage = nil
        routeIdentity = nil
        savedRouteOrigin = nil
        pendingPackBuild = nil
        pendingGroupTracking = nil
        activeGroupTracking = nil
        pendingMemberRouteReplacement = nil
        dismissGroupNavigationNotice()
        cancelGroupRouteUpdate(resetStopState: true)
        packAcquisition.resetSession()
        mapState.selectPlannerPin(nil)
        refreshMap()
    }

    /// Switch tabs without the keep/clear confirmation (Saved, or empty drafts).
    func selectMode(_ newMode: Mode) {
        waypointPlacement = nil
        waypointMove = nil
        showsWaypointPlacementConfirmation = false
        cancelFuelReplacement()
        if showingLoop {
            invalidateInFlightRoutes()
            showingLoop = false
            loopRunID = nil
            loopFar = nil
            loopSummary = nil
            errorMessage = nil
            fuelPlanningStatus = nil
            isAssemblingRoute = false
            refreshMap()
        }
        guard newMode != mode else { return }
        mode = newMode
    }

    /// From here → Plan: keep GPS→B (or geometry) as stage 1.
    func switchToPlanKeepingFromHere() {
        pendingGroupTracking = nil
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
        pendingGroupTracking = nil
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
        pendingGroupTracking = nil
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
        pendingGroupTracking = nil
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
        pendingGroupTracking = nil
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
        if showingLoop, !hasRoute, let far = loopFar {
            markers.append(
                MapState.Marker(
                    id: "loop-far",
                    latitude: far.latitude,
                    longitude: far.longitude,
                    label: "Far",
                    kind: .destination
                )
            )
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
        if let draft = waypointPlacement {
            markers.append(MapState.Marker(id: "waypoint-draft", latitude: draft.coordinate.latitude,
                longitude: draft.coordinate.longitude, label: "+", kind: .stage))
        }
        markers.append(contentsOf: fuelTargetMarkers)
        mapState.setPlannerMarkers(markers)
        primeNavigationTilePlanIfReady()
    }

    /// Move the destination pin to the snapped road without rebuilding.
    /// `apply(.move)` would start another search; this only updates the visible pin.
    private func syncSnappedDestinationPin(from result: BuiltItinerary) {
        guard errorMessage == nil,
              let lastLeg = result.legs.last,
              let snapped = lastLeg.response.coordinates.last
        else { return }
        let snappedCoord = snapped
        if let idx = itinerary.waypoints.indices.last {
            let current = itinerary.waypoints[idx].coordinate
            let moved = CLLocation(
                latitude: current.latitude,
                longitude: current.longitude
            ).distance(
                from: CLLocation(latitude: snappedCoord.latitude, longitude: snappedCoord.longitude)
            )
            if moved > 2 {
                itinerary.relocateWaypoint(at: idx, to: snappedCoord)
            }
        }
        destination = snappedCoord
        RoutingDebugLog.shared.event(
            "PIN snapped destination "
                + String(format: "%.5f,%.5f", snappedCoord.latitude, snappedCoord.longitude)
        )
    }

    private func canonicalMarkers(riderPinsLocked: Bool) -> [MapState.Marker] {
        var markers = itinerary.waypoints.enumerated().map { index, waypoint in
            MapState.Marker(
                id: "wp:\(waypoint.id.uuidString)",
                latitude: waypointMove?.id == waypoint.id ? waypointMove!.coordinate.latitude : waypoint.coordinate.latitude,
                longitude: waypointMove?.id == waypoint.id ? waypointMove!.coordinate.longitude : waypoint.coordinate.longitude,
                label: "\(index + 1)",
                kind: index == 0 ? .start : (index == itinerary.waypoints.count - 1 ? .destination : .stage),
                isLocked: showingLoop ? index != 1 : riderPinsLocked
            )
        }
        var fuelOrdinal = 0
        for (index, leg) in (built?.legs ?? []).enumerated() {
            if let stop = leg.endsAtFuelStop {
                fuelOrdinal += 1
                markers.append(
                    MapState.Marker(
                        id: "fuel:\(leg.riderLegID.uuidString):\(index)",
                        latitude: stop.coordinate.latitude,
                        longitude: stop.coordinate.longitude,
                        label: "F\(fuelOrdinal)",
                        kind: .fuel,
                        subtitle: stop.name,
                        isLocked: true
                    )
                )
            }
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
        existing.segments = activeResponses.flatMap { $0.segments ?? [] }
        existing.surfaceFamilyMode = activeSurfaceFamilyMode
        existing.ridePreferencesData = ridePreferences.flatMap { try? JSONEncoder().encode($0) }
        existing.routeSeedsData = try? JSONEncoder().encode(["routingSessionSeed": routingSessionSeed])
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
            pavedPercent: aggregatePavedPercent,
            segments: activeResponses.flatMap { $0.segments ?? [] },
            surfaceFamilyMode: activeSurfaceFamilyMode
        )
        route.ridePreferencesData = ridePreferences.flatMap { try? JSONEncoder().encode($0) }
        route.routeSeedsData = try? JSONEncoder().encode(["routingSessionSeed": routingSessionSeed])
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
        ridePreferences = saved.ridePreferencesData.flatMap { try? JSONDecoder().decode(RidePreferences.self, from: $0) }
        if let data = saved.routeSeedsData,
           let seeds = try? JSONDecoder().decode([String: UInt64].self, from: data),
           let seed = seeds["routingSessionSeed"], seed > 0 {
            routingSessionSeed = seed
        }
        mode = .saved
        applyStoredRouteGeometry(
            name: saved.name,
            coordinates: saved.coordinates,
            distanceMeters: saved.distanceMeters,
            dirtPercent: saved.dirtPercent,
            pavedPercent: saved.pavedPercent,
            identity: "saved:\(saved.id.uuidString)",
            imported: false,
            networkSegments: saved.segments,
            surfaceFamilyMode: saved.surfaceFamilyMode
        )
        // Set after applying geometry — that path clears the origin for imports.
        savedRouteOrigin = SavedRouteOrigin(id: saved.id, name: saved.name)
    }

#if DEBUG
    /// Stable active-build state used by UI tests to verify that route
    /// progress remains pinned under the logo instead of behaving like a
    /// transient toast over the planning sheet.
    func installRouteProgressFixtureForTesting(_ message: String) {
        isRouting = true
        fuelPlanningStatus = message
        toast = message
    }

    /// Stable, non-persistent route used only by visual/UI tests. It keeps a
    /// real ferry edge between two ordinary road runs so the shipping map and
    /// route-card presentation can be reviewed without making a network route.
    func installFerryPresentationFixtureForTesting() {
        let west = [
            RouteCoordinate(longitude: -69.99, latitude: 47.86),
            RouteCoordinate(longitude: -69.872, latitude: 47.844)
        ]
        let ferry = [
            west[1],
            RouteCoordinate(longitude: -69.553, latitude: 47.847)
        ]
        let east = [
            ferry[1],
            RouteCoordinate(longitude: -69.43, latitude: 47.87)
        ]
        let segments = [
            RouteSegment(
                surfaceClass: "gravel",
                trackClass: "secondary",
                accessClass: "motorized_permissive",
                distanceMeters: GeoMath.lineMeters(west),
                geometry: west,
                coords: nil,
                edgeId: "ui-test-west",
                surfaceLeaf: "gravel"
            ),
            RouteSegment(
                surfaceClass: "unknown",
                trackClass: "ferry",
                accessClass: "motorized_permissive",
                distanceMeters: GeoMath.lineMeters(ferry),
                geometry: ferry,
                coords: nil,
                edgeId: "ui-test-ferry",
                structureType: "ferry",
                crossingLabel: "Ferry crossing"
            ),
            RouteSegment(
                surfaceClass: "paved",
                trackClass: "secondary",
                accessClass: "motorized_permissive",
                distanceMeters: GeoMath.lineMeters(east),
                geometry: east,
                coords: nil,
                edgeId: "ui-test-east",
                surfaceLeaf: "asphalt"
            )
        ]
        let coordinates = west + Array(ferry.dropFirst()) + Array(east.dropFirst())
        applyStoredRouteGeometry(
            name: "Rivière-du-Loup ferry",
            coordinates: coordinates,
            distanceMeters: segments.compactMap(\.distanceMeters).reduce(0, +),
            dirtPercent: 50,
            pavedPercent: 50,
            identity: "ui-test:ferry-presentation",
            imported: false,
            networkSegments: segments,
            surfaceFamilyMode: "leaf-v3"
        )
    }
#endif

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
        pendingGroupTracking = nil
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
        segmentPolylines: [[RouteCoordinate]]? = nil,
        networkSegments: [RouteSegment]? = nil,
        surfaceFamilyMode: String? = nil
    ) {
        pendingGroupTracking = nil
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
            segmentPolylines: segmentPolylines,
            networkSegments: networkSegments,
            surfaceFamilyMode: surfaceFamilyMode
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
        unknownSurfacePercent: Int = 0,
        surfaceFamilyMode: String? = nil,
        maneuvers: [RouteManeuver]? = nil,
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
                unknownAccessPercent: unknownAccessPercent,
                unknownSurfacePercent: unknownSurfacePercent,
                surfaceFamilyMode: surfaceFamilyMode
            ),
            maneuvers: maneuvers,
            warnings: warnings,
            dirtPercentValue: nil,
            pavedPercentValue: nil
        )
    }

    /// Show only this generated stage and frame its start + end points. The
    /// endpoint view is intentionally tighter than the full-geometry view.
    func focusStage(at index: Int) {
        guard stages.indices.contains(index) else { return }
        let stage = stages[index]
        if let response = stage.response {
            mapState.setRoute(MapState.displaySegments(
                from: [response],
                riderLegIDs: [stage.riderLegID]
            ))
        }
        mapState.setPlannerMarkers(focusMarkers(forStageAt: index))
        var points: [RouteCoordinate] = []
        if let start = stage.start { points.append(start) }
        if let end = stage.end { points.append(end) }
        guard !points.isEmpty else { return }
        mapState.fit(points)
        RoutingDebugLog.shared.event(
            "map focus stage=\(index + 1) scope=endpoints title=\(stageEndpointTitle(at: index))"
        )
    }

    /// Show only this generated stage and fit every bend of its route.
    func focusEntireStage(at index: Int) {
        guard stages.indices.contains(index),
              let response = stages[index].response,
              response.coordinates.count >= 2
        else { return }
        let stage = stages[index]
        mapState.setRoute(MapState.displaySegments(
            from: [response],
            riderLegIDs: [stage.riderLegID]
        ))
        mapState.setPlannerMarkers(focusMarkers(forStageAt: index))
        mapState.fit(response.coordinates)
        RoutingDebugLog.shared.event(
            "map focus stage=\(index + 1) scope=geometry points=\(response.coordinates.count) "
                + "title=\(stageEndpointTitle(at: index))"
        )
    }

    private func focusMarkers(forStageAt index: Int) -> [MapState.Marker] {
        guard stages.indices.contains(index) else { return [] }
        let stage = stages[index]
        let labels = stageEndpointTitle(at: index)
            .components(separatedBy: " → ")

        func compactLabel(_ title: String, fallback: String) -> String {
            if title.hasPrefix("Point ") {
                return String(title.dropFirst("Point ".count))
            }
            return title.isEmpty ? fallback : title
        }

        var markers: [MapState.Marker] = []
        if let start = stage.start {
            let title = labels.first ?? ""
            markers.append(MapState.Marker(
                id: "focus-stage-\(index)-start",
                latitude: start.latitude,
                longitude: start.longitude,
                label: compactLabel(title, fallback: "A"),
                kind: title.hasPrefix("F") ? .fuel : .start,
                isLocked: true
            ))
        }
        if let end = stage.end {
            let title = labels.count > 1 ? labels[1] : ""
            markers.append(MapState.Marker(
                id: "focus-stage-\(index)-end",
                latitude: end.latitude,
                longitude: end.longitude,
                label: compactLabel(title, fallback: "B"),
                kind: title.hasPrefix("F") ? .fuel : .destination,
                isLocked: true
            ))
        }
        return markers
    }

    // MARK: - Fuel assist

    /// Rebuild the current route after the rider changes automatic planning,
    /// tank range, or reserve (From here / Plan).
    func reapplyFuelAssist(rangeKm requestedRangeKm: Double? = nil) {
        let rangeKm = requestedRangeKm ?? FuelRangePrefs.kilometers
        guard rangeKm > 0 else { return }
        guard mode == .fromHere || mode == .plan else { return }
        guard itinerary.legs.count > 0 else { return }
        FuelRangePrefs.kilometers = rangeKm
        FuelRangePrefs.lastEnabledKilometers = rangeKm
        fuelPlanNotice = nil
        RoutingDebugLog.shared.event(
            "fuel range stored mode=\(mode) range=\(Int(rangeKm))km (routing does not consult fuel)"
        )
        toast = "Fuel range saved"
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
        refreshMap()
        mapState.fit(allCoordinates)
        toast = "Route overview"
        RoutingDebugLog.shared.event(
            "map focus scope=entire_route stages=\(stages.count) points=\(allCoordinates.count)"
        )
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
        let xml = GPXExporter.document(
            for: route,
            fuelWarnings: fuelGaps.map {
                GPXExporter.FuelWarning(
                    from: $0.fromCoordinate,
                    to: $0.toCoordinate,
                    description: $0.message
                )
            },
            fuelUnknownMessages: fuelUnknownMessages.map { "FUEL STATUS UNKNOWN · \($0)" }
        )
        let url = FileManager.default.temporaryDirectory.appending(path: "dirt-route.gpx")
        do {
            try xml.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Navigation

    private var navigationViewportSize: CGSize {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        if let size = scene?.screen.bounds.size, size.width > 0, size.height > 0 {
            return size
        }
        return CGSize(width: 390, height: 844)
    }

    /// Visible stage geometry is already split at generated fuel stops. Saved
    /// single-line routes fall back to their one stored response.
    private var navigationTileStageCoordinates: [[RouteCoordinate]] {
        switch mode {
        case .saved:
            return activeResponses.map(\.coordinates).filter { $0.count >= 2 }
        case .fromHere, .plan:
            let routedStages = stages.compactMap { stage -> [RouteCoordinate]? in
                guard let coordinates = stage.response?.coordinates, coordinates.count >= 2 else {
                    return nil
                }
                return coordinates
            }
            return routedStages.isEmpty
                ? activeResponses.map(\.coordinates).filter { $0.count >= 2 }
                : routedStages
        }
    }

    /// Use otherwise-idle route review time to eliminate corridor computation
    /// from the Start button. No network request occurs here.
    private func primeNavigationTilePlanIfReady() {
        guard navigation.phase == .idle,
              !isRouting,
              fuelPlanningStatus == nil,
              routeIdentity != nil,
              allCoordinates.count >= 2
        else { return }
        let blocking = NavigationTileScope.blockingCoordinates(
            stageCoordinates: navigationTileStageCoordinates,
            fallback: allCoordinates
        )
        offline.primeNavigationPlan(coordinates: blocking, viewportSize: navigationViewportSize)
    }

    private func prefetchNextNavigationTileStageIfNeeded() {
        guard navigation.phase == .active else { return }
        let currentIndex = max(0, (navigation.currentStageNumber ?? 1) - 1)
        prefetchNextNavigationTileStage(after: currentIndex)
    }

    private func prefetchNextNavigationTileStage(after currentStageIndex: Int) {
        guard let next = NavigationTileScope.lookaheadCoordinates(
            after: currentStageIndex,
            stageCoordinates: navigationTileStageCoordinates
        ), lastQueuedTileLookaheadStageIndex != next.index
        else { return }
        lastQueuedTileLookaheadStageIndex = next.index
        offline.prefetchInBackground(
            identity: "stage-\(next.index + 1)",
            coordinates: next.coordinates,
            viewportSize: navigationViewportSize
        )
    }

    /// Routing packs follow the rider's actual province/state. This is kept
    /// independent from one-stage-ahead basemap prefetch so entering a long
    /// itinerary never starts a whole-country pack download.
    private func prepareCurrentNavigationRoutingPackIfNeeded(
        at coordinate: CLLocationCoordinate2D
    ) {
        guard navigation.phase == .active else { return }
        graphPacks.prepareCurrentNavigationRegionIfNeeded(at: coordinate)
    }

    /// Start Navigation gates only the first rider/fuel stage corridor. Later
    /// stages are saved one at a time while riding, before the rider reaches them.
    func startNavigation() {
        guard hasRoute, navigation.beginPrefetch() else { return }
        cancelFuelReplacement()
        refreshMap()

        if let pendingGroupTracking,
           destination == pendingGroupTracking.routedCoordinate {
            activeGroupTracking = ActiveGroupTracking(
                groupID: pendingGroupTracking.groupID,
                userID: pendingGroupTracking.userID,
                displayName: pendingGroupTracking.displayName,
                routedCoordinate: pendingGroupTracking.routedCoordinate,
                latestTarget: pendingGroupTracking.latestTarget,
                deferredCoordinate: nil
            )
        } else {
            activeGroupTracking = nil
            self.pendingGroupTracking = nil
        }
        groupFollowerStoppedSince = nil
        groupFollowerIsStopped = false
        dismissGroupNavigationNotice()

        navigationStartTask?.cancel()
        offline.beginNavigationPrepPresentation()

        // Lock pin edit for the whole prep → ride window. Pan/zoom stay free.
        // Prevents accidental waypoint moves that invalidate the route and re-download.
        mapState.lockRouteEditingForPrep()

        let startedAt = Date()
        RoutingDebugLog.shared.event("navigation start presentation ready")
        navigationStartTask = Task { @MainActor [weak self] in
            // Let SwiftUI commit the full-screen prep state before copying a long
            // route or determining the map/routing-pack preparation inputs.
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.navigation.phase == .prefetching
            else { return }
            self.continueNavigationStart(startedAt: startedAt)
            self.navigationStartTask = nil
        }
    }

    private func continueNavigationStart(startedAt: Date) {
        let coords = allCoordinates
        guard coords.count > 1 else {
            offline.cancelPrep()
            navigation.cancelPrefetch()
            mapState.unlockRouteEditingAfterPrepCancel()
            return
        }
        let tileStages = navigationTileStageCoordinates
        let blockingTileCoordinates = NavigationTileScope.blockingCoordinates(
            stageCoordinates: tileStages,
            fallback: coords
        )
        guard let routingStart = NavigationRoutingPackScope.startingCoordinate(
            stageCoordinates: tileStages,
            fallback: coords
        ) else {
            offline.cancelPrep()
            navigation.cancelPrefetch()
            mapState.unlockRouteEditingAfterPrepCancel()
            return
        }

        let identity = routeIdentity ?? "route"
        let keepExisting = (lastNavigationIdentity == identity)
        lastNavigationIdentity = identity

        locationService.requestAlways()
        let windowSize = navigationViewportSize
        // Tile identity is geographic — profile changes must not wipe corridor cache.
        let tileIdentity = Self.geographicTileIdentity(
            routeIdentity: identity,
            destination: destination,
            stages: stages
        )
        lastQueuedTileLookaheadStageIndex = nil
        RoutingDebugLog.shared.event(
            "navigation prep handoff elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000)) "
                + "blockingStages=1 availableStages=\(tileStages.count) "
                + "points=\(blockingTileCoordinates.count) routingPoints=1 "
                + "allRoutePoints=\(coords.count)"
        )
        offline.prepareForNavigation(
            identity: tileIdentity,
            coordinates: blockingTileCoordinates,
            keepExisting: keepExisting,
            viewportSize: windowSize
        )
        // Start locks only the rider's current region. Subsequent regions are
        // acquired on entry from location updates; the full itinerary is never
        // scanned or downloaded here.
        graphPacks.protectInstalledRevisions = true
        graphPacks.prepareForNavigation(
            startingAt: CLLocationCoordinate2D(
                latitude: routingStart.latitude,
                longitude: routingStart.longitude
            ),
            keepExisting: keepExisting
        )
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

    /// Called when offline prep is ready (or rider confirms after delight).
    func beginRideAfterOfflineReady() {
        guard hasRoute,
              navigation.phase == .prefetching,
              offline.markPrepConsumed()
        else { return }
        let coords = allCoordinates
        guard coords.count > 1 else {
            navigation.cancelPrefetch()
            graphPacks.protectInstalledRevisions = false
            mapState.unlockRouteEditingAfterPrepCancel()
            return
        }

        // Drop the gate immediately — proxy/style work used to run first and left
        // this card frozen on "BEGIN RIDE" for several seconds.

        Task { @MainActor in
            await Task.yield()
            do {
                try await offline.engageOfflineBasemap()
            } catch {
                toast = "Offline map proxy failed — riding with live tiles only."
            }

            locationService.requestAlways()
            locationService.setBackgroundUpdates(true, for: .navigation)
            locationService.startUpdates()

            let maneuvers = allManeuvers
            let displaySegments = MapState.displaySegments(from: activeResponses)
            navigation.activate(
                coordinates: coords,
                maneuvers: maneuvers,
                segments: displaySegments,
                stageEndMeters: stageEndAlongMeters(),
                stages: navigationStages(),
                networkSegments: networkSegments(from: activeResponses)
            )
            prefetchNextNavigationTileStage(after: 0)
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
        navigationStartTask?.cancel()
        navigationStartTask = nil
        offline.cancelPrep()
        graphPacks.cancel()
        // Start Nav pins installed revisions; cancelling prep must release that
        // pin or Layers Update/Delete keep throwing with no visible progress.
        graphPacks.protectInstalledRevisions = false
        graphPacks.cancelQuietDownloads()
        navigation.cancelPrefetch()
        activeGroupTracking = nil
        groupFollowerStoppedSince = nil
        groupFollowerIsStopped = false
        if navigation.phase == .idle {
            mapState.unlockRouteEditingAfterPrepCancel()
        }
    }

    /// Retry is an explicit transition out of the current failed prep. Regular
    /// Start taps remain idle-only so a double tap cannot launch overlapping
    /// tile/pack work, while the retry buttons can intentionally create a fresh
    /// prep session.
    func retryOfflineMapPrep() {
        guard hasRoute, navigation.phase == .prefetching else { return }
        navigationStartTask?.cancel()
        navigationStartTask = nil
        offline.cancelPrep()
        graphPacks.cancel()
        navigation.cancelPrefetch()
        startNavigation()
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

    /// Stable rider-facing stage names travel with the route into navigation.
    /// Fuel points retain the station name; rider points retain their itinerary ordinal.
    private func navigationStages(fromStage startIndex: Int = 0) -> [NavigationStage] {
        var result: [NavigationStage] = []
        var cursor = 0.0
        for (index, stage) in stages.enumerated() where index >= startIndex {
            guard let response = stage.response else { continue }
            cursor += response.distanceMeters ?? GeoMath.lineMeters(response.coordinates)

            let riderLegIndex = itinerary.legs.firstIndex(where: { $0.id == stage.riderLegID })
            let pointOrdinal = (riderLegIndex ?? index) + 2
            let waypointID = riderLegIndex.flatMap { legIndex in
                itinerary.waypoints.indices.contains(legIndex + 1)
                    ? itinerary.waypoints[legIndex + 1].id
                    : nil
            }
            let waypointFuel = waypointID.flatMap { built?.waypointFuelStops[$0] }

            let title: String
            let detail: String?
            let kind: NavigationStage.Kind
            if stage.endsAtFuelStop {
                title = "F\(fuelOrdinal(endingAt: index))"
                detail = stage.fuelStopName
                kind = .fuelStop
            } else if let waypointFuel {
                title = "Point \(pointOrdinal)"
                detail = waypointFuel.name ?? "Fuel stop"
                kind = .fuelStop
            } else {
                title = "Point \(pointOrdinal)"
                detail = nil
                kind = index == stages.indices.last ? .destination : .waypoint
            }
            result.append(
                NavigationStage(
                    id: stage.id,
                    title: title,
                    detail: detail,
                    kind: kind,
                    endMeters: cursor
                )
            )
        }

        if result.isEmpty {
            let meters = GeoMath.lineMeters(allCoordinates)
            if meters > 0 {
                result.append(
                    NavigationStage(
                        id: routeIdentity ?? "destination",
                        title: destinationName ?? "Destination",
                        detail: nil,
                        kind: .destination,
                        endMeters: meters
                    )
                )
            }
        }
        return result
    }

    func skipPrefetch() {
        cancelOfflineMapPrep()
    }

    func endNavigation() {
        cancelNavigationReroute()
        cancelGroupRouteUpdate(resetStopState: true)
        if let activeGroupTracking {
            pendingGroupTracking = PendingGroupTracking(
                groupID: activeGroupTracking.groupID,
                userID: activeGroupTracking.userID,
                displayName: activeGroupTracking.displayName,
                routedCoordinate: activeGroupTracking.routedCoordinate,
                latestTarget: activeGroupTracking.latestTarget
            )
        }
        activeGroupTracking = nil
        dismissGroupNavigationNotice()
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
        lastQueuedTileLookaheadStageIndex = nil
        mapState.endNavigationCamera()
        locationService.setBackgroundUpdates(false, for: .navigation)
        offline.disengageOfflineBasemap()
        graphPacks.protectInstalledRevisions = false
        graphPacks.cancelQuietDownloads()
        onNavigationEnded?(candidate)
    }

    // MARK: - Incident recovery support

    /// True when Start Nav locked a graph pack for on-device detours.
    var hasOnDeviceRoutingPack: Bool { graphPacks.canRouteOnDevice }

    /// Mid-ride / report recovery over installed routing packs.
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
        let request = RouteRequest(
            profile: useProfile,
            locations: [
                RouteLocation(latitude: from.latitude, longitude: from.longitude, label: "A"),
                RouteLocation(latitude: to.latitude, longitude: to.longitude, label: "B")
            ],
            allowUnknown: useAllow,
            avoidEdgeIds: avoidEdgeIds,
            sessionSeed: planningSessionSeed,
            cleanMetroMultiplier: nil,
            avoidMotorways: avoidMotorways,
            preferBackRoads: preferBackRoads
        )
        return try await routingSourcePolicy.select(for: request).route(request)
    }

    /// From here / Plan A→B.
    /// Routing uses installed packs in both online and offline conditions.
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
        announce: Bool,
        requestGeneration: Int
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
            guard !Task.isCancelled,
                  navigationRerouteGeneration == requestGeneration,
                  navigation.phase == .active
            else { return }
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
            guard !Task.isCancelled,
                  navigationRerouteGeneration == requestGeneration
            else { return }
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
            fuelUsedOnArrivalMeters: old.fuelUsedOnArrivalMeters,
            routeProfile: old.routeProfile
        )
        var statuses = current.riderLegStatus
        statuses[old.riderLegID] = .built
        built = BuiltItinerary(
            generation: current.generation,
            legs: legs,
            riderLegStatus: statuses,
            riderRoutes: current.riderRoutes,
            waypointFuelStops: current.waypointFuelStops
        )

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
            offset += response.distanceMeters ?? GeoMath.lineMeters(response.coordinates)
        }

        let display = MapState.displaySegments(from: remainingResponses)
        navigation.replaceRoute(
            coordinates: coords,
            maneuvers: maneuvers,
            segments: display,
            stageEndMeters: stageEndAlongMeters(fromStage: index),
            stages: navigationStages(fromStage: index),
            networkSegments: networkSegments(from: Array(remainingResponses))
        )
    }

    /// Flatten route segments that carry pack `edgeId`s (for ride contribution).
    private func networkSegments(from responses: [RouteResponse]) -> [RouteSegment] {
        responses.flatMap { $0.segments ?? [] }
    }

    // MARK: - Route to member

    func routeToMember(_ target: GroupMemberRouteTarget) {
        if navigation.phase != .idle {
            let currentUserID = activeGroupTracking?.userID ?? pendingGroupTracking?.userID
            if currentUserID == target.userID {
                toast = "Already routing to \(target.displayName)."
                RoutingDebugLog.shared.event(
                    "group tracking already routing user=\(target.userID)"
                )
                return
            }
            pendingMemberRouteReplacement = target
            RoutingDebugLog.shared.event(
                "group tracking replace offered from=\(currentUserID ?? "none") to=\(target.userID)"
            )
            return
        }
        armRouteToMember(target)
    }

    func confirmReplaceMemberRoute() {
        guard let target = pendingMemberRouteReplacement else { return }
        pendingMemberRouteReplacement = nil
        RoutingDebugLog.shared.event(
            "group tracking replace confirmed user=\(target.userID)"
        )
        clearRoute()
        armRouteToMember(target)
    }

    func cancelReplaceMemberRoute() {
        pendingMemberRouteReplacement = nil
    }

    private func armRouteToMember(_ target: GroupMemberRouteTarget) {
        guard StopTriggeredTrackingPolicy.targetIsFresh(target) else {
            toast = "That rider's location is no longer current."
            RoutingDebugLog.shared.event(
                "group tracking offline rejected user=\(target.userID)"
            )
            return
        }
        let point = target.coordinate
        pendingGroupTracking = PendingGroupTracking(
            groupID: target.groupID,
            userID: target.userID,
            displayName: target.displayName,
            routedCoordinate: point,
            latestTarget: target
        )
        mode = .fromHere
        itinerary = RiderItinerary()
        built = nil
        fromHereResponse = nil
        destination = point
        destinationName = target.displayName
        presentRouteCard = true
        isAssemblingRoute = true
        toast = Self.calculatingRouteToast
        mapState.fromHereLongPressRelocatesDestination = true
        RoutingDebugLog.shared.event(
            "group tracking route armed group=\(target.groupID) user=\(target.userID)"
        )
        refreshMap()
        Task { await routeFromHere() }
    }

    func receiveGroupMemberUpdate(_ target: GroupMemberRouteTarget) {
        if var pending = pendingGroupTracking,
           pending.groupID == target.groupID,
           pending.userID == target.userID {
            pending.latestTarget = target.withDisplayName(pending.displayName)
            pendingGroupTracking = pending
        }
        if var active = activeGroupTracking,
           active.groupID == target.groupID,
           active.userID == target.userID {
            active.latestTarget = target.withDisplayName(active.displayName)
            if active.deferredCoordinate != target.coordinate {
                active.deferredCoordinate = nil
            }
            activeGroupTracking = active
        }
    }

    func receiveGroupMemberSharingEnded(userID: String, displayName: String) {
        if pendingGroupTracking?.userID == userID {
            pendingGroupTracking = nil
        }
        guard var active = activeGroupTracking, active.userID == userID else { return }
        let lastKnown = active.latestTarget
        active.latestTarget = GroupMemberRouteTarget(
            groupID: lastKnown.groupID,
            userID: lastKnown.userID,
            displayName: lastKnown.displayName,
            coordinate: lastKnown.coordinate,
            lastSeenAt: lastKnown.lastSeenAt,
            accuracyMeters: lastKnown.accuracyMeters,
            isLive: false
        )
        activeGroupTracking = active
        cancelGroupRouteUpdate(resetStopState: true)
        RoutingDebugLog.shared.event("group tracking sharing ended user=\(userID)")
        groupNavigationNotice = GroupNavigationNotice(
            kind: .lastKnown,
            title: "\(displayName) stopped sharing",
            message: "Continuing to the last known location."
        )
    }

    func dismissGroupNavigationNotice() {
        groupNavigationNotice = nil
    }

    private func handleGroupTrackingLocation(_ location: CLLocation) {
        guard navigation.phase == .active, activeGroupTracking != nil else {
            groupFollowerStoppedSince = nil
            groupFollowerIsStopped = false
            return
        }
        switch StopTriggeredTrackingPolicy.motion(for: location) {
        case .moving, .uncertain:
            if groupRouteUpdateTask != nil {
                RoutingDebugLog.shared.event("group tracking reroute discarded follower=moving")
            }
            cancelGroupRouteUpdate(resetStopState: true)
        case .stopped:
            groupFollowerIsStopped = true
            let now = Date.now
            if groupFollowerStoppedSince == nil {
                groupFollowerStoppedSince = now
                return
            }
            guard StopTriggeredTrackingPolicy.hasBeenStoppedLongEnough(
                since: groupFollowerStoppedSince,
                now: now
            ) else { return }
            beginStoppedGroupRouteUpdate(from: location)
        }
    }

    private func beginStoppedGroupRouteUpdate(from location: CLLocation) {
        guard groupRouteUpdateTask == nil,
              groupFollowerIsStopped,
              !navigation.offRoute,
              var tracking = activeGroupTracking,
              StopTriggeredTrackingPolicy.targetIsFresh(tracking.latestTarget),
              StopTriggeredTrackingPolicy.targetMovedMeaningfully(
                from: tracking.routedCoordinate,
                to: tracking.latestTarget.coordinate
              ),
              tracking.deferredCoordinate != tracking.latestTarget.coordinate
        else { return }

        let target = tracking.latestTarget
        if stages.contains(where: \.endsAtFuelStop) {
            tracking.deferredCoordinate = target.coordinate
            activeGroupTracking = tracking
            groupNavigationNotice = GroupNavigationNotice(
                kind: .needsReview,
                title: "\(tracking.displayName)'s location changed",
                message: "Open Route to update the destination without removing planned fuel stops."
            )
            RoutingDebugLog.shared.event("group tracking reroute deferred reason=fuel-stops")
            return
        }

        let rider = RouteCoordinate(
            longitude: location.coordinate.longitude,
            latitude: location.coordinate.latitude
        )
        groupRouteUpdateGeneration += 1
        let requestGeneration = groupRouteUpdateGeneration
        let profile = self.profile
        let allowUnknown = self.allowUnknown
        RoutingDebugLog.shared.event(
            "group tracking reroute begin group=\(target.groupID) user=\(target.userID)"
        )
        groupRouteUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.groupRouteUpdateGeneration == requestGeneration {
                    self.groupRouteUpdateTask = nil
                }
            }
            do {
                let response = try await self.routeWhileNavigating(
                    from: rider,
                    to: target.coordinate,
                    profile: profile,
                    allowUnknown: allowUnknown
                )
                guard !Task.isCancelled,
                      self.groupRouteUpdateGeneration == requestGeneration,
                      self.groupFollowerIsStopped,
                      self.navigation.phase == .active,
                      !self.navigation.offRoute,
                      var current = self.activeGroupTracking,
                      current.groupID == target.groupID,
                      current.userID == target.userID,
                      current.latestTarget.coordinate == target.coordinate,
                      StopTriggeredTrackingPolicy.targetIsFresh(current.latestTarget)
                else { return }

                current.routedCoordinate = target.coordinate
                current.deferredCoordinate = nil
                self.activeGroupTracking = current
                self.destination = target.coordinate
                self.destinationName = current.displayName
                self.seedCanonicalBuild(
                    coordinates: [rider, target.coordinate],
                    profile: profile,
                    allowUnknown: allowUnknown,
                    responses: [response]
                )
                let display = MapState.displaySegments(from: [response])
                let meters = response.distanceMeters ?? GeoMath.lineMeters(response.coordinates)
                self.navigation.replaceRoute(
                    coordinates: response.coordinates,
                    maneuvers: response.maneuvers ?? [],
                    segments: display,
                    stageEndMeters: [meters],
                    stages: [
                        NavigationStage(
                            id: target.id,
                            title: current.displayName,
                            detail: "Group member",
                            kind: .destination,
                            endMeters: meters
                        )
                    ],
                    networkSegments: self.networkSegments(from: [response])
                )
                self.refreshMap()
                self.groupFollowerStoppedSince = .now
                self.groupNavigationNotice = GroupNavigationNotice(
                    kind: .updated,
                    title: "\(current.displayName)'s location changed",
                    message: "Your route has been updated."
                )
                RoutingDebugLog.shared.event(
                    "group tracking reroute applied group=\(target.groupID) user=\(target.userID)"
                )
            } catch {
                guard !Task.isCancelled,
                      self.groupRouteUpdateGeneration == requestGeneration else { return }
                self.groupNavigationNotice = GroupNavigationNotice(
                    kind: .lastKnown,
                    title: "Couldn't update the group route",
                    message: "Continuing to \(target.displayName)'s last routed location."
                )
                RoutingDebugLog.shared.event(
                    "group tracking reroute failed group=\(target.groupID) user=\(target.userID)"
                )
            }
        }
    }

    private func cancelGroupRouteUpdate(resetStopState: Bool) {
        groupRouteUpdateTask?.cancel()
        groupRouteUpdateTask = nil
        groupRouteUpdateGeneration += 1
        if resetStopState {
            groupFollowerStoppedSince = nil
            groupFollowerIsStopped = false
        }
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
                guard case .built = built.riderLegStatus[leg.id] else { return false }
                let routed = built.legs.filter { $0.riderLegID == leg.id }
                return !routed.isEmpty && routed.allSatisfy {
                    $0.response.status == "complete" && $0.response.coordinates.count > 1
                }
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

    private static func userFacingFuelFailureMessage(_ message: String) -> String {
        let normalized = message.lowercased()
        if normalized.contains("fuel planning")
            || normalized.contains("fuel continuity")
            || normalized.contains("fuel coverage")
            || normalized.contains("fuel chain") {
            return "Route built. Fuel safety could not be verified for one or more legs."
        }
        return message
    }
}
