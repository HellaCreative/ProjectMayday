import CoreLocation
import Foundation

/// Hard metro-core wall for Dirt / Balanced / Direct. Clean is exempt.
///
/// Boxes are metro-wide, not downtown-tiny. A downtown-only Vancouver box
/// still lets Squamish→east dive through the city; this wall must not.
/// Lockstep: `scripts/pack-fabric/routing/lib/hop-search.js`.
nonisolated enum UrbanCore {
    struct Box: Sendable {
        var minLat: Double
        var maxLat: Double
        var minLon: Double
        var maxLon: Double
        var name: String

        func contains(_ lat: Double, _ lon: Double) -> Bool {
            lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon
        }

        func contains(_ c: CLLocationCoordinate2D) -> Bool {
            contains(c.latitude, c.longitude)
        }
    }

    /// Major Canadian metros. Vancouver covers the Lower Mainland core
    /// (Vancouver / Burnaby / Richmond / North Van) and stops south of Lions Bay
    /// so Sea-to-Sky remains usable until the city actually begins.
    static let boxes: [Box] = [
        Box(minLat: 49.00, maxLat: 49.42, minLon: -123.32, maxLon: -122.70, name: "vancouver"),
        Box(minLat: 48.40, maxLat: 48.52, minLon: -123.45, maxLon: -123.30, name: "victoria"),
        Box(minLat: 50.85, maxLat: 51.22, minLon: -114.32, maxLon: -113.85, name: "calgary"),
        Box(minLat: 53.40, maxLat: 53.70, minLon: -113.72, maxLon: -113.28, name: "edmonton"),
        Box(minLat: 43.58, maxLat: 43.85, minLon: -79.64, maxLon: -79.12, name: "toronto"),
        Box(minLat: 45.38, maxLat: 45.72, minLon: -73.98, maxLon: -73.48, name: "montreal"),
        Box(minLat: 45.32, maxLat: 45.48, minLon: -75.85, maxLon: -75.62, name: "ottawa"),
        Box(minLat: 49.80, maxLat: 50.00, minLon: -97.30, maxLon: -96.95, name: "winnipeg")
    ]

    static func box(containing c: CLLocationCoordinate2D) -> Box? {
        boxes.first { $0.contains(c) }
    }

    static func contains(_ c: CLLocationCoordinate2D) -> Bool {
        box(containing: c) != nil
    }

    /// Ban travel through a metro core unless a pin is actually inside that same box.
    static func blocks(
        point: CLLocationCoordinate2D,
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D
    ) -> Bool {
        guard let box = box(containing: point) else { return false }
        if box.contains(start) || box.contains(end) { return false }
        return true
    }
}
