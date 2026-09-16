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
              var layers = root["layers"] as? [[String: Any]]
        else { return nil }

        for index in layers.indices {
            let id = (layers[index]["id"] as? String ?? "").lowercased()
            var paint = layers[index]["paint"] as? [String: Any] ?? [:]

            // Rich palette, ~15% more saturated (HSL S *1.15, clamped) than the
            // original landcover/road hand-picked values below each comment.
            if rich, id == "background" {
                paint["background-color"] = "#f5ead9" // was #f3eadb
            } else if rich, id.contains("water") {
                if paint["fill-color"] != nil { paint["fill-color"] = "#8ac9f6" } // was #91c8ef
                if paint["line-color"] != nil { paint["line-color"] = "#51abe9" } // was #5ba9df
            } else if rich, id.contains("forest") {
                paint["fill-color"] = "#94d56d" // was #96ce74
            } else if rich, id.contains("orchard") || id.contains("vineyard") || id.contains("scrub") {
                paint["fill-color"] = "#a3d97b" // was #a4d381
            } else if rich, id.contains("park") || id.contains("heath") || id.contains("meadow") {
                paint["fill-color"] = "#b1e28a" // was #b2dc90
            } else if rich, id.contains("grass") || id.contains("recreation_ground")
                        || id.contains("village_green") || id.contains("golf_course") {
                paint["fill-color"] = "#b9e493" // was #b9df98
            } else if rich, id.contains("farmland") || id.contains("farmyard") {
                paint["fill-color"] = "#eecb87" // was #e7c98e
            } else if rich, id.contains("residential-fill") {
                paint["fill-color"] = "#f0ddc7" // was #edddca
            } else if rich, id.contains("retail-fill") || id.contains("commercial-fill") {
                paint["fill-color"] = "#f3bbb5" // was #efbeb9
            } else if rich, id.contains("industrial-fill") || id.contains("construction-fill") {
                paint["fill-color"] = "#f8e09a" // was #f2dda0
            } else if rich, id.contains("eduhospital-fill") || id.contains("schoolyard-fill") {
                paint["fill-color"] = "#e4d3f3" // was #e4d5f1
            } else if rich, id.contains("beach-fill") || id.contains("sand-fill") {
                paint["fill-color"] = "#f8e486" // was #f1df8d
            }

            if paint["line-color"] != nil, id.contains("highway") {
                let isCasing = id.contains("casing") || id.contains("outline")
                if isCasing {
                    if id.contains("motorway") || id.contains("trunk") {
                        paint["line-color"] = rich ? "#a82e1f" : "#6f4d49" // rich was #9f3528
                    } else if id.contains("primary") {
                        paint["line-color"] = rich ? "#b7511a" : "#805c50" // rich was #ad5424
                    } else if id.contains("secondary") {
                        paint["line-color"] = rich ? "#ae7a1b" : "#79684a" // rich was #a47725
                    } else if id.contains("tertiary") {
                        paint["line-color"] = rich ? "#977b26" : "#6f6d50" // rich was #90772d
                    } else if id.contains("service") || id.contains("unclassified")
                                || id.contains("living_street") {
                        paint["line-color"] = rich ? "#757066" : "#77736b" // rich was #747067
                    }
                } else if rich {
                    if id.contains("motorway") || id.contains("trunk") {
                        paint["line-color"] = "#f15630" // was #e45e3d
                    } else if id.contains("primary") {
                        paint["line-color"] = "#fc8624" // was #ee8732
                    } else if id.contains("secondary") {
                        paint["line-color"] = "#fcb841" // was #f0b54d
                    } else if id.contains("tertiary") {
                        paint["line-color"] = "#f2c955" // was #e8c45f
                    }
                }
            }

            layers[index]["paint"] = paint
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
                "dirt-shortbread-\(rich ? "rich" : "standard")-\(tileSource.styleCacheKey).json"
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
