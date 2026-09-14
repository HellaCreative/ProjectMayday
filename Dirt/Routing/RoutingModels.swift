import CoreLocation
import Foundation

nonisolated enum RouteProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case cleanest
    case balanced
    case dirt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cleanest: "Clean"
        case .balanced: "Balanced"
        case .dirt: "Dirt"
        }
    }

    /// One-line guidance — Clean is nav-like; others optimize ride character.
    var guidance: String {
        switch self {
        case .cleanest: "Pavement · soft forward · skip metros/highways"
        case .balanced: "Dual-sport mix · aim about half dirt / half paved"
        case .dirt: "Adventure ride to B · meander for dirt, not the highway ETA"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RouteProfile(rawValue: raw) ?? .balanced
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated struct RouteCoordinate: Codable, Hashable, Sendable {
    let longitude: Double
    let latitude: Double

    var locationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(longitude: Double, latitude: Double) {
        self.longitude = longitude
        self.latitude = latitude
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        longitude = try container.decode(Double.self)
        latitude = try container.decode(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(longitude)
        try container.encode(latitude)
    }
}

struct RouteLocation: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double
    let label: String

    enum CodingKeys: String, CodingKey {
        case latitude = "lat"
        case longitude = "lon"
        case label
    }

    init(latitude: Double, longitude: Double, label: String) {
        self.latitude = latitude
        self.longitude = longitude
        self.label = label
    }

    init(coordinate: CLLocationCoordinate2D, label: String) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude, label: label)
    }
}

struct AccessPolicy: Codable, Sendable {
    let motorizedPermissive: Bool
    let motorizedUnknown: Bool
}

/// Optional per-request routing options. `avoidEdgeIds` is honored on-device
/// (route incident recovery). Requests without it omit `options`.
struct RouteRequestOptions: Codable, Sendable {
    var ridePreferences: RidePreferences?
    var avoidEdgeIds: [String]?
    var priorEdgeIds: [String]?
    var arrivalEdgeId: String?
    var backtrackFactor: Double?
    var sessionSeed: UInt64?
    var maxPathMeters: Double?
    var directExtraBudgetMeters: Double?
    /// Fuel-chain graph minima for each regional seam hop. The final route
    /// reserves later hops before spending distance on Dirt detours.
    var regionalHopMinimumMeters: [Double]?
    /// DEBUG ONLY. Clean pin tests: urban-core multiplier override (1…20).
    var cleanMetroMultiplier: Double?
    /// Internal inverse of the rider-facing "Allow major highways" control.
    var avoidMotorways: Bool?
    /// Legacy compatibility field; Clean no longer adds a primary-road penalty.
    var preferBackRoads: Bool?
    /// MapLibre zoom used for the V4 tap radius. Omitted on V3.
    var mapZoom: Double?
    /// Optional override of the zoom-aware snap radius, still capped.
    var matchLimitMeters: Double?
    /// V4 access intent. `customers` is set only for a deliberately selected
    /// service/fuel endpoint; ordinary rider pins omit these fields.
    var startEndpointKind: String?
    var endEndpointKind: String?

    init(
        avoidEdgeIds: [String] = [],
        priorEdgeIds: [String] = [],
        arrivalEdgeId: String? = nil,
        backtrackFactor: Double? = nil,
        sessionSeed: UInt64? = nil,
        maxPathMeters: Double? = nil,
        directExtraBudgetMeters: Double? = nil,
        regionalHopMinimumMeters: [Double] = [],
        cleanMetroMultiplier: Double? = nil,
        avoidMotorways: Bool = false,
        preferBackRoads: Bool = false,
        mapZoom: Double? = nil,
        matchLimitMeters: Double? = nil,
        startEndpointKind: String? = nil,
        endEndpointKind: String? = nil
    ) {
        self.ridePreferences = RidePreferenceContext.current
        self.avoidEdgeIds = avoidEdgeIds.isEmpty ? nil : avoidEdgeIds
        self.priorEdgeIds = priorEdgeIds.isEmpty ? nil : priorEdgeIds
        self.arrivalEdgeId = arrivalEdgeId
        self.backtrackFactor = backtrackFactor
        self.sessionSeed = sessionSeed
        self.maxPathMeters = maxPathMeters
        self.directExtraBudgetMeters = directExtraBudgetMeters
        let regionalMinima = regionalHopMinimumMeters.filter { $0.isFinite && $0 >= 0 }
        self.regionalHopMinimumMeters = regionalMinima.isEmpty ? nil : regionalMinima
        if let cleanMetroMultiplier, cleanMetroMultiplier.isFinite {
            self.cleanMetroMultiplier = min(20, max(1, cleanMetroMultiplier))
        } else {
            self.cleanMetroMultiplier = nil
        }
        self.avoidMotorways = avoidMotorways ? true : nil
        self.preferBackRoads = preferBackRoads ? true : nil
        self.mapZoom = mapZoom?.isFinite == true ? mapZoom : nil
        self.matchLimitMeters = matchLimitMeters?.isFinite == true ? matchLimitMeters : nil
        self.startEndpointKind = startEndpointKind == "customers" ? "customers" : nil
        self.endEndpointKind = endEndpointKind == "customers" ? "customers" : nil
    }
}

