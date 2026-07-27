import Foundation

/// Swappable visual basemaps. Routing still uses OSM graph data via `/api/route` —
/// these styles are display-only (Shortbread vector or Esri raster).
enum MapStyleID: String, CaseIterable, Identifiable, Sendable {
    case shortbread
    case esriSatellite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shortbread:    "OSM Shortbread"
        case .esriSatellite: "Esri World Imagery"
        }
    }

    var subtitle: String {
        switch self {
        case .shortbread:    "Default · High-contrast OSM vector · works offline"
        case .esriSatellite: "Aerial satellite imagery · Esri / Maxar"
        }
    }
}

/// Resolves the active basemap URL and persists the rider's choice.
enum MapStyleCatalog {
    static let preferenceKey = "dirt.map.styleID"

    static var selectedID: MapStyleID {
        get {
            let raw = UserDefaults.standard.string(forKey: preferenceKey) ?? ""
            return MapStyleID(rawValue: raw) ?? .shortbread
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey)
        }
    }

    /// Style URL for MapLibre.
    static func styleURL(for id: MapStyleID = selectedID) -> URL {
        switch id {
        case .shortbread:
            return AppConfig.mapStyleURL
        case .esriSatellite:
            return writeEsriRasterStyle() ?? AppConfig.mapStyleURL
        }
    }

    // MARK: - Raster style JSON

    private static func writeEsriRasterStyle() -> URL? {
        let json = rasterStyleJSON(
            sourceID: "esri-satellite",
            tiles: [
                // Esri tile order is {z}/{y}/{x}
                "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"
            ],
            tileSize: 256,
            attribution: "© Esri, Maxar, Earthstar Geographics, and the GIS User Community"
        )
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            return nil
        }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let file = dir.appendingPathComponent("dirt-basemap-esri-satellite.json", isDirectory: false)
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
                    "maxzoom": 18
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
