import CoreLocation
import Foundation

nonisolated enum RouteProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case cleanest
    case direct
    case balanced
    case dirt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cleanest: "Clean"
        case .direct: "Direct"
        case .balanced: "Balanced"
        case .dirt: "Dirt"
        }
    }

    /// One-line guidance — Clean is nav-like; others optimize ride character.
    var guidance: String {
        switch self {
        case .cleanest: "Pavement only · skip towns unless B is there"
        case .direct: "Follow the A→B line · take dirt when it stays direct"
        case .balanced: "Dual-sport mix · aim about half dirt / half paved"
        case .dirt: "Adventure ride to B · meander for dirt, not the highway ETA"
        }
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
    var avoidEdgeIds: [String]?
    var priorEdgeIds: [String]?
    var arrivalEdgeId: String?
    var backtrackFactor: Double?
    var sessionSeed: UInt64?
    var maxPathMeters: Double?
    var directExtraBudgetMeters: Double?

    init(
        avoidEdgeIds: [String] = [],
        priorEdgeIds: [String] = [],
        arrivalEdgeId: String? = nil,
        backtrackFactor: Double? = nil,
        sessionSeed: UInt64? = nil,
        maxPathMeters: Double? = nil,
        directExtraBudgetMeters: Double? = nil
    ) {
        self.avoidEdgeIds = avoidEdgeIds.isEmpty ? nil : avoidEdgeIds
        self.priorEdgeIds = priorEdgeIds.isEmpty ? nil : priorEdgeIds
        self.arrivalEdgeId = arrivalEdgeId
        self.backtrackFactor = backtrackFactor
        self.sessionSeed = sessionSeed
        self.maxPathMeters = maxPathMeters
        self.directExtraBudgetMeters = directExtraBudgetMeters
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
        directExtraBudgetMeters: Double? = nil
    ) {
        self.profile = profile
        self.locations = locations
        vehicle = "dual-sport-motorcycle"
        accessPolicy = AccessPolicy(
            motorizedPermissive: true,
            motorizedUnknown: profile == .cleanest ? false : allowUnknown
        )
        let seed = sessionSeed == 0 ? nil : sessionSeed
        if avoidEdgeIds.isEmpty, priorEdgeIds.isEmpty, arrivalEdgeId == nil,
           backtrackFactor == nil, seed == nil, maxPathMeters == nil,
           directExtraBudgetMeters == nil {
            options = nil
        } else {
            options = RouteRequestOptions(
                avoidEdgeIds: avoidEdgeIds,
                priorEdgeIds: priorEdgeIds,
                arrivalEdgeId: arrivalEdgeId,
                backtrackFactor: backtrackFactor,
                sessionSeed: seed,
                maxPathMeters: maxPathMeters,
                directExtraBudgetMeters: directExtraBudgetMeters
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
}

struct FuelChainRequest: Codable, Sendable {
    let profile: RouteProfile
    let locations: [RouteLocation]
    let vehicle: String
    let accessPolicy: AccessPolicy
    let options: RouteRequestOptions?
    let fuel: FuelChainConstraint

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
        priorEdgeIds: [String] = [],
        arrivalEdgeId: String? = nil,
        backtrackFactor: Double? = nil,
        probeFirstReachableStation: Bool = false,
        excludedStationIds: [String] = [],
        windowMaxStops: Int? = nil,
        allowPartialWindow: Bool = false,
        windowTimeBudgetMs: Int? = nil,
        requiredFirstStationId: String? = nil
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
        options = avoidEdgeIds.isEmpty && priorEdgeIds.isEmpty && arrivalEdgeId == nil
            && backtrackFactor == nil
            ? nil
            : RouteRequestOptions(
                avoidEdgeIds: avoidEdgeIds,
                priorEdgeIds: priorEdgeIds,
                arrivalEdgeId: arrivalEdgeId,
                backtrackFactor: backtrackFactor
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
            requiredFirstStationId: requiredFirstStationId
        )
    }
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
    let states: Int?
    let dijkstraPops: Int?
    let matchedFuel: Int?
    let elapsedMs: Int?
    var candidateK: Int? = nil
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
}

struct FuelChainResponse: Codable, Sendable {
    let status: String
    let error: String?
    let message: String?
    let regionIds: [String]?
    let stops: [FuelChainStop]?
    let graphMeters: [Double]?
    let diagnostics: FuelChainDiagnostics?
    var stationCandidates: [FuelStationCandidate]? = nil
    var firstReachableStationMeters: Double? = nil
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

    enum CodingKeys: String, CodingKey {
        case surfaceClass, trackClass, accessClass, distanceMeters, geometry, coords, edgeId
    }

    init(
        surfaceClass: String?,
        trackClass: String?,
        accessClass: String? = nil,
        distanceMeters: Double?,
        geometry: [RouteCoordinate]?,
        coords: [RouteCoordinate]?,
        edgeId: String?
    ) {
        self.surfaceClass = surfaceClass
        self.trackClass = trackClass
        self.accessClass = accessClass
        self.distanceMeters = distanceMeters
        self.geometry = geometry
        self.coords = coords
        self.edgeId = edgeId
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

    init(
        dirtPercent: Int? = nil,
        pavedPercent: Int? = nil,
        unknownAccessPercent: Int? = nil
    ) {
        self.dirtPercent = dirtPercent
        self.pavedPercent = pavedPercent
        self.unknownAccessPercent = unknownAccessPercent
    }

    enum CodingKeys: String, CodingKey {
        case dirtPercent, pavedPercent, unknownAccessPercent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dirtPercent = try c.decodeIfPresent(Int.self, forKey: .dirtPercent)
        pavedPercent = try c.decodeIfPresent(Int.self, forKey: .pavedPercent)
        unknownAccessPercent = try c.decodeIfPresent(Int.self, forKey: .unknownAccessPercent)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(dirtPercent, forKey: .dirtPercent)
        try c.encodeIfPresent(pavedPercent, forKey: .pavedPercent)
        try c.encodeIfPresent(unknownAccessPercent, forKey: .unknownAccessPercent)
    }
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
}

struct RouteResponseDebug: Codable, Sendable {
    let routingRevision: String?
    let graphMode: String?
    let searchMeta: RouteResponseSearchMeta?
    let fallback: String?
    var packIdentity: [RoutingPackIdentity]? = nil
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
        case instruction, type, kind, side, number, degrees, distanceMeters, alongMeters
    }

    init(
        instruction: String?,
        type: String?,
        kind: String? = nil,
        side: String? = nil,
        number: Int? = nil,
        degrees: Double? = nil,
        distanceMeters: Double?,
        alongMeters: Double?
    ) {
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
