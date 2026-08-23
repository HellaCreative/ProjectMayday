import Foundation

/// Phase E2 read-time road tiers — must match `road-tier.js` + pack `enumsJson.roadTierMap`.
nonisolated enum RoadTier: String, Sendable {
    case motorway
    case trunk
    case arterial
    case collector
    case localPaved = "local_paved"
    case destination
    case service
    case adventure
    case unknown
}

nonisolated enum RoadTierStats {
    static let defaultMap: [String: RoadTier] = [
        "motorway": .motorway, "motorway_link": .motorway,
        "trunk": .trunk, "trunk_link": .trunk,
        "primary": .arterial, "primary_link": .arterial,
        "secondary": .collector, "secondary_link": .collector,
        "tertiary": .localPaved, "tertiary_link": .localPaved,
        "unclassified": .localPaved, "unclassified_link": .localPaved,
        "residential": .destination, "living_street": .destination,
        "service": .service,
        "track": .adventure, "path": .adventure,
        "unknown": .unknown
    ]

    static let cleanTierCost: [RoadTier: Double] = [
        .collector: 0.86,
        .localPaved: 0.92,
        .arterial: 5.5,
        .service: 2.8,
        .destination: 1.15,
        .trunk: 16.0,
        .motorway: 70.0,
        .adventure: 120.0,
        .unknown: 2.2
    ]

    static let cleanFamilyCost: [SurfaceFamily: Double] = [
        .paved: 1.0,
        .gravel: 14.0,
        .loose: 90.0,
        .unknown: 1.05
    ]

    static func tier(
        of roadClassLeaf: String?,
        map: [String: RoadTier] = defaultMap
    ) -> RoadTier {
        guard let raw = roadClassLeaf?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return .unknown }
        return map[raw.lowercased()] ?? .unknown
    }

    static func parseTierMap(_ raw: Any?) -> [String: RoadTier] {
        guard let dict = raw as? [String: Any] else { return defaultMap }
        var out: [String: RoadTier] = [:]
        for (key, value) in dict {
            let name = "\(value)".lowercased()
            if let tier = RoadTier(rawValue: name) {
                out[key.lowercased()] = tier
            }
        }
        return out.isEmpty ? defaultMap : out
    }

    static func isPavedCapable(_ tier: RoadTier) -> Bool {
        switch tier {
        case .motorway, .trunk, .arterial, .collector, .localPaved: return true
        default: return false
        }
    }

    /// Clean leaf passability — mirrors `isBlockedForCleanLeaf` in road-tier.js.
    static func isBlockedForCleanLeaf(
        family: SurfaceFamily,
        tier: RoadTier,
        pavedOnly: Bool,
        isEndpointEdge: Bool
    ) -> Bool {
        if isEndpointEdge { return false }
        if tier == .destination { return true }
        if tier == .adventure { return pavedOnly }
        if pavedOnly {
            switch family {
            case .paved: return false
            case .gravel, .loose: return true
            case .unknown: return !isPavedCapable(tier)
            }
        }
        if family == .loose, !isPavedCapable(tier) { return true }
        return false
    }

    static func cleanLeafCostMult(tier: RoadTier, family: SurfaceFamily) -> Double {
        let t = cleanTierCost[tier] ?? cleanTierCost[.unknown]!
        let f = cleanFamilyCost[family] ?? cleanFamilyCost[.unknown]!
        return t * f
    }

    static func cleanLeafHighwayAvoidMult(
        tier: RoadTier,
        metersFromStart: Double,
        metersToDestination: Double,
        startOnHighway: Bool,
        endOnHighway: Bool
    ) -> Double {
        guard tier == .motorway || tier == .trunk else { return 1 }
        let join = 6000.0
        let near =
            (endOnHighway && metersToDestination < join) ||
            (startOnHighway && metersFromStart < join)
        if near { return 1 }
        return tier == .motorway ? 1.8 : 1.35
    }
}
