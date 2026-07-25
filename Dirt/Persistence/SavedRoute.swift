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
    var createdAt: Date

    var profile: RouteProfile {
        get { RouteProfile(rawValue: profileRawValue) ?? .balanced }
        set { profileRawValue = newValue.rawValue }
    }

    var coordinates: [RouteCoordinate] {
        get { (try? JSONDecoder().decode([RouteCoordinate].self, from: coordinatesData)) ?? [] }
        set { coordinatesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    init(
        id: UUID = UUID(),
        name: String,
        profile: RouteProfile,
        coordinates: [RouteCoordinate],
        distanceMeters: Double,
        dirtPercent: Int,
        pavedPercent: Int,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        profileRawValue = profile.rawValue
        coordinatesData = (try? JSONEncoder().encode(coordinates)) ?? Data()
        self.distanceMeters = distanceMeters
        self.dirtPercent = dirtPercent
        self.pavedPercent = pavedPercent
        self.createdAt = createdAt
    }
}

enum GPXExporter {
    static func document(for route: SavedRoute) -> String {
        let points = route.coordinates.map {
            "      <trkpt lat=\"\($0.latitude)\" lon=\"\($0.longitude)\"></trkpt>"
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="DIRT" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>\(escape(route.name))</name></metadata>
          <trk>
            <name>\(escape(route.name))</name>
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
