import Foundation

/// Swappable visual basemaps. Display only. Routing uses on-device graph packs.
enum MapStyleID: String, CaseIterable, Identifiable, Sendable {
    case shortbread
    case shortbreadRich

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shortbread:     "Standard"
        case .shortbreadRich: "Rich"
        }
    }

    var subtitle: String {
        switch self {
        case .shortbread:     "High-contrast OSM Shortbread"
        case .shortbreadRich: "Default · Deeper landcover and hotter road colours"
        }
    }
}

/// Resolves the active basemap URL and persists the rider's choice.
enum MapStyleCatalog {
    static let preferenceKey = "dirt.map.styleID"
    /// Bump when generated paint/label rules change so a cached JSON cannot linger.
    static let generatedStyleRevision = "osmand-v3"
    /// Natural Earth 50m admin-1 (lakes), US+CA interior borders. Not pack bounds.
    static let admin1OverviewSourceID = "dirt-admin1-overview"
    static let admin1OverviewLayerID = "dirt-bound-state-overview"

    private final class BundleToken {}

    static var selectedID: MapStyleID {
        get {
            let raw = UserDefaults.standard.string(forKey: preferenceKey) ?? ""
            // Retired Esri satellite — land on Rich.
            if raw == "esriSatellite" { return .shortbreadRich }
            // First launch / empty preference → Rich.
            if raw.isEmpty { return .shortbreadRich }
            return MapStyleID(rawValue: raw) ?? .shortbreadRich
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey)
        }
    }

    /// Style URL for MapLibre (bundled JSON with local sprite sheet).
    static func styleURL(
        for id: MapStyleID = selectedID,
        tileSource: ShortbreadTileSource = .publicOSM
    ) -> URL {
        switch id {
        case .shortbread:
            return generatedShortbreadStyleURL(rich: false, tileSource: tileSource)
                ?? bundledStyleURL(resource: "shortbread-style")
                ?? AppConfig.mapStyleURL
        case .shortbreadRich:
            return generatedShortbreadStyleURL(rich: true, tileSource: tileSource)
                ?? bundledStyleURL(resource: "shortbread-rich-style")
                ?? bundledStyleURL(resource: "shortbread-style")
                ?? AppConfig.mapStyleURL
        }
    }

    /// Rich is derived from the bundled Shortbread style so both choices stay
    /// structurally identical while Rich gets the saturated outdoor palette the
    /// product promises. This also avoids silently falling back to Standard when
    /// a second, very large style JSON is omitted from the app bundle.
    private static func generatedShortbreadStyleURL(
        rich: Bool,
        tileSource: ShortbreadTileSource
    ) -> URL? {
        guard let source = bundledJSONURL(resource: "shortbread-style"),
              let data = try? Data(contentsOf: source),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let incoming = root["layers"] as? [[String: Any]]
        else { return nil }

        var layers: [[String: Any]] = []
        layers.reserveCapacity(incoming.count + 4)
        for var layer in incoming {
            let id = (layer["id"] as? String ?? "").lowercased()
            var paint = layer["paint"] as? [String: Any] ?? [:]

            applyLandcover(id: id, rich: rich, paint: &paint)
            if paint["line-color"] != nil, id.contains("highway") {
                applyHighwayColors(id: id, rich: rich, paint: &paint)
                applyHighwayWidths(id: id, paint: &paint)
            }
            layer["paint"] = paint

            if id == "boundaries-0" {
                layers.append(contentsOf: dirtBoundaryLineLayers(from: layer))
                continue
            }
            if id == "boundary_labels-named-0" {
                layers.append(contentsOf: dirtBoundaryLabelLayers(from: layer))
                continue
            }
            if id == "label-street-centre-12" {
                layers.append(contentsOf: dirtStreetNameLayers(from: layer))
                continue
            }
            retunePlaceLabel(&layer)
            retunePathLabel(&layer)
            retuneWaterLabel(&layer)
            layers.append(layer)
        }

        if var sources = root["sources"] as? [String: Any] {
            for key in sources.keys {
                guard var source = sources[key] as? [String: Any],
                      source["type"] as? String == "vector"
                else { continue }
                source["tiles"] = [tileSource.tileTemplate]
                sources[key] = source
            }
            if let admin1 = admin1OverviewGeoJSONObject() {
                sources[admin1OverviewSourceID] = [
                    "type": "geojson",
                    "data": admin1
                ]
            }
            root["sources"] = sources
        }
        root["name"] = rich ? "DIRT Rich Shortbread" : "DIRT Standard Shortbread"
        root["layers"] = layers
        if (root["sprite"] as? String) == "DIRT_SPRITE_PLACEHOLDER",
           let spriteBase = bundledSpriteBaseURL() {
            root["sprite"] = spriteBase.absoluteString
        }
        guard let richData = try? JSONSerialization.data(withJSONObject: root) else { return nil }

        let destination = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(
                "dirt-shortbread-\(generatedStyleRevision)-\(rich ? "rich" : "standard")-\(tileSource.styleCacheKey).json"
            )
        do {
            try richData.write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
    }

    /// Writes a cache copy with `sprite` pointed at the bundled sprite sheet.
    static func bundledStyleURL(resource: String) -> URL? {
        guard let source = Bundle.main.url(forResource: resource, withExtension: "json") else {
            return nil
        }
        guard var json = try? String(contentsOf: source, encoding: .utf8) else { return source }
        if json.contains("DIRT_SPRITE_PLACEHOLDER"), let spriteBase = bundledSpriteBaseURL() {
            json = json.replacingOccurrences(of: "DIRT_SPRITE_PLACEHOLDER", with: spriteBase.absoluteString)
            let dest = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("dirt-\(resource).json")
            try? json.write(to: dest, atomically: true, encoding: .utf8)
            return dest
        }
        return source
    }

    private static func bundledSpriteBaseURL() -> URL? {
        let json = Bundle.main.url(
            forResource: "svwd03sprite",
            withExtension: "json",
            subdirectory: "shortbread"
        ) ?? Bundle.main.url(forResource: "svwd03sprite", withExtension: "json")
        guard let json else { return nil }
        return json.deletingPathExtension()
    }
}