struct RouteRequest: Codable, Sendable {
    let profile: RouteProfile
    let locations: [RouteLocation]
    let vehicle: String
    let accessPolicy: AccessPolicy
    let options: RouteRequestOptions?

    init(
        profile: RouteProfile,
        locations: [RouteLocation],
        allowUnknown: Bool,
        avoidEdgeIds: [String] = [],
        priorEdgeIds: [String] = [],
        arrivalEdgeId: String? = nil,
        backtrackFactor: Double? = nil,
        sessionSeed: UInt64 = 0,
        maxPathMeters: Double? = nil,
        directExtraBudgetMeters: Double? = nil,
        regionalHopMinimumMeters: [Double] = [],
        cleanMetroMultiplier: Double? = nil,
        avoidMotorways: Bool = false,
        preferBackRoads: Bool = false,
        mapZoom: Double? = nil,
        matchLimitMeters: Double? = nil,
        startEndpointKind: String? = nil,
        endEndpointKind: String? = nil
    ) {
        self.profile = profile
        self.locations = locations
        vehicle = "dual-sport-motorcycle"
        accessPolicy = AccessPolicy(
            motorizedPermissive: true,
            motorizedUnknown: profile == .cleanest ? false : allowUnknown
        )
        let seed = sessionSeed == 0 ? RoutingSessionContext.seed : sessionSeed
        let metro = profile == .cleanest ? cleanMetroMultiplier : nil
        let scopedAvoid = profile == .cleanest && avoidMotorways
        let scopedPrefer = false
        let zoom = mapZoom?.isFinite == true ? mapZoom : nil
        let matchLimit = matchLimitMeters?.isFinite == true ? matchLimitMeters : nil
        if avoidEdgeIds.isEmpty, priorEdgeIds.isEmpty, arrivalEdgeId == nil,
           backtrackFactor == nil, seed == nil, maxPathMeters == nil,
           directExtraBudgetMeters == nil, regionalHopMinimumMeters.isEmpty, metro == nil,
           !scopedAvoid, !scopedPrefer, zoom == nil, matchLimit == nil,
           startEndpointKind == nil, endEndpointKind == nil, RidePreferenceContext.current == nil {
            options = nil
        } else {
            options = RouteRequestOptions(
                avoidEdgeIds: avoidEdgeIds,
                priorEdgeIds: priorEdgeIds,
                arrivalEdgeId: arrivalEdgeId,
                backtrackFactor: backtrackFactor,
                sessionSeed: seed,
                maxPathMeters: maxPathMeters,
                directExtraBudgetMeters: directExtraBudgetMeters,
                regionalHopMinimumMeters: regionalHopMinimumMeters,
                cleanMetroMultiplier: metro,
                avoidMotorways: scopedAvoid,
                preferBackRoads: scopedPrefer,
                mapZoom: zoom,
                matchLimitMeters: matchLimit,
                startEndpointKind: startEndpointKind,
                endEndpointKind: endEndpointKind
            )
        }
    }
}

/// One live request that discovers the ordered graph-reachable pump chain.
/// It does not generate a disposable point-1-to-point-2 route and then alter
/// it. The selected waypoints are subsequently routed as final ride legs.
struct FuelChainConstraint: Codable, Sendable {
    let usableRangeMeters: Double
    let firstLegMaxMeters: Double
    let requireFuelStopBeforeEnd: Bool
    let minimumFuelStops: Int
    let destinationFuelUsedLimitMeters: Double?
    let profileMeters: Double
    let riderLegId: String
    var probeFirstReachableStation: Bool? = nil
    var excludedStationIds: [String]? = nil
    var windowMaxStops: Int? = nil
    var allowPartialWindow: Bool? = nil
    var windowTimeBudgetMs: Int? = nil
    var requiredFirstStationId: String? = nil
    /// Candidate pumps retained from a prior profile calculation for the same
    /// rider corridor. The service may evaluate these first, but may not treat
    /// them as required or skip normal eligibility checks.
    var preferredStationIds: [String]? = nil
    /// Discover the next reachable anchor using graph distance only. The
    /// selected anchor is routed once, as the real rider leg, by the client.
    var forwardFeeler: Bool? = nil
    /// Live-service capability: build the selected route before fuel search,
    /// reuse that graph runtime, and return the route legs already calculated.
    var routeFirstPlan: Bool? = nil
    /// Require enough fuel on arrival to reach a packed pump by road from the
    /// final destination. A rider waypoint on a pump satisfies this directly.
    var ensureDestinationFuelEscape: Bool? = nil
}

