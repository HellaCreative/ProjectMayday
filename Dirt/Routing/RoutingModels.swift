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
        case .cleanest: "Pavement first · Google/Waze-style"
        case .direct: "Crow-flies to B · pick up dirt when it barely detours"
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
    let avoidEdgeIds: [String]
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
        avoidEdgeIds: [String] = []
    ) {
        self.profile = profile
        self.locations = locations
        vehicle = "dual-sport-motorcycle"
        accessPolicy = AccessPolicy(
            motorizedPermissive: true,
            motorizedUnknown: profile == .cleanest ? false : allowUnknown
        )
        options = avoidEdgeIds.isEmpty ? nil : RouteRequestOptions(avoidEdgeIds: avoidEdgeIds)
    }
}

struct RouteSegment: Codable, Identifiable, Sendable {
    let id = UUID()
    let surfaceClass: String?
    let trackClass: String?
    let distanceMeters: Double?
    let geometry: [RouteCoordinate]?
    let coords: [RouteCoordinate]?
    /// Authoritative network edge ID (e.g. `ns-gov-…`) — used by incident
    /// reports so "Find a way around" can avoid this edge on-device.
    let edgeId: String?

    enum CodingKeys: String, CodingKey {
        case surfaceClass, trackClass, distanceMeters, geometry, coords, edgeId
    }

    init(
        surfaceClass: String?,
        trackClass: String?,
        distanceMeters: Double?,
        geometry: [RouteCoordinate]?,
        coords: [RouteCoordinate]?,
        edgeId: String?
    ) {
        self.surfaceClass = surfaceClass
        self.trackClass = trackClass
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

    enum CodingKeys: String, CodingKey {
        case status, error, message, distanceMeters, geometry, segments, stats, maneuvers, warnings
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

    var errorDescription: String? {
        switch self {
        case .invalidEndpoints: "Choose a valid start and destination."
        case .server(let message): message
        case .invalidResponse: "The routing service returned an unreadable response."
        case .offGraphStart:
            "Your start (GPS) isn’t close enough to a mapped road. Tap the nearest road to set A — B stays put."
        }
    }
}