// MARK: - OsmAnd-aimed Shortbread paint + admin labels

extension MapStyleCatalog {
    /// Daytime OsmAnd-like palette (pale land, orange roads, green cover at street zoom).
    /// Rich applies `×1.15` HSL saturation on top. Never paint pack-bound polygons.
    private static let osmandBase: [String: String] = [
        "background": "#ebe8e0",
        "water-fill": "#7eb8d4",
        "water-line": "#5a9ec0",
        "forest": "#9ec97a",
        "orchard": "#b3d48a",
        "park": "#b8d690",
        "grass": "#c3dc9a",
        "farmland": "#e4d5a4",
        "residential": "#e6e0d4",
        "retail": "#edd3cc",
        "industrial": "#e8dcc0",
        "edu": "#ddd4ea",
        "beach": "#ead89a",
        "mw-fill": "#c4483c",
        "pri-fill": "#d97838",
        "sec-fill": "#e0a84a",
        "ter-fill": "#e4c85e",
        "mw-casing": "#8a3028",
        "pri-casing": "#9a4a24",
        "sec-casing": "#9a7028",
        "ter-casing": "#88722e",
        "svc-casing": "#6e6a64"
    ]

    static func boostedSaturationHex(_ hex: String, factor: Double = 1.15) -> String {
        guard let base = rgb(from: hex) else { return hex }
        var color = hsl(from: base)
        color.s = min(1, color.s * factor)
        return hexString(from: rgb(from: color))
    }

    private static func paintHex(_ key: String, rich: Bool) -> String {
        let hex = osmandBase[key]!
        return rich ? boostedSaturationHex(hex) : hex
    }