struct FuelChainRequest: Codable, Sendable {
    let profile: RouteProfile
    let locations: [RouteLocation]
    let vehicle: String
    let accessPolicy: AccessPolicy
    var options: RouteRequestOptions?
    var fuel: FuelChainConstraint

    init(
        profile: RouteProfile,
        from start: RouteCoordinate,
        to end: RouteCoordinate,
        allowUnknown: Bool,
        usableRangeMeters: Double,
        firstLegMaxMeters: Double,
        requireFuelStopBeforeEnd: Bool,
        minimumFuelStops: Int,
        destinationFuelUsedLimitMeters: Double? = nil,
        profileMeters: Double,
        riderLegId: String,
        avoidEdgeIds: [String] = [],
        cleanMetroMultiplier: Double? = nil,
        avoidMotorways: Bool = false,
        priorEdgeIds: [String] = [],
        arrivalEdgeId: String? = nil,
        backtrackFactor: Double? = nil,
        probeFirstReachableStation: Bool = false,
        excludedStationIds: [String] = [],
        windowMaxStops: Int? = nil,
        allowPartialWindow: Bool = false,
        windowTimeBudgetMs: Int? = nil,
        requiredFirstStationId: String? = nil,
        preferredStationIds: [String] = [],
        forwardFeeler: Bool = false,
        routeFirstPlan: Bool = false,
        ensureDestinationFuelEscape: Bool = false,
        mapZoom: Double? = nil
    ) {
        self.profile = profile
        locations = [
            RouteLocation(latitude: start.latitude, longitude: start.longitude, label: "Point 1"),
            RouteLocation(latitude: end.latitude, longitude: end.longitude, label: "Point 2")
        ]
        vehicle = "dual-sport-motorcycle"
        accessPolicy = AccessPolicy(
            motorizedPermissive: true,
            motorizedUnknown: profile == .cleanest ? false : allowUnknown
        )
        let metro = profile == .cleanest ? cleanMetroMultiplier : nil
        let scopedAvoid = profile == .cleanest && avoidMotorways
        let zoom = mapZoom?.isFinite == true ? mapZoom : nil
        options = avoidEdgeIds.isEmpty && priorEdgeIds.isEmpty && arrivalEdgeId == nil
            && backtrackFactor == nil && metro == nil && !scopedAvoid && zoom == nil && RidePreferenceContext.current == nil
            ? nil
            : RouteRequestOptions(
                avoidEdgeIds: avoidEdgeIds,
                priorEdgeIds: priorEdgeIds,
                arrivalEdgeId: arrivalEdgeId,
                backtrackFactor: backtrackFactor,
                cleanMetroMultiplier: metro,
                avoidMotorways: scopedAvoid,
                mapZoom: zoom
            )
        fuel = FuelChainConstraint(
            usableRangeMeters: usableRangeMeters,
            firstLegMaxMeters: firstLegMaxMeters,
            requireFuelStopBeforeEnd: requireFuelStopBeforeEnd,
            minimumFuelStops: minimumFuelStops,
            destinationFuelUsedLimitMeters: destinationFuelUsedLimitMeters,
            profileMeters: profileMeters,
            riderLegId: riderLegId,
            probeFirstReachableStation: probeFirstReachableStation ? true : nil,
            excludedStationIds: excludedStationIds.isEmpty ? nil : excludedStationIds,
            windowMaxStops: windowMaxStops,
            allowPartialWindow: allowPartialWindow ? true : nil,
            windowTimeBudgetMs: windowTimeBudgetMs,
            requiredFirstStationId: requiredFirstStationId,
            preferredStationIds: preferredStationIds.isEmpty ? nil : preferredStationIds,
            forwardFeeler: forwardFeeler ? true : nil,
            routeFirstPlan: routeFirstPlan ? true : nil,
            ensureDestinationFuelEscape: ensureDestinationFuelEscape ? true : nil
        )
    }
}

struct FuelSnapPatch {
    static func applyingMapZoom(_ request: FuelChainRequest, zoom: Double?) -> FuelChainRequest {
        guard let zoom, zoom.isFinite else { return request }
        var req = request
        var opts = req.options ?? RouteRequestOptions()
        opts.mapZoom = zoom
        req.options = opts
        return req
    }
}

struct FuelWaypointReset: Codable, Sendable {
    let locationIndex: Int?
    let id: String?
    let name: String?
    let lat: Double?
    let lon: Double?
    let metersFromWaypoint: Double?
}

