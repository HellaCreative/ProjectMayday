import CoreLocation
import Foundation

enum RouteProfile: String, Codable, CaseIterable, Identifiable, Sendable {
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
}

struct RouteCoordinate: Codable, Hashable, Sendable {
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

struct RouteRequest: Codable, Sendable {
    let profile: RouteProfile
    let locations: [RouteLocation]
    let vehicle: String
    let accessPolicy: AccessPolicy

    init(profile: RouteProfile, locations: [RouteLocation], allowUnknown: Bool) {
        self.profile = profile
        self.locations = locations
        vehicle = "dual-sport-motorcycle"
        accessPolicy = AccessPolicy(
            motorizedPermissive: true,
            motorizedUnknown: profile == .cleanest ? false : allowUnknown
        )
    }
}

struct RouteSegment: Codable, Identifiable, Sendable {
    let id = UUID()
    let surfaceClass: String?
    let trackClass: String?
    let distanceMeters: Double?
    let geometry: [RouteCoordinate]?
    let coords: [RouteCoordinate]?

    enum CodingKeys: String, CodingKey {
        case surfaceClass, trackClass, distanceMeters, geometry, coords
    }

    var coordinates: [RouteCoordinate] { geometry ?? coords ?? [] }

    var isDirt: Bool {
        let kind = (surfaceClass ?? trackClass ?? "").lowercased()
        return ["gravel", "dirt", "track", "access", "resource", "unknown", "unpaved"].contains(kind)
    }
}

struct RouteStats: Codable, Sendable {
    let dirtPercent: Int?
    let pavedPercent: Int?
}

struct RouteManeuver: Codable, Identifiable, Sendable {
    let id = UUID()
    let instruction: String?
    let type: String?
    let distanceMeters: Double?
    let alongMeters: Double?

    enum CodingKeys: String, CodingKey {
        case instruction, type, distanceMeters, alongMeters
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

    var errorDescription: String? {
        switch self {
        case .invalidEndpoints: "Choose a valid start and destination."
        case .server(let message): message
        case .invalidResponse: "The routing service returned an unreadable response."
        }
    }
}