    private static func applyLandcover(id: String, rich: Bool, paint: inout [String: Any]) {
        if id == "background" {
            paint["background-color"] = paintHex("background", rich: rich)
        } else if id.contains("water") {
            if paint["fill-color"] != nil {
                paint["fill-color"] = paintHex("water-fill", rich: rich)
            }
            if paint["line-color"] != nil, !id.contains("label") {
                paint["line-color"] = paintHex("water-line", rich: rich)
            }
        } else if id.contains("forest") {
            paint["fill-color"] = paintHex("forest", rich: rich)
        } else if id.contains("orchard") || id.contains("vineyard") || id.contains("scrub") {
            paint["fill-color"] = paintHex("orchard", rich: rich)
        } else if id.contains("park") || id.contains("heath") || id.contains("meadow") {
            paint["fill-color"] = paintHex("park", rich: rich)
        } else if id.contains("grass") || id.contains("recreation_ground")
                    || id.contains("village_green") || id.contains("golf_course") {
            paint["fill-color"] = paintHex("grass", rich: rich)
        } else if id.contains("farmland") || id.contains("farmyard") {
            paint["fill-color"] = paintHex("farmland", rich: rich)
        } else if id.contains("residential-fill") {
            paint["fill-color"] = paintHex("residential", rich: rich)
        } else if id.contains("retail-fill") || id.contains("commercial-fill") {
            paint["fill-color"] = paintHex("retail", rich: rich)
        } else if id.contains("industrial-fill") || id.contains("construction-fill") {
            paint["fill-color"] = paintHex("industrial", rich: rich)
        } else if id.contains("eduhospital-fill") || id.contains("schoolyard-fill") {
            paint["fill-color"] = paintHex("edu", rich: rich)
        } else if id.contains("beach-fill") || id.contains("sand-fill") {
            paint["fill-color"] = paintHex("beach", rich: rich)
        }
    }

    private static func applyHighwayColors(id: String, rich: Bool, paint: inout [String: Any]) {
        let isCasing = id.contains("casing") || id.contains("outline")
        if isCasing {
            if id.contains("motorway") || id.contains("trunk") {
                paint["line-color"] = paintHex("mw-casing", rich: rich)
            } else if id.contains("primary") {
                paint["line-color"] = paintHex("pri-casing", rich: rich)
            } else if id.contains("secondary") {
                paint["line-color"] = paintHex("sec-casing", rich: rich)
            } else if id.contains("tertiary") {
                paint["line-color"] = paintHex("ter-casing", rich: rich)
            } else if id.contains("service") || id.contains("unclassified")
                        || id.contains("living_street") {
                paint["line-color"] = paintHex("svc-casing", rich: rich)
            }
        } else {
            if id.contains("motorway") || id.contains("trunk") {
                paint["line-color"] = paintHex("mw-fill", rich: rich)
            } else if id.contains("primary") {
                paint["line-color"] = paintHex("pri-fill", rich: rich)
            } else if id.contains("secondary") {
                paint["line-color"] = paintHex("sec-fill", rich: rich)
            } else if id.contains("tertiary") {
                paint["line-color"] = paintHex("ter-fill", rich: rich)
            }
        }
    }

    /// OsmAnd regional view shows motorways/trunks as readable orange strokes, not hairlines.
    private static func applyHighwayWidths(id: String, paint: inout [String: Any]) {
        guard id.contains("otherfill") else { return }
        if id.contains("motorway") {
            paint["line-width"] = ["base": 1.4, "stops": [[3, 0.9], [6, 1.5], [9, 2.6], [14, 7]]]
        } else if id.contains("trunk") {
            paint["line-width"] = ["base": 1.4, "stops": [[6, 1.1], [9, 2.2], [14, 6]]]
        } else if id.contains("primary") {
            paint["line-width"] = ["base": 1.4, "stops": [[7, 1.0], [9, 2.0], [14, 5.5]]]
        }
    }