struct FuelChainStop: Codable, Sendable {
    let id: String
    let latitude: Double
    let longitude: Double
    let name: String?
    let brand: String?
    let address: String?
    let graphMeters: Double?
    var dirtPercent: Int? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, brand, address, graphMeters, dirtPercent
        case latitude = "lat"
        case longitude = "lon"
    }

    var coordinate: RouteCoordinate {
        RouteCoordinate(longitude: longitude, latitude: latitude)
    }

    var displayName: String {
        let raw = name ?? brand ?? "Fuel stop"
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Fuel stop" : raw
    }
}

struct FuelChainDiagnostics: Codable, Sendable {
    let strategy: String?
    var selectionPolicy: String? = nil
    var graphOnlySelection: Bool? = nil
    var stationAlternativesLimit: Int? = nil
    var stationAlternativesReturned: Int? = nil
    let states: Int?
    let dijkstraPops: Int?
    let matchedFuel: Int?
    var stationsConsidered: Int? = nil
    var stationsInRange: Int? = nil
    var stationsMatchLimited: Bool? = nil
    var stationCacheMatches: Int? = nil
    var stationFreshMatches: Int? = nil
    var targetPasses: [FuelTargetPassDiagnostic]? = nil
    let elapsedMs: Int?
    var candidateK: Int? = nil
    var stationsReachableWithinRange: Int? = nil
    var candidatesEvaluated: Int? = nil
    var gapReason: String? = nil
    var failureReason: String? = nil
    var watchStartMeters: Double? = nil
    var preferredStartMeters: Double? = nil
    var hardRangeMeters: Double? = nil
    var destinationEscapeMeters: Double? = nil
    var selectedReason: String? = nil
    var totalElapsedMs: Int? = nil
    var routeFirstMs: Int? = nil
    var routeFirstBudgetMs: Int? = nil
    var routeFirstSharedRuntime: Bool? = nil
    var profileRoutesSharedRuntime: Bool? = nil
    var routeFirstAttempted: Bool? = nil
    var routeFirstSkippedReason: String? = nil
    var directLowerBoundMeters: Int? = nil
    var firstLegMaxMeters: Int? = nil
    var planningDataLoadMs: Int? = nil
    var routeFirstBuildMs: Int? = nil
    var routeFirstSearchMs: Int? = nil
    var routeFirstSnapMs: Int? = nil
    var routeFirstPostprocessMs: Int? = nil
    var routeFirstPops: Int? = nil
    var routeFirstSearchOutcome: String? = nil
    var routeFirstFallbacks: [String]? = nil
    var routeFirstDeadlineRemainingAfterLoadMs: Int? = nil
    var routeFirstWindowRemainingAfterLoadMs: Int? = nil
    var routeFirstSearchBudgetGrantedMs: Int? = nil
    var routeFirstLoadBudgetReliefMs: Int? = nil
    var routeFirstBudgetStartsAfterRuntimeLoad: Bool? = nil
    var endpointResolutionMs: Int? = nil
    var endpointProbeCount: Int? = nil
    var endpointResolutionSources: String? = nil
    var graphFetchMs: Int? = nil
    var graphDecodeMs: Int? = nil
    var graphGridMs: Int? = nil
    var fuelFetchMs: Int? = nil
    var fuelCacheHit: Bool? = nil
    var targetPrepareMs: Int? = nil
    var targetCacheHit: Bool? = nil
    var destinationEscapeSearchMs: Int? = nil
    var destinationEscapePops: Int? = nil
    var profileRouteAttempts: Int? = nil
    var slowestProfileRoutes: [FuelRouteAttemptDiagnostic]? = nil
    var maxHopMs: Int? = nil
    var windowBudgetMs: Int? = nil
    var windowBudgetOverrunMs: Int? = nil
    var searchDeadlineOverrunMs: Int? = nil
    var timeBudgetExceeded: Bool? = nil
    var profileRouteFailureReason: String? = nil
    var profileRouteSearchOutcome: String? = nil
    var profileRouteSearchMs: Int? = nil
    var profileRoutePops: Int? = nil
    var deadlinePhase: String? = nil
    var cancelled: Bool? = nil
    var foundationRouteReused: Bool? = nil
    var foundationRouteMeters: Int? = nil
    var foundationRouteDirtPercent: Int? = nil
    var foundationMatchedStations: Int? = nil
    var foundationSelectedStationId: String? = nil
    var foundationChainMeters: Int? = nil
    var foundationChainDirtPercent: Int? = nil
    var profileRouteSavings: Int? = nil
    var foundationPriorityStations: Int? = nil
    var selectedUrbanEntry: Bool? = nil
    var ruralAlternativeAvailable: Bool? = nil
    var allowUnknown: Bool? = nil
    var tapRadiusMeters: Double? = nil
    var mapZoom: Double? = nil
    var snap: RouteSnapDiagnostics? = nil
}

struct FuelTargetPassDiagnostic: Codable, Sendable {
    let origin: String?
    let pool: Int?
    let considered: Int?
    let cacheMatches: Int?
    let freshMatches: Int?
    let returned: Int?
    let limited: Bool?
    let elapsedMs: Int?
}

