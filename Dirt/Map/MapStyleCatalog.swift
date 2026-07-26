import Foundation

/// Swappable visual basemaps. Routing still uses OSM graph data via `/api/route` —
/// these styles are display-only (Shortbread vector or Mapbox classic raster).
///
/// MapLibre does not resolve `mapbox://` URIs, so Mapbox classic styles are loaded
/// as Style Spec raster sources against the Static Tiles API (see Mapbox’s
/// “Use Mapbox APIs in MapLibre” guide).
enum MapStyleID: String, CaseIterable, Identifiable, Sendable {
    case shortbread
    case mapboxOutdoors
    case mapboxStreets
    case mapboxSatellite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shortbread: "OSM Shortbread"
        case .mapboxOutdoors: "Mapbox Outdoors"
        case .mapboxStreets: "Mapbox Streets"
        case .mapboxSatellite: "Mapbox Satellite"
        }
    }

    var subtitle: String {
        switch self {
        case .shortbread: "Default · OSM vector · works offline without a Mapbox token"
        case .mapboxOutdoors: "Terrain, trails, land cover · dual-sport oriented"
        case .mapboxStreets: "General road basemap"
        case .mapboxSatellite: "Aerial imagery"
        }
    }

    /// Whether this style needs a Mapbox public access token (`pk.…`).
    var requiresMapboxToken: Bool {
        self != .shortbread
    }

    /// Classic Mapbox style id used by the Static Tiles API, if applicable.
    var mapboxStylePath: String? {
        switch self {
        case .shortbread: nil
        case .mapboxOutdoors: "mapbox/outdoors-v12"
        case .mapboxStreets: "mapbox/streets-v12"
        case .mapboxSatellite: nil // uses Raster Tiles API
        }
    }
}

/// Resolves the active basemap URL and persists the rider’s choice.
enum MapStyleCatalog {
    static let preferenceKey = "dirt.map.styleID"
    static let tokenKey = "dirt.mapbox.accessToken"

    /// Preferred default when a token is available; otherwise Shortbread.
    static var preferredDefault: MapStyleID {
        hasMapboxToken ? .mapboxOutdoors : .shortbread
    }

    static var selectedID: MapStyleID {
        get {
            let raw = UserDefaults.standard.string(forKey: preferenceKey) ?? ""
            if let id = MapStyleID(rawValue: raw) {
                return resolve(id)
            }
            return preferredDefault
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey)
        }
    }

    /// Falls back to Shortbread when a Mapbox style is selected without a token.
    static func resolve(_ id: MapStyleID) -> MapStyleID {
        if id.requiresMapboxToken, !hasMapboxToken { return .shortbread }
        return id
    }

    static var hasMapboxToken: Bool {
        !(mapboxAccessToken?.isEmpty ?? true)
    }

    /// Token order: UserDefaults (Layers paste) → Info.plist → process env.
    static var mapboxAccessToken: String? {
        if let stored = UserDefaults.standard.string(forKey: tokenKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "MAPBOX_ACCESS_TOKEN") as? String {
            let trimmed = plist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.hasPrefix("$(") { return trimmed }
        }
        if let env = ProcessInfo.processInfo.environment["MAPBOX_ACCESS_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        return nil
    }

    static func setMapboxAccessToken(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: tokenKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: tokenKey)
        }
    }

    /// Style URL for MapLibre. Shortbread is the remote production JSON;
    /// Mapbox styles are written to a cache file so the token never lands in git.
    static func styleURL(for id: MapStyleID = selectedID) -> URL {
        let resolved = resolve(id)
        switch resolved {
        case .shortbread:
            return AppConfig.mapStyleURL
        case .mapboxOutdoors, .mapboxStreets, .mapboxSatellite:
            return writeMapboxRasterStyle(for: resolved) ?? AppConfig.mapStyleURL
        }
    }

    // MARK: - Raster style JSON

    private static func writeMapboxRasterStyle(for id: MapStyleID) -> URL? {
        guard let token = mapboxAccessToken else { return nil }
        let json: [String: Any]
        switch id {
        case .mapboxSatellite:
            json = rasterStyleJSON(
                sourceID: "mapbox-satellite",
                tiles: [
                    "https://api.mapbox.com/v4/mapbox.satellite/{z}/{x}/{y}@2x.jpg90?access_token=\(token)"
                ],
                tileSize: 256,
                attribution: "© Mapbox © Maxar © OpenStreetMap"
            )
        case .mapboxOutdoors, .mapboxStreets:
            guard let path = id.mapboxStylePath else { return nil }
            json = rasterStyleJSON(
                sourceID: "mapbox-raster",
                tiles: [
                    "https://api.mapbox.com/styles/v1/\(path)/tiles/512/{z}/{x}/{y}@2x?access_token=\(token)"
                ],
                tileSize: 512,
                attribution: "© Mapbox © OpenStreetMap"
            )
        case .shortbread:
            return AppConfig.mapStyleURL
        }

        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            return nil
        }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let file = dir.appendingPathComponent("dirt-basemap-\(id.rawValue).json", isDirectory: false)
        do {
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    private static func rasterStyleJSON(
        sourceID: String,
        tiles: [String],
        tileSize: Int,
        attribution: String
    ) -> [String: Any] {
        [
            "version": 8,
            "name": "DIRT basemap",
            "sources": [
                sourceID: [
                    "type": "raster",
                    "tiles": tiles,
                    "tileSize": tileSize,
                    "attribution": attribution,
                    "maxzoom": 22
                ]
            ],
            "layers": [
                [
                    "id": "basemap",
                    "type": "raster",
                    "source": sourceID
                ]
            ]
        ]
    }
}