    /// Country lines from Shortbread z0. State/province lines: Natural Earth
    /// admin-1 through z7 (Shortbread has no admin_level=4 geometry below z7),
    /// then tile lines from z7. Never RegionPolygons pack bounds.
    private static func dirtBoundaryLineLayers(from base: [String: Any]) -> [[String: Any]] {
        func line(id: String, admin: Int, minZoom: Double, dashed: Bool, color: String, widths: [[Any]]) -> [String: Any] {
            var layer = base
            layer["id"] = id
            layer["minzoom"] = minZoom
            layer["filter"] = [
                "all",
                ["==", "admin_level", admin],
                ["!=", "maritime", true]
            ]
            var paint = layer["paint"] as? [String: Any] ?? [:]
            paint["line-color"] = color
            paint["line-opacity"] = 0.88
            paint["line-width"] = ["stops": widths]
            if dashed {
                paint["line-dasharray"] = [4, 3]
            } else {
                paint.removeValue(forKey: "line-dasharray")
            }
            layer["paint"] = paint
            return layer
        }
        var layers: [[String: Any]] = []
        if admin1OverviewGeoJSONObject() != nil {
            var overview = base
            overview["id"] = admin1OverviewLayerID
            overview["source"] = admin1OverviewSourceID
            overview.removeValue(forKey: "source-layer")
            overview["minzoom"] = 0
            overview["maxzoom"] = 7
            overview.removeValue(forKey: "filter")
            var paint = overview["paint"] as? [String: Any] ?? [:]
            paint["line-color"] = "#9a74b8"
            paint["line-opacity"] = 0.9
            paint["line-width"] = ["stops": [[2, 0.7], [5, 1.0], [7, 1.2]]]
            paint["line-dasharray"] = [4, 3]
            overview["paint"] = paint
            layers.append(overview)
        }
        layers.append(
            line(
                id: "dirt-bound-country",
                admin: 2,
                minZoom: 0,
                dashed: false,
                color: "#7b4fa0",
                widths: [[2, 0.9], [6, 1.5], [10, 2.1]]
            )
        )
        layers.append(
            line(
                id: "dirt-bound-state",
                admin: 4,
                minZoom: 7,
                dashed: true,
                color: "#9a74b8",
                widths: [[7, 0.7], [10, 1.3]]
            )
        )
        return layers
    }

    static func admin1OverviewResourceURL() -> URL? {
        bundledJSONURL(resource: "ne-admin1-na", extensions: ["json", "geojson"])
    }

    static func admin1OverviewGeoJSONObject() -> Any? {
        guard let url = admin1OverviewResourceURL(),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return object
    }

    private static func bundledJSONURL(
        resource: String,
        extensions: [String] = ["json"]
    ) -> URL? {
        let bundles = [Bundle.main, Bundle(for: BundleToken.self)]
        for bundle in bundles {
            for ext in extensions {
                if let url = bundle.url(forResource: resource, withExtension: ext) {
                    return url
                }
            }
        }
        return nil
    }

    /// Outdoor glanceable type. Glyphs are Noto Sans Regular only — weight comes
    /// from size, near-black ink, and a thick cream halo on green/blue land.
    private static let typeInk = "#111418"
    private static let typeHalo = "#f8f4f0"
    private static let typeHaloWidth = 2.6

    private static func applyGlanceableType(
        paint: inout [String: Any],
        layout: inout [String: Any],
        color: String = typeInk,
        haloWidth: Double = typeHaloWidth,
        padding: Double = 0.5
    ) {
        paint["text-color"] = color
        paint["text-halo-color"] = typeHalo
        paint["text-halo-width"] = haloWidth
        paint["text-halo-blur"] = 0.15
        layout["text-padding"] = padding
        layout["text-font"] = ["Noto Sans Regular"]
    }