struct FuelRouteAttemptDiagnostic: Codable, Sendable {
    let candidateId: String?
    let elapsedMs: Int?
    let status: String?
    let distanceMeters: Double?
    let maxMeters: Double?
    var deadlineRemainingAtStartMs: Int? = nil
    var deadlineRemainingAtEndMs: Int? = nil
    var searchMs: Int? = nil
    var snapMs: Int? = nil
    var postprocessMs: Int? = nil
    var pops: Int? = nil
    var fallbacks: [String]? = nil
}

struct FuelStationCandidate: Codable, Sendable {
    let id: String
    let meters: Double
    let dirtPct: Int
    var departureId: String? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
    var name: String? = nil
    var validForward: Bool? = nil
    var remainingGraphMeters: Double? = nil
    var commitBand: Int? = nil
    var canFinish: Bool? = nil
    var rank: Int? = nil
    var approachElapsedMs: Int? = nil
    var approachStatus: String? = nil
    var approachSearchOutcome: String? = nil
    var approachFailureReason: String? = nil
    var continuationElapsedMs: Int? = nil
    var continuationStatus: String? = nil
    var continuationStrategy: String? = nil
    var approachBudgetMs: Int? = nil
    var candidateDeadlineRemainingMs: Int? = nil
    var backtrackMeters: Double? = nil
    var rejectedReason: String? = nil
    var totalElapsedMs: Int? = nil
    var candidateSource: String? = nil
    var foundationAlongMeters: Double? = nil
    var foundationOffRouteMeters: Double? = nil
    var foundationPriorityCellDistance: Int? = nil
    var chainMeters: Double? = nil
    var chainDirtPct: Double? = nil
    var continuationBacktrackMeters: Double? = nil
    var urbanEntry: Bool? = nil
    var oneStopCapable: Bool? = nil
    /// Per-region graph lower bounds from the current visible departure to
    /// this candidate. Cross-region recovery uses these to budget the real
    /// profile route through the same authored seams as the selected pump.
    var regionalGraphMeters: [Double]? = nil
}

struct FuelChainResponse: Codable, Sendable {
    let status: String
    let error: String?
    let message: String?
    let regionIds: [String]?
    let stops: [FuelChainStop]?
    let graphMeters: [Double]?
    let diagnostics: FuelChainDiagnostics?
    /// Route responses already calculated while selecting the returned pump
    /// chain. There is one response per returned hop, plus the destination hop
    /// when windowComplete is true.
    var routes: [RouteResponse]? = nil
    /// A completed road foundation retained after an incomplete fuel proof.
    /// This is advisory geometry, never a fuel-qualified route.
    var foundationRoute: RouteResponse? = nil
    var stationCandidates: [FuelStationCandidate]? = nil
    var firstReachableStationMeters: Double? = nil
    var destinationEscapeMeters: Double? = nil
    /// False means this bounded response ends at its final pump and the client
    /// must request the next window toward the rider waypoint.
    var windowComplete: Bool? = nil
    var gapMeters: Double? = nil
    var overByMeters: Double? = nil
    var gapFrom: FuelChainStop? = nil
    var gapTo: FuelChainStop? = nil
    var serviceContract: String? = nil
    var serviceBuild: String? = nil
    var packIdentity: [RoutingPackIdentity]? = nil
    /// Live-derived numbered-waypoint refuels. Never persisted on the waypoint.
    var waypointResets: [FuelWaypointReset]? = nil

    var isComplete: Bool { status == "complete" }
    var isGap: Bool { status == "gap" }
    var isFuelUnknown: Bool { status == "unknown" }
    var isUsableFuelResult: Bool { isComplete || isGap || isFuelUnknown }
    var reachesDestination: Bool { windowComplete != false }
}

struct RouteSegment: Codable, Identifiable, Sendable {
    let id = UUID()
    let surfaceClass: String?
    let trackClass: String?
    let accessClass: String?
    let distanceMeters: Double?
    let geometry: [RouteCoordinate]?
    let coords: [RouteCoordinate]?
    /// Authoritative network edge ID (e.g. `ns-gov-…`) — used by incident
    /// reports so "Find a way around" can avoid this edge on-device.
    let edgeId: String?
    let structureType: String?
    let structureLeaf: String?
    let layer: Int?
    let crossingLabel: String?
    let waterCrossing: Bool?
    /// Graph-v3 normalized OSM `surface=*` leaf. Nil means genuinely untagged
    /// when the response advertises `surfaceFamilyMode=leaf-v3`.
    let surfaceLeaf: String?

    enum CodingKeys: String, CodingKey {
        case surfaceClass, trackClass, accessClass, distanceMeters, geometry, coords, edgeId
        case structureType, structureLeaf, layer, crossingLabel, waterCrossing, surfaceLeaf
    }

