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
        .collector: 0.92,
        .localPaved: 1.0,
        .arterial: 0.96,
        .service: 2.8,
        .destination: 1.15,
        .trunk: 1.0,
        .motorway: 1.0,
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

    static func isCleanPavementEligible(family: SurfaceFamily, tier: RoadTier) -> Bool {
        switch family {
        case .paved: return true
        case .unknown: return isPavedCapable(tier)
        case .gravel, .loose: return false
        }
    }

    /// Clean leaf passability — mirrors `isBlockedForCleanLeaf` in road-tier.js.
    static func isBlockedForCleanLeaf(
        family: SurfaceFamily,
        tier: RoadTier,
        pavedOnly: Bool,
        isEndpointEdge: Bool
    ) -> Bool {
        if pavedOnly, !isCleanPavementEligible(family: family, tier: tier) { return true }
        if isEndpointEdge { return false }
        if tier == .destination { return true }
        if tier == .adventure { return pavedOnly }
        if pavedOnly {
            return false
        }
        if family == .loose, !isPavedCapable(tier) { return true }
        return false
    }

    static func cleanLeafCostMult(tier: RoadTier, family: SurfaceFamily) -> Double {
        let t = cleanTierCost[tier] ?? cleanTierCost[.unknown]!
        let f = cleanFamilyCost[family] ?? cleanFamilyCost[.unknown]!
        return t * f
    }

    // Clean motorway policy. Avoidance is the default internal state; the rider-facing
    // "Allow motorways" switch disables it. Soft costs only; never delete edges.
    static let e4AvoidMotorwayMult = 40.0
    static let e4AvoidTrunkMult = 18.0
    static let e4PreferBackArterialMult = 4.5
    static let e4PreferBackCollectorMult = 0.82
    static let e4HighwayJoinMeters = 6000.0

    static func e4AvoidMotorwaysMult(
        tier: RoadTier,
        enabled: Bool,
        metersFromStart: Double,
        metersToDestination: Double,
        startOnHighway: Bool,
        endOnHighway: Bool
    ) -> Double {
        guard enabled else { return 1 }
        guard tier == .motorway || tier == .trunk else { return 1 }
        let near =
            (endOnHighway && metersToDestination < e4HighwayJoinMeters) ||
            (startOnHighway && metersFromStart < e4HighwayJoinMeters)
        if near { return 1 }
        return tier == .motorway ? e4AvoidMotorwayMult : e4AvoidTrunkMult
    }

    /// Prefer back roads: penalize arterial; mild collector preference. Never excludes.
    static func e4PreferBackRoadsMult(tier: RoadTier, enabled: Bool) -> Double {
        guard enabled else { return 1 }
        switch tier {
        case .arterial: return e4PreferBackArterialMult
        case .collector: return e4PreferBackCollectorMult
        default: return 1
        }
    }

    static func e4LeafCostMult(
        tier: RoadTier,
        avoidMotorways: Bool,
        preferBackRoads: Bool,
        metersFromStart: Double,
        metersToDestination: Double,
        startOnHighway: Bool,
        endOnHighway: Bool
    ) -> Double {
        e4AvoidMotorwaysMult(
            tier: tier,
            enabled: avoidMotorways,
            metersFromStart: metersFromStart,
            metersToDestination: metersToDestination,
            startOnHighway: startOnHighway,
            endOnHighway: endOnHighway
        ) * e4PreferBackRoadsMult(tier: tier, enabled: preferBackRoads)
    }

    /// Clean-only motorway policy. Primary and secondary roads remain ordinary
    /// pavement; only motorway/trunk receive the default soft avoidance.
    static func e4Flags(
        for profile: RouteProfile,
        avoidMotorways: Bool,
        preferBackRoads: Bool
    ) -> (avoidMotorways: Bool, preferBackRoads: Bool) {
        if profile != .cleanest {
            return (false, false)
        }
        return (avoidMotorways, false)
    }
}
