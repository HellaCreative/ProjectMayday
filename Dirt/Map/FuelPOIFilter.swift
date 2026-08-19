import Foundation

/// Motorcycle-usable fuel. Drops truck-only, cardlock/bulk, and known-closed
/// OSM stations. Bare `amenity=fuel` with no extra tags is kept (normal retail).
///
/// Pack-time twin: `scripts/pack-fabric/poi/fuel-filter.js`
enum FuelPOIFilter {
    struct Input: Sendable {
        var name: String? = nil
        var brand: String? = nil
        var openingHours: String? = nil
        /// OSM tags when present (pack extract). CDN chunks are name/brand only.
        var tags: [String: String] = [:]
    }

    enum Rejection: String, Sendable {
        case closed
        case truckOnly
        case privateAccess
        case dieselOnly
        case bulkOrCardlock
    }

    static func isMotorcycleUsable(_ input: Input) -> Bool {
        rejection(for: input) == nil
    }

    static func rejection(for input: Input) -> Rejection? {
        let tags = normalizedTags(input.tags)
        if isKnownClosed(openingHours: input.openingHours, tags: tags) {
            return .closed
        }
        if isTruckOnly(tags) {
            return .truckOnly
        }
        if isPrivateOrGated(tags) {
            return .privateAccess
        }
        if isDieselOnlyDepot(tags) {
            return .dieselOnly
        }
        if isBulkOrCardlockName(input.name, input.brand, tags: tags) {
            return .bulkOrCardlock
        }
        return nil
    }

    // MARK: - Rules

    private static func isKnownClosed(openingHours: String?, tags: [String: String]) -> Bool {
        if tagYes(tags["disused"]) || tagYes(tags["abandoned"]) { return true }
        if let amenity = tags["amenity"], amenity == "disused" || amenity == "abandoned" {
            return true
        }
        if tags["disused:amenity"] == "fuel" || tags["abandoned:amenity"] == "fuel" {
            return true
        }
        let hours = (openingHours ?? tags["opening_hours"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return hours == "closed" || hours == "off"
    }

    /// `hgv=designated` is truck-only. `hgv=yes` is not: many retail stations serve trucks.
    private static func isTruckOnly(_ tags: [String: String]) -> Bool {
        let hgv = tags["hgv"] ?? ""
        if hgv == "designated" || hgv == "only" { return true }
        if tagYes(tags["fuel:hgv_diesel"]) && !hasGasolineYes(tags) { return true }
        if tags["capacity:hgv"] != nil && isDieselWithoutGasoline(tags) { return true }
        return false
    }

    private static func isPrivateOrGated(_ tags: [String: String]) -> Bool {
        switch tags["access"] {
        case "private", "customers", "no", "permit", "military":
            return true
        default:
            return false
        }
    }

    /// Diesel-only only when gasoline is explicitly absent/no, not when tagging is sparse.
    private static func isDieselOnlyDepot(_ tags: [String: String]) -> Bool {
        if hasGasolineYes(tags) { return false }
        if tagNo(tags["fuel:gasoline"]) || tagNo(tags["fuel:petrol"]) {
            return tagYes(tags["fuel:diesel"]) || tagYes(tags["fuel:hgv_diesel"])
        }
        if hasExplicitOctaneNo(tags) && !hasOctaneYes(tags) {
            return tagYes(tags["fuel:diesel"]) || tagYes(tags["fuel:hgv_diesel"])
        }
        return false
    }

    private static func isBulkOrCardlockName(
        _ name: String?,
        _ brand: String?,
        tags: [String: String]
    ) -> Bool {
        let blobs = [name, brand, tags["name"], tags["brand"], tags["operator"], tags["operator:type"]]
            .compactMap { $0?.lowercased() }
        let text = blobs.joined(separator: " ")
        guard !text.isEmpty else { return false }
        if text.range(of: #"card[\s\-]?lock"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"key[\s\-]?lock"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"\bfleet\s+(fuel|card)"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"\bbulk\s+(fuel|plant|station|terminal|depot|card)"#, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"\bbulk\b"#, options: .regularExpression) != nil,
           text.range(of: #"\b(fuel|gas|petrol|diesel|cardlock)\b"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    // MARK: - Tag helpers

    private static let gasolineKeys = [
        "fuel:gasoline", "fuel:petrol", "fuel:e10", "fuel:e85",
        "fuel:octane_87", "fuel:octane_89", "fuel:octane_91", "fuel:octane_92",
        "fuel:octane_94", "fuel:octane_95", "fuel:octane_98"
    ]

    private static func hasGasolineYes(_ tags: [String: String]) -> Bool {
        gasolineKeys.contains { tagYes(tags[$0]) }
    }

    private static func hasOctaneYes(_ tags: [String: String]) -> Bool {
        gasolineKeys.contains { $0.hasPrefix("fuel:octane_") && tagYes(tags[$0]) }
    }

    private static func hasExplicitOctaneNo(_ tags: [String: String]) -> Bool {
        gasolineKeys.contains { $0.hasPrefix("fuel:octane_") && tagNo(tags[$0]) }
    }

    private static func isDieselWithoutGasoline(_ tags: [String: String]) -> Bool {
        (tagYes(tags["fuel:diesel"]) || tagYes(tags["fuel:hgv_diesel"])) && !hasGasolineYes(tags)
    }

    private static func tagYes(_ raw: String?) -> Bool {
        guard let value = raw?.lowercased() else { return false }
        return value == "yes" || value == "true" || value == "1"
    }

    private static func tagNo(_ raw: String?) -> Bool {
        guard let value = raw?.lowercased() else { return false }
        return value == "no" || value == "false" || value == "0"
    }

    private static func normalizedTags(_ tags: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(tags.count)
        for (key, value) in tags {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            out[key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = trimmed.lowercased()
        }
        return out
    }
}