    init(
        surfaceClass: String?,
        trackClass: String?,
        accessClass: String? = nil,
        distanceMeters: Double?,
        geometry: [RouteCoordinate]?,
        coords: [RouteCoordinate]?,
        edgeId: String?,
        structureType: String? = nil,
        structureLeaf: String? = nil,
        layer: Int? = nil,
        crossingLabel: String? = nil,
        waterCrossing: Bool? = nil,
        surfaceLeaf: String? = nil
    ) {
        self.surfaceClass = surfaceClass
        self.trackClass = trackClass
        self.accessClass = accessClass
        self.distanceMeters = distanceMeters
        self.geometry = geometry
        self.coords = coords
        self.edgeId = edgeId
        self.structureType = structureType
        self.structureLeaf = structureLeaf
        self.layer = layer
        self.crossingLabel = crossingLabel
        self.waterCrossing = waterCrossing
        self.surfaceLeaf = surfaceLeaf
    }

    var coordinates: [RouteCoordinate] { geometry ?? coords ?? [] }

    /// Surface key for map paint — prefers surfaceClass, then trackClass.
    /// `unknown` on an OSM road class is remapped to paved by the on-device
    /// builder before it lands here.
    var paintSurfaceKey: String {
        let raw = (surfaceClass ?? trackClass ?? "connector").lowercased()
        let key = raw.isEmpty ? "connector" : raw
        if key == "unknown" {
            return OnDeviceProfileCosts.riderPaintSurface(
                surfaceName: key,
                roadClassName: (trackClass ?? "").lowercased()
            )
        }
        return key
    }

    /// Map paint key that preserves unknown motorized access independently of
    /// surface. Purple means access is unproven; it never means "paved".
    var selectedRoutePaintKey: String {
        OnDeviceProfileCosts.selectedRoutePaintKey(
            surfaceName: (surfaceClass ?? "unknown").lowercased(),
            roadClassName: (trackClass ?? "unknown").lowercased(),
            // Older saved/API segments predate accessClass; preserve their
            // surface paint rather than inventing an unknown-access warning.
            accessName: (accessClass ?? "motorized_permissive").lowercased()
        )
    }

    /// Detailed surface leaves are authoritative whenever Graph v3 says they
    /// are present. Coarse classes remain a rollback path for v2/legacy data.
    func presentationSurfaceFamily(usesSurfaceLeaves: Bool) -> SurfaceFamily {
        if usesSurfaceLeaves {
            return SurfaceFamilyStats.family(of: surfaceLeaf)
        }
        let coarse = paintSurfaceKey.lowercased()
        let leafFamily = SurfaceFamilyStats.family(of: coarse)
        if leafFamily != .unknown { return leafFamily }
        switch coarse {
        case "paved": return .paved
        case "gravel", "unpaved", "compacted", "fine_gravel": return .gravel
        case "dirt", "ground", "earth", "grass", "mud", "sand", "rock", "natural", "woodchips":
            return .loose
        default: return .unknown
        }
    }

    var isDirt: Bool {
        Self.isAdventureSurface(paintSurfaceKey)
    }

