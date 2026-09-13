import Foundation
import SwiftData

@Model
final class SavedRoute {
    var id: UUID
    var name: String
    var profileRawValue: String
    var coordinatesData: Data
    var distanceMeters: Double
    var dirtPercent: Int
    var pavedPercent: Int
    /// Optional Graph-v3 route runs. Existing records remain valid with nil.
    var segmentsData: Data?
    var ridePreferencesData: Data?
    /// Compatibility with DEV builds that saved per-leg seeds. Retain the
    /// optional storage column while routing behavior is recovered.
    var routeSeedsData: Data?
    /// Additive versioned canonical plan. Nil keeps legacy library entries readable.
    var routingPlanData: Data?
    var surfaceFamilyMode: String?
    var createdAt: Date

    var profile: RouteProfile {
        get { RouteProfile(rawValue: profileRawValue) ?? .balanced }
        set { profileRawValue = newValue.rawValue }
    }

    var coordinates: [RouteCoordinate] {
        get { (try? JSONDecoder().decode([RouteCoordinate].self, from: coordinatesData)) ?? [] }
        set { coordinatesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var segments: [RouteSegment]? {
        get {
            guard let segmentsData else { return nil }
            return try? JSONDecoder().decode([RouteSegment].self, from: segmentsData)
        }
        set {
            segmentsData = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    init(
        id: UUID = UUID(),
        name: String,
        profile: RouteProfile,
        coordinates: [RouteCoordinate],
        distanceMeters: Double,
        dirtPercent: Int,
        pavedPercent: Int,
        segments: [RouteSegment]? = nil,
        surfaceFamilyMode: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        profileRawValue = profile.rawValue
        coordinatesData = (try? JSONEncoder().encode(coordinates)) ?? Data()
        self.distanceMeters = distanceMeters
        self.dirtPercent = dirtPercent
        self.pavedPercent = pavedPercent
        segmentsData = segments.flatMap { try? JSONEncoder().encode($0) }
        self.surfaceFamilyMode = surfaceFamilyMode
        self.createdAt = createdAt
    }
}

enum GPXExporter {
    struct FuelWarning: Equatable {
        let from: RouteCoordinate
        let to: RouteCoordinate
        let description: String
    }

    static func document(
        for route: SavedRoute,
        fuelWarnings: [FuelWarning] = [],
        fuelUnknownMessages: [String] = []
    ) -> String {
        let points = route.coordinates.map {
            "      <trkpt lat=\"\($0.latitude)\" lon=\"\($0.longitude)\"></trkpt>"
        }.joined(separator: "\n")
        let warningWaypoints = fuelWarnings.enumerated().flatMap { index, warning in
            let description = escape(warning.description)
            return [
                "  <wpt lat=\"\(warning.from.latitude)\" lon=\"\(warning.from.longitude)\"><name>FUEL GAP START \(index + 1)</name><desc>\(description)</desc></wpt>",
                "  <wpt lat=\"\(warning.to.latitude)\" lon=\"\(warning.to.longitude)\"><name>FUEL GAP END \(index + 1)</name><desc>\(description)</desc></wpt>"
            ]
        }.joined(separator: "\n")
        let warningDescriptions = fuelWarnings.map(\.description) + fuelUnknownMessages
        let routeDescription = warningDescriptions.isEmpty
            ? ""
            : "\n    <desc>\(escape(warningDescriptions.joined(separator: " | ")))</desc>"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="DIRT" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>\(escape(route.name))</name></metadata>
        \(warningWaypoints)
          <trk>
            <name>\(escape(route.name))</name>\(routeDescription)
            <trkseg>
        \(points)
            </trkseg>
          </trk>
        </gpx>
        """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
