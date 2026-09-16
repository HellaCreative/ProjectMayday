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
    static let generatedStyleRevision = "admin-v1"

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
        guard let source = Bundle.main.url(forResource: "shortbread-style", withExtension: "json"),
              let data = try? Data(contentsOf: source),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let incoming = root["layers"] as? [[String: Any]]
        else { return nil }

        var layers: [[String: Any]] = []
        layers.reserveCapacity(incoming.count + 4)
        for var layer in incoming {
            let id = (layer["id"] as? String ?? "").lowercased()
            var paint = layer["paint"] as? [String: Any] ?? [:]

            if rich {
                applyRichLandcover(id: id, paint: &paint)
            }
            if paint["line-color"] != nil, id.contains("highway") {
                applyHighwayColors(id: id, rich: rich, paint: &paint)
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
            retunePlaceLabel(&layer)
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

// MARK: - Rich saturation + admin labels

extension MapStyleCatalog {
    /// Pre-boost landcover/road fills. Rich applies `×1.15` HSL saturation at generate time.
    private static let richBase: [String: String] = [
        "background": "#f3eadb",
        "water-fill": "#91c8ef",
        "water-line": "#5ba9df",
        "forest": "#96ce74",
        "orchard": "#a4d381",
        "park": "#b2dc90",
        "grass": "#b9df98",
        "farmland": "#e7c98e",
        "residential": "#edddca",
        "retail": "#efbeb9",
        "industrial": "#f2dda0",
        "edu": "#e4d5f1",
        "beach": "#f1df8d",
        "mw-fill": "#e45e3d",
        "pri-fill": "#ee8732",
        "sec-fill": "#f0b54d",
        "ter-fill": "#e8c45f",
        "mw-casing": "#9f3528",
        "pri-casing": "#ad5424",
        "sec-casing": "#a47725",
        "ter-casing": "#90772d",
        "svc-casing": "#747067"
    ]

    static func boostedSaturationHex(_ hex: String, factor: Double = 1.15) -> String {
        guard let rgb = rgb(from: hex) else { return hex }
        var hsl = hsl(from: rgb)
        hsl.s = min(1, hsl.s * factor)
        return hexString(from: rgb(from: hsl))
    }

    private static func applyRichLandcover(id: String, paint: inout [String: Any]) {
        if id == "background" {
            paint["background-color"] = boostedSaturationHex(richBase["background"]!)
        } else if id.contains("water") {
            if paint["fill-color"] != nil {
                paint["fill-color"] = boostedSaturationHex(richBase["water-fill"]!)
            }
            if paint["line-color"] != nil {
                paint["line-color"] = boostedSaturationHex(richBase["water-line"]!)
            }
        } else if id.contains("forest") {
            paint["fill-color"] = boostedSaturationHex(richBase["forest"]!)
        } else if id.contains("orchard") || id.contains("vineyard") || id.contains("scrub") {
            paint["fill-color"] = boostedSaturationHex(richBase["orchard"]!)
        } else if id.contains("park") || id.contains("heath") || id.contains("meadow") {
            paint["fill-color"] = boostedSaturationHex(richBase["park"]!)
        } else if id.contains("grass") || id.contains("recreation_ground")
                    || id.contains("village_green") || id.contains("golf_course") {
            paint["fill-color"] = boostedSaturationHex(richBase["grass"]!)
        } else if id.contains("farmland") || id.contains("farmyard") {
            paint["fill-color"] = boostedSaturationHex(richBase["farmland"]!)
        } else if id.contains("residential-fill") {
            paint["fill-color"] = boostedSaturationHex(richBase["residential"]!)
        } else if id.contains("retail-fill") || id.contains("commercial-fill") {
            paint["fill-color"] = boostedSaturationHex(richBase["retail"]!)
        } else if id.contains("industrial-fill") || id.contains("construction-fill") {
            paint["fill-color"] = boostedSaturationHex(richBase["industrial"]!)
        } else if id.contains("eduhospital-fill") || id.contains("schoolyard-fill") {
            paint["fill-color"] = boostedSaturationHex(richBase["edu"]!)
        } else if id.contains("beach-fill") || id.contains("sand-fill") {
            paint["fill-color"] = boostedSaturationHex(richBase["beach"]!)
        }
    }

    private static func applyHighwayColors(id: String, rich: Bool, paint: inout [String: Any]) {
        let isCasing = id.contains("casing") || id.contains("outline")
        if isCasing {
            if id.contains("motorway") || id.contains("trunk") {
                paint["line-color"] = rich ? boostedSaturationHex(richBase["mw-casing"]!) : "#6f4d49"
            } else if id.contains("primary") {
                paint["line-color"] = rich ? boostedSaturationHex(richBase["pri-casing"]!) : "#805c50"
            } else if id.contains("secondary") {
                paint["line-color"] = rich ? boostedSaturationHex(richBase["sec-casing"]!) : "#79684a"
            } else if id.contains("tertiary") {
                paint["line-color"] = rich ? boostedSaturationHex(richBase["ter-casing"]!) : "#6f6d50"
            } else if id.contains("service") || id.contains("unclassified")
                        || id.contains("living_street") {
                paint["line-color"] = rich ? boostedSaturationHex(richBase["svc-casing"]!) : "#77736b"
            }
        } else if rich {
            if id.contains("motorway") || id.contains("trunk") {
                paint["line-color"] = boostedSaturationHex(richBase["mw-fill"]!)
            } else if id.contains("primary") {
                paint["line-color"] = boostedSaturationHex(richBase["pri-fill"]!)
            } else if id.contains("secondary") {
                paint["line-color"] = boostedSaturationHex(richBase["sec-fill"]!)
            } else if id.contains("tertiary") {
                paint["line-color"] = boostedSaturationHex(richBase["ter-fill"]!)
            }
        }
    }

    /// Tile lines start at z7 (Shortbread has no province/state geometry below that).
    /// Bundled `RegionPolygons` outlines cover idle/continental zoom.
    private static func dirtBoundaryLineLayers(from base: [String: Any]) -> [[String: Any]] {
        func line(id: String, admin: Int, dashed: Bool, color: String) -> [String: Any] {
            var layer = base
            layer["id"] = id
            layer["minzoom"] = 7
            layer["filter"] = [
                "all",
                ["==", "admin_level", admin],
                ["!=", "maritime", true]
            ]
            var paint = layer["paint"] as? [String: Any] ?? [:]
            paint["line-color"] = color
            paint["line-opacity"] = 0.92
            paint["line-width"] = [
                "stops": [[7, dashed ? 0.8 : 1.1], [10, dashed ? 1.6 : 2.2]]
            ]
            if dashed {
                paint["line-dasharray"] = [4, 3]
            } else {
                paint.removeValue(forKey: "line-dasharray")
            }
            layer["paint"] = paint
            return layer
        }
        return [
            line(id: "dirt-bound-country", admin: 2, dashed: false, color: "#3a424c"),
            line(id: "dirt-bound-state", admin: 4, dashed: true, color: "#5a6470")
        ]
    }

    private static func dirtBoundaryLabelLayers(from base: [String: Any]) -> [[String: Any]] {
        func label(id: String, admin: Int, minZoom: Double, maxZoom: Double?, sizeStops: [[Any]]) -> [String: Any] {
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
            layout["text-padding"] = 4
            layout["symbol-sort-key"] = ["-", ["get", "way_area"]]
            layout["text-font"] = ["Noto Sans Regular"]
            layer["layout"] = layout
            var paint = layer["paint"] as? [String: Any] ?? [:]
            paint["text-color"] = "#1a1f24"
            paint["text-halo-color"] = "#f8f4f0"
            paint["text-halo-width"] = 1.8
            paint["text-halo-blur"] = 0.4
            layer["paint"] = paint
            return layer
        }
        return [
            label(
                id: "dirt-bound-label-country",
                admin: 2,
                minZoom: 2,
                maxZoom: 6.01,
                sizeStops: [[2, 13], [8, 22]]
            ),
            label(
                id: "dirt-bound-label-state",
                admin: 4,
                minZoom: 3,
                maxZoom: nil,
                sizeStops: [[3, 12], [10, 18]]
            )
        ]
    }

    private static func retunePlaceLabel(_ layer: inout [String: Any]) {
        let id = layer["id"] as? String ?? ""
        guard id.hasPrefix("place_labels-") else { return }
        var layout = layer["layout"] as? [String: Any] ?? [:]
        var paint = layer["paint"] as? [String: Any] ?? [:]
        paint["text-color"] = "#1a1f24"
        paint["text-halo-color"] = "#f8f4f0"
        paint["text-halo-width"] = 1.6
        if id.contains("capital") {
            layer["minzoom"] = 3
            layout["text-size"] = ["stops": [[3, 14], [12, 22]]]
        } else if id.hasSuffix("-city") || id == "place_labels-city" {
            layer["minzoom"] = 5
            layout["text-size"] = ["stops": [[5, 13], [12, 20]]]
        } else if id.contains("town") {
            layer["minzoom"] = 7
            layout["text-size"] = ["stops": [[7, 12], [12, 16]]]
        } else if id.contains("village") {
            layer["minzoom"] = 10
            layout["text-size"] = ["stops": [[10, 11], [13, 14]]]
        } else if id.contains("hamlet") {
            layer["minzoom"] = 11
            layout["text-size"] = ["stops": [[11, 10], [14, 13]]]
        } else if id.contains("island") {
            layer["minzoom"] = 10
            layout["text-size"] = ["stops": [[10, 11], [13, 14]]]
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