    /// Rider-facing surface name (Mapbox RoadSurface analogue from OSM classes).
    static func riderFacingSurfaceLabel(_ key: String) -> String {
        switch key.lowercased() {
        case "paved": "Paved"
        case "gravel", "unpaved": "Gravel / unpaved"
        case "dirt": "Dirt"
        case "track", "double_track": "Track"
        case "access", "resource": "Access / resource"
        case "unknown": "Unknown surface"
        case "connector": "Connector"
        default: key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func isAdventureSurface(_ key: String) -> Bool {
        OnDeviceProfileCosts.isAdventureSurface(key)
    }
}

struct RouteStats: Codable, Sendable {
    let dirtPercent: Int?
    let pavedPercent: Int?
    /// Share of route distance on `motorized_unknown` (Allow-gated purple).
    let unknownAccessPercent: Int?
    /// Share of route distance whose surface family is Unknown (Phase E1).
    let unknownSurfacePercent: Int?
    /// `leaf-v3` means a missing per-edge leaf is honest Unknown, not a legacy
    /// payload omission that should fall back to its coarse surface class.
    let surfaceFamilyMode: String?

    init(
        dirtPercent: Int? = nil,
        pavedPercent: Int? = nil,
        unknownAccessPercent: Int? = nil,
        unknownSurfacePercent: Int? = nil,
        surfaceFamilyMode: String? = nil
    ) {
        self.dirtPercent = dirtPercent
        self.pavedPercent = pavedPercent
        self.unknownAccessPercent = unknownAccessPercent
        self.unknownSurfacePercent = unknownSurfacePercent
        self.surfaceFamilyMode = surfaceFamilyMode
    }

    enum CodingKeys: String, CodingKey {
        case dirtPercent, pavedPercent, unknownAccessPercent, unknownSurfacePercent, surfaceFamilyMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dirtPercent = try c.decodeIfPresent(Int.self, forKey: .dirtPercent)
        pavedPercent = try c.decodeIfPresent(Int.self, forKey: .pavedPercent)
        unknownAccessPercent = try c.decodeIfPresent(Int.self, forKey: .unknownAccessPercent)
        unknownSurfacePercent = try c.decodeIfPresent(Int.self, forKey: .unknownSurfacePercent)
        surfaceFamilyMode = try c.decodeIfPresent(String.self, forKey: .surfaceFamilyMode)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(dirtPercent, forKey: .dirtPercent)
        try c.encodeIfPresent(pavedPercent, forKey: .pavedPercent)
        try c.encodeIfPresent(unknownAccessPercent, forKey: .unknownAccessPercent)
        try c.encodeIfPresent(unknownSurfacePercent, forKey: .unknownSurfacePercent)
        try c.encodeIfPresent(surfaceFamilyMode, forKey: .surfaceFamilyMode)
    }
}

struct RouteSearchAttempt: Codable, Sendable {
    let corridorMeters: Double?
    let outcome: String?
    let pops: Int?
    let searchMs: Int?
    var succeeded: Bool? = nil
}

struct RouteResponseSearchMeta: Codable, Sendable {
    let pass2Outcome: String?
    let pops: Int?
    let timedOut: Bool?
    let rideObjective: String?
    let corridorMeters: Double?
    let maxCrossTrackMeters: Double?
    let corridorWidened: Bool?
    let shortestMeters: Double?
    let extraUsedMeters: Double?
    let extraBudgetMeters: Double?
    let urbanCoreFallbackUsed: Bool?
    let cleanUnpavedFallbackUsed: Bool?
    let settlementFallbackUsed: Bool?
    var corridorCandidates: [RouteSearchAttempt]? = nil
}

/// Live `/api/route` diagnostics block (`debug.diagnostics`). Logging only.
struct RouteResponseDiagnostics: Codable, Sendable {
    var buildMs: Int? = nil
    var searchMs: Int? = nil
    var searchAttempts: [RouteSearchAttempt]? = nil
    var pops: Int? = nil
    var corridorMeters: Double? = nil
    var corridorWidened: Bool? = nil
    var corridorWidthsTried: [Double?]? = nil
    var maxCrossTrackMeters: Double? = nil
    var backtrackPct: Double? = nil
    var failureReason: String? = nil
    var searchOutcome: String? = nil
    var requestedProfile: String? = nil
    var effectiveProfile: String? = nil
    var profileFallbacks: [String]? = nil
    var endpointResolutionMs: Int? = nil
    var endpointProbeCount: Int? = nil
    var endpointResolutionSources: String? = nil
    var snapMs: Int? = nil
    var postprocessMs: Int? = nil
    var deadlineRemainingMs: Int? = nil
    var corridorClipDiagnosticSkipped: Bool? = nil
    /// DEBUG ONLY. Echo of options.cleanMetroMultiplier when Clean override was applied.
    var cleanMetroMultiplier: Double? = nil
    var allowUnknown: Bool? = nil
    var tapRadiusMeters: Double? = nil
    var mapZoom: Double? = nil
    var snap: RouteSnapDiagnostics? = nil
}

nonisolated struct RouteSnapEndpoint: Codable, Sendable {
    var raw: SnapCoordinate?
    var snapped: SnapCoordinate?
    var distanceM: Int?
    var candidateCount: Int?
    var osmWayId: String?
    var accessClass: String?
    var component: Int?
    var rejectionReasons: [String]? = nil
}

nonisolated struct SnapCoordinate: Codable, Sendable {
    var longitude: Double
    var latitude: Double

    var routeCoordinate: RouteCoordinate {
        RouteCoordinate(longitude: longitude, latitude: latitude)
    }

    enum CodingKeys: String, CodingKey {
        case lon, lng, lat, longitude, latitude
    }

    init(longitude: Double, latitude: Double) {
        self.longitude = longitude
        self.latitude = latitude
    }

    init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            longitude = try unkeyed.decode(Double.self)
            latitude = try unkeyed.decode(Double.self)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latitude = try container.decodeIfPresent(Double.self, forKey: .lat)
            ?? container.decode(Double.self, forKey: .latitude)
        longitude = try container.decodeIfPresent(Double.self, forKey: .lon)
            ?? container.decodeIfPresent(Double.self, forKey: .lng)
            ?? container.decode(Double.self, forKey: .longitude)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(longitude, forKey: .lon)
        try container.encode(latitude, forKey: .lat)
    }
}

nonisolated struct RouteSnapDiagnostics: Codable, Sendable {
    var start: RouteSnapEndpoint?
    var end: RouteSnapEndpoint?
}

struct RouteResponseDebug: Codable, Sendable {
    let routingRevision: String?
    let graphMode: String?
    let searchMeta: RouteResponseSearchMeta?
    let fallback: String?
    var packIdentity: [RoutingPackIdentity]? = nil
    var diagnostics: RouteResponseDiagnostics? = nil
    var failureReason: String? = nil
    var searchMs: Int? = nil
    var pops: Int? = nil
}

struct RoutingPackIdentity: Codable, Sendable, Equatable {
    let regionId: String?
    let releaseId: String?
    let graphSource: String?
    let geometrySource: String?
    let graphBytes: Int?
    let geometryBytes: Int?
    let fuelBytes: Int?
    let graphSha256: String?
    let geometrySha256: String?
    let fuelSha256: String?
    let fuelSource: String?
}

nonisolated struct RouteManeuver: Codable, Identifiable, Sendable {
    let id = UUID()
    /// Route-engine identity that survives decode and route-stage composition.
    let stableID: String?
    /// Optional itinerary stage arrival identity.
    let stageID: String?
    let instruction: String?
    let type: String?
    /// Web roadbook kind (`curve` / `junction`) when the backend or client enricher provides it.
    let kind: String?
    let side: String?
    let number: Int?
    let degrees: Double?
    let distanceMeters: Double?
    let alongMeters: Double?

    enum CodingKeys: String, CodingKey {
        case stableID, stageID, instruction, type, kind, side, number, degrees
        case distanceMeters, alongMeters
    }

    init(
        instruction: String?,
        type: String?,
        stableID: String? = nil,
        stageID: String? = nil,
        kind: String? = nil,
        side: String? = nil,
        number: Int? = nil,
        degrees: Double? = nil,
        distanceMeters: Double?,
        alongMeters: Double?
    ) {
        self.stableID = stableID
        self.stageID = stageID
        self.instruction = instruction
        self.type = type
        self.kind = kind
        self.side = side
        self.number = number
        self.degrees = degrees
        self.distanceMeters = distanceMeters
        self.alongMeters = alongMeters
    }

    /// Copies a maneuver with a shifted along-route distance (multi-stage plans).
    func shiftingAlong(by offset: Double) -> RouteManeuver {
        RouteManeuver(
            instruction: instruction,
            type: type,
            stableID: stableID,
            stageID: stageID,
            kind: kind,
            side: side,
            number: number,
            degrees: degrees,
            distanceMeters: distanceMeters,
            alongMeters: (alongMeters ?? 0) + offset
        )
    }
}

struct RouteWarning: Codable, Sendable {
    let code: String?
    let message: String?
}

struct RouteResponse: Codable, Sendable {
    let status: String
    let error: String?
    let message: String?
    let distanceMeters: Double?
    let estimatedMovingSeconds: Double?
    let estimatedElapsedSeconds: Double?
    let geometry: [RouteCoordinate]?
    let segments: [RouteSegment]?
    let stats: RouteStats?
    let maneuvers: [RouteManeuver]?
    let warnings: [RouteWarning]?
    let dirtPercentValue: Int?
    let pavedPercentValue: Int?
    var backtrackMeters: Double? = nil
    var backtrackPct: Double? = nil
    var backtrackReason: String? = nil
    var restrictedMeters: Double? = nil
    var restrictedReason: String? = nil
    var debug: RouteResponseDebug? = nil
    var serviceContract: String? = nil
    var serviceBuild: String? = nil

