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
    static func styleURL(for id: MapStyleID = selectedID) -> URL {
        switch id {
        case .shortbread:
            return bundledStyleURL(resource: "shortbread-style") ?? AppConfig.mapStyleURL
        case .shortbreadRich:
            return generatedRichStyleURL()
                ?? bundledStyleURL(resource: "shortbread-rich-style")
                ?? bundledStyleURL(resource: "shortbread-style")
                ?? AppConfig.mapStyleURL
        }
    }

    /// Rich is derived from the bundled Shortbread style so both choices stay
    /// structurally identical while Rich gets the saturated outdoor palette the
    /// product promises. This also avoids silently falling back to Standard when
    /// a second, very large style JSON is omitted from the app bundle.
    private static func generatedRichStyleURL() -> URL? {
        guard let source = Bundle.main.url(forResource: "shortbread-style", withExtension: "json"),
              let data = try? Data(contentsOf: source),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var layers = root["layers"] as? [[String: Any]]
        else { return nil }

        for index in layers.indices {
            let id = (layers[index]["id"] as? String ?? "").lowercased()
            var paint = layers[index]["paint"] as? [String: Any] ?? [:]

            if id == "background" {
                paint["background-color"] = "#f3eadb"
            } else if id.contains("water") {
                if paint["fill-color"] != nil { paint["fill-color"] = "#91c8ef" }
                if paint["line-color"] != nil { paint["line-color"] = "#5ba9df" }
            } else if id.contains("forest") {
                paint["fill-color"] = "#96ce74"
            } else if id.contains("orchard") || id.contains("vineyard") || id.contains("scrub") {
                paint["fill-color"] = "#a4d381"
            } else if id.contains("park") || id.contains("heath") || id.contains("meadow") {
                paint["fill-color"] = "#b2dc90"
            } else if id.contains("grass") || id.contains("recreation_ground")
                        || id.contains("village_green") || id.contains("golf_course") {
                paint["fill-color"] = "#b9df98"
            } else if id.contains("farmland") || id.contains("farmyard") {
                paint["fill-color"] = "#e7c98e"
            } else if id.contains("residential-fill") {
                paint["fill-color"] = "#edddca"
            } else if id.contains("retail-fill") || id.contains("commercial-fill") {
                paint["fill-color"] = "#efbeb9"
            } else if id.contains("industrial-fill") || id.contains("construction-fill") {
                paint["fill-color"] = "#f2dda0"
            } else if id.contains("eduhospital-fill") || id.contains("schoolyard-fill") {
                paint["fill-color"] = "#e4d5f1"
            } else if id.contains("beach-fill") || id.contains("sand-fill") {
                paint["fill-color"] = "#f1df8d"
            }

            if paint["line-color"] != nil, id.contains("highway") {
                if id.contains("motorway") || id.contains("trunk") {
                    paint["line-color"] = "#e45e3d"
                } else if id.contains("primary") {
                    paint["line-color"] = "#ee8732"
                } else if id.contains("secondary") {
                    paint["line-color"] = "#f0b54d"
                } else if id.contains("tertiary") {
                    paint["line-color"] = "#f0ca70"
                }
            }

            layers[index]["paint"] = paint
        }

        root["name"] = "DIRT Rich Shortbread"
        root["layers"] = layers
        if (root["sprite"] as? String) == "DIRT_SPRITE_PLACEHOLDER",
           let spriteBase = bundledSpriteBaseURL() {
            root["sprite"] = spriteBase.absoluteString
        }
        guard let richData = try? JSONSerialization.data(withJSONObject: root) else { return nil }

        let destination = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dirt-shortbread-rich-style.json")
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
