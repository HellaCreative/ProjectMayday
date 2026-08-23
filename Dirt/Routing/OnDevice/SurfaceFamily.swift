import Foundation

/// Phase E1 read-time surface family map — must match
/// `scripts/pack-fabric/routing/lib/surface-family.js` and pack `enumsJson.surfaceFamilyMap`.
nonisolated enum SurfaceFamily: String, Sendable {
    case paved
    case gravel
    case loose
    case unknown
}

nonisolated enum SurfaceFamilyStats {
    /// Canonical fallback when a v2 pack has no `surfaceFamilyMap` in enums.
    static let defaultMap: [String: SurfaceFamily] = [
        "asphalt": .paved, "paved": .paved, "concrete": .paved, "chipseal": .paved,
        "paving_stones": .paved, "cobblestone": .paved, "sett": .paved, "brick": .paved,
        "metal": .paved, "wood": .paved,
        "gravel": .gravel, "compacted": .gravel, "fine_gravel": .gravel,
        "pebblestone": .gravel, "unpaved": .gravel,
        "dirt": .loose, "ground": .loose, "earth": .loose, "grass": .loose,
        "mud": .loose, "sand": .loose, "rock": .loose, "natural": .loose, "woodchips": .loose
    ]

    static func family(
        of surfaceLeaf: String?,
        map: [String: SurfaceFamily] = defaultMap
    ) -> SurfaceFamily {
        guard let raw = surfaceLeaf?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return .unknown }
        return map[raw.lowercased()] ?? .unknown
    }

    /// Honest Dirt% = Loose/technical + Unknown. Paved and Gravel do not count as dirt.
    struct Percents: Sendable, Equatable {
        var dirtPercent: Int
        var pavedPercent: Int
        var gravelPercent: Int
        var unknownSurfacePercent: Int
    }

    static func honestPercents(
        rows: [(meters: Double, surfaceLeaf: String?)],
        distanceMeters: Double,
        familyMap: [String: SurfaceFamily] = defaultMap
    ) -> Percents {
        var pavedM = 0.0
        var gravelM = 0.0
        var looseM = 0.0
        var unknownM = 0.0
        for row in rows {
            guard row.meters > 0 else { continue }
            switch family(of: row.surfaceLeaf, map: familyMap) {
            case .paved: pavedM += row.meters
            case .gravel: gravelM += row.meters
            case .loose: looseM += row.meters
            case .unknown: unknownM += row.meters
            }
        }
        let dirtM = looseM + unknownM
        let total = distanceMeters > 0 ? distanceMeters : (pavedM + gravelM + looseM + unknownM)
        func pct(_ m: Double) -> Int {
            guard total > 0 else { return 0 }
            return Int((m / total * 100).rounded())
        }
        return Percents(
            dirtPercent: pct(dirtM),
            pavedPercent: pct(pavedM),
            gravelPercent: pct(gravelM),
            unknownSurfacePercent: pct(unknownM)
        )
    }

    static func parseFamilyMap(_ raw: Any?) -> [String: SurfaceFamily] {
        guard let dict = raw as? [String: Any] else { return defaultMap }
        var out: [String: SurfaceFamily] = [:]
        for (key, value) in dict {
            let name = "\(value)".lowercased()
            if let fam = SurfaceFamily(rawValue: name) {
                out[key.lowercased()] = fam
            }
        }
        return out.isEmpty ? defaultMap : out
    }
}
