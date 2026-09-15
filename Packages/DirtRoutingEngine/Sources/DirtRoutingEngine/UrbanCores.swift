import Foundation

/// Hardcoded metro walls matching `hop-search.js` `METRO_CORE_WALL`. Used when a
/// pack does not embed `urbanCores`. Pack metadata still wins when present.
enum UrbanCores {
    static let defaults: [GeographicBox] = [
        .init(minLat: 49.0, maxLat: 49.42, minLon: -123.32, maxLon: -122.7, name: "vancouver"),
        .init(minLat: 49.0, maxLat: 49.14, minLon: -122.45, maxLon: -122.15, name: "abbotsford"),
        .init(minLat: 49.08, maxLat: 49.2, minLon: -122.05, maxLon: -121.85, name: "chilliwack"),
        .init(minLat: 48.4, maxLat: 48.52, minLon: -123.45, maxLon: -123.3, name: "victoria"),
        .init(minLat: 49.8, maxLat: 50.0, minLon: -119.65, maxLon: -119.3, name: "kelowna"),
        .init(minLat: 50.62, maxLat: 50.75, minLon: -120.5, maxLon: -120.15, name: "kamloops"),
        .init(minLat: 53.82, maxLat: 54.0, minLon: -122.85, maxLon: -122.65, name: "prince-george"),
        .init(minLat: 44.55, maxLat: 44.78, minLon: -63.75, maxLon: -63.4, name: "halifax"),
        .init(minLat: 45.85, maxLat: 46.2, minLon: -64.95, maxLon: -64.55, name: "moncton"),
        .init(minLat: 45.2, maxLat: 45.35, minLon: -66.2, maxLon: -65.95, name: "saint-john"),
        .init(minLat: 45.9, maxLat: 46.05, minLon: -66.75, maxLon: -66.55, name: "fredericton"),
        .init(minLat: 46.75, maxLat: 46.9, minLon: -71.35, maxLon: -71.1, name: "quebec-city"),
        .init(minLat: 50.85, maxLat: 51.22, minLon: -114.32, maxLon: -113.85, name: "calgary"),
        .init(minLat: 53.4, maxLat: 53.7, minLon: -113.72, maxLon: -113.28, name: "edmonton"),
        .init(minLat: 43.58, maxLat: 43.85, minLon: -79.64, maxLon: -79.12, name: "toronto"),
        .init(minLat: 45.38, maxLat: 45.72, minLon: -73.98, maxLon: -73.48, name: "montreal"),
        .init(minLat: 45.32, maxLat: 45.48, minLon: -75.85, maxLon: -75.62, name: "ottawa"),
        .init(minLat: 49.8, maxLat: 50.0, minLon: -97.3, maxLon: -96.95, name: "winnipeg"),
        .init(minLat: 50.38, maxLat: 50.52, minLon: -104.75, maxLon: -104.5, name: "regina"),
        .init(minLat: 52.05, maxLat: 52.22, minLon: -106.8, maxLon: -106.55, name: "saskatoon")
    ]
    static func boxes(in pack: any RoadGraph) -> [GeographicBox] {
        pack.urbanCores.isEmpty ? defaults : pack.urbanCores
    }
}