    private static func dirtBoundaryLabelLayers(from base: [String: Any]) -> [[String: Any]] {
        func label(
            id: String,
            admin: Int,
            minZoom: Double,
            maxZoom: Double?,
            sizeStops: [[Any]],
            sortKey: Int
        ) -> [String: Any] {
            var layer = base
            layer["id"] = id
            layer["minzoom"] = minZoom
            if let maxZoom {
                layer["maxzoom"] = maxZoom
            } else {
                layer.removeValue(forKey: "maxzoom")
            }
            layer["filter"] = ["==", "admin_level", admin]
            var layout = layer["layout"] as? [String: Any] ?? [:]
            layout["text-field"] = ["coalesce", ["get", "name_en"], ["get", "name"]]
            layout["text-size"] = ["stops": sizeStops]
            layout["symbol-sort-key"] = sortKey
            layout["text-max-width"] = 8
            var paint = layer["paint"] as? [String: Any] ?? [:]
            applyGlanceableType(paint: &paint, layout: &layout, haloWidth: 2.8, padding: 0.4)
            layer["layout"] = layout
            layer["paint"] = paint
            return layer
        }
        return [
            label(
                id: "dirt-bound-label-country",
                admin: 2,
                minZoom: 2,
                maxZoom: 6.01,
                sizeStops: [[2, 15], [4, 16]],
                sortKey: 20
            ),
            label(
                id: "dirt-bound-label-state",
                admin: 4,
                minZoom: 3,
                maxZoom: 12.5,
                sizeStops: [[3, 13], [5, 17], [8, 20], [11, 18]],
                sortKey: 100
            )
        ]
    }

    private static func retunePlaceLabel(_ layer: inout [String: Any]) {
        let id = layer["id"] as? String ?? ""
        guard id.hasPrefix("place_labels-") else { return }
        var layout = layer["layout"] as? [String: Any] ?? [:]
        var paint = layer["paint"] as? [String: Any] ?? [:]
        applyGlanceableType(paint: &paint, layout: &layout, haloWidth: 2.7)
        if id.contains("capital") {
            layer["minzoom"] = 2
            layout["text-size"] = ["stops": [[2, 14], [7, 18], [11, 22], [14, 26]]]
            layout["symbol-sort-key"] = 80
        } else if id.hasSuffix("-city") || id == "place_labels-city" {
            layer["minzoom"] = 4
            layout["text-size"] = ["stops": [[4, 13], [7, 17], [11, 21], [14, 24]]]
            layout["symbol-sort-key"] = 70
        } else if id.contains("town") {
            layer["minzoom"] = 7
            layout["text-size"] = ["stops": [[7, 13], [10, 17], [13, 20]]]
            layout["symbol-sort-key"] = 60
        } else if id.contains("village") {
            layer["minzoom"] = 10
            layout["text-size"] = ["stops": [[10, 13], [13, 16], [15, 18]]]
            layout["symbol-sort-key"] = 50
        } else if id.contains("hamlet") {
            layer["minzoom"] = 10
            layout["text-size"] = ["stops": [[10, 12], [13, 15], [15, 17]]]
            layout["symbol-sort-key"] = 40
        } else if id.contains("island") {
            layer["minzoom"] = 10
            layout["text-size"] = ["stops": [[10, 12], [13, 15]]]
            layout["symbol-sort-key"] = 45
        }
        layer["layout"] = layout
        layer["paint"] = paint
    }

    private static func dirtStreetNameLayers(from base: [String: Any]) -> [[String: Any]] {
        func street(id: String, kinds: [String], minZoom: Double, sizes: [[Any]]) -> [String: Any] {
            var layer = base
            layer["id"] = id
            layer["minzoom"] = minZoom
            layer["filter"] = ["in", "kind"] + kinds
            var layout = layer["layout"] as? [String: Any] ?? [:]
            var paint = layer["paint"] as? [String: Any] ?? [:]
            layout["text-size"] = ["stops": sizes]
            layout["symbol-placement"] = "line"
            applyGlanceableType(paint: &paint, layout: &layout, haloWidth: 2.5, padding: 1)
            layer["layout"] = layout
            layer["paint"] = paint
            return layer
        }
        return [
            street(
                id: "dirt-label-street-major",
                kinds: ["motorway", "trunk", "primary", "secondary"],
                minZoom: 10,
                sizes: [[10, 12], [13, 15], [16, 18]]
            ),
            street(
                id: "label-street-centre-12",
                kinds: [
                    "tertiary", "unclassified", "residential",
                    "pedestrian", "living_street", "service", "road"
                ],
                minZoom: 11,
                sizes: [[11, 12], [14, 15], [16, 17]]
            )
        ]
    }