    enum CodingKeys: String, CodingKey {
        case status, error, message, distanceMeters, geometry, segments, stats, maneuvers, warnings, debug
        case serviceContract, serviceBuild
        case backtrackMeters, backtrackPct, backtrackReason
        case restrictedMeters, restrictedReason
        case estimatedMovingSeconds, estimatedElapsedSeconds
        case dirtPercentValue = "dirtPercent"
        case pavedPercentValue = "pavedPercent"
    }

    var isComplete: Bool { status == "complete" }
    var coordinates: [RouteCoordinate] { geometry ?? [] }
    var dirtPercent: Int { stats?.dirtPercent ?? dirtPercentValue ?? 0 }
    var pavedPercent: Int { stats?.pavedPercent ?? pavedPercentValue ?? max(0, 100 - dirtPercent) }
}

enum RoutingError: LocalizedError {
    case invalidEndpoints
    case server(String)
    case invalidResponse
    /// From here: GPS (or start) is farther than the snap radius from any eligible edge.
    case offGraphStart
    case fuelGap(FuelGap)
    case fuelUnknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoints: "Choose a valid start and destination."
        case .server(let message): message
        case .invalidResponse: "The routing service returned an unreadable response."
        case .offGraphStart:
            "Your start (GPS) isn’t close enough to a mapped road. Tap the nearest road to set A — B stays put."
        case .fuelGap(let gap): gap.message
        case .fuelUnknown(let message): message
        }
    }
}