    private static func retunePathLabel(_ layer: inout [String: Any]) {
        let id = layer["id"] as? String ?? ""
        if id == "label-path-bottom-12" {
            layer["minzoom"] = 11
            var layout = layer["layout"] as? [String: Any] ?? [:]
            var paint = layer["paint"] as? [String: Any] ?? [:]
            layout["text-size"] = ["stops": [[11, 11], [14, 14], [16, 16]]]
            applyGlanceableType(paint: &paint, layout: &layout, haloWidth: 2.4, padding: 1)
            layer["layout"] = layout
            layer["paint"] = paint
            return
        }
        guard id == "streets_polygons_labels-name-13" else { return }
        var layout = layer["layout"] as? [String: Any] ?? [:]
        var paint = layer["paint"] as? [String: Any] ?? [:]
        layout["text-size"] = ["stops": [[13, 12], [16, 16]]]
        applyGlanceableType(paint: &paint, layout: &layout, haloWidth: 2.4, padding: 1)
        layer["layout"] = layout
        layer["paint"] = paint
    }

    private static func retuneWaterLabel(_ layer: inout [String: Any]) {
        let id = layer["id"] as? String ?? ""
        let isWaterText = id.contains("water_polygons_labels") || id.hasPrefix("label-waterway")
        guard isWaterText else { return }
        var layout = layer["layout"] as? [String: Any] ?? [:]
        var paint = layer["paint"] as? [String: Any] ?? [:]
        applyGlanceableType(
            paint: &paint,
            layout: &layout,
            color: "#1a4d68",
            haloWidth: 2.4,
            padding: 1
        )
        if let size = layout["text-size"] as? [String: Any],
           let stops = size["stops"] as? [[Any]],
           let first = stops.first, first.count == 2,
           let zoom = first[0] as? Int, zoom >= 12 {
            layout["text-size"] = ["stops": [[zoom, 12], [20, 22]]]
        }
        layer["layout"] = layout
        layer["paint"] = paint
    }

    private static func rgb(from hex: String) -> (r: Double, g: Double, b: Double)? {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    private static func hsl(from rgb: (r: Double, g: Double, b: Double)) -> (h: Double, s: Double, l: Double) {
        let maxV = max(rgb.r, rgb.g, rgb.b)
        let minV = min(rgb.r, rgb.g, rgb.b)
        let l = (maxV + minV) / 2
        let d = maxV - minV
        guard d > 0 else { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        let h: Double
        if maxV == rgb.r {
            h = (rgb.g - rgb.b) / d + (rgb.g < rgb.b ? 6 : 0)
        } else if maxV == rgb.g {
            h = (rgb.b - rgb.r) / d + 2
        } else {
            h = (rgb.r - rgb.g) / d + 4
        }
        return (h * 60, s, l)
    }

    private static func rgb(from hsl: (h: Double, s: Double, l: Double)) -> (r: Double, g: Double, b: Double) {
        let c = (1 - abs(2 * hsl.l - 1)) * hsl.s
        let x = c * (1 - abs((hsl.h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = hsl.l - c / 2
        let rgb: (Double, Double, Double)
        switch hsl.h {
        case ..<60: rgb = (c, x, 0)
        case ..<120: rgb = (x, c, 0)
        case ..<180: rgb = (0, c, x)
        case ..<240: rgb = (0, x, c)
        case ..<300: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        return (rgb.0 + m, rgb.1 + m, rgb.2 + m)
    }

    private static func hexString(from rgb: (r: Double, g: Double, b: Double)) -> String {
        func byte(_ v: Double) -> Int { min(255, max(0, Int((v * 255).rounded()))) }
        return String(format: "#%02x%02x%02x", byte(rgb.r), byte(rgb.g), byte(rgb.b))
    }
}
