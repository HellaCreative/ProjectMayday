import Foundation

/// Phase E1 read-time surface family map — must match
/// `scripts/pack-fabric/routing/lib/surface-family.js` and pack `enumsJson.surfaceFamilyMap`.
nonisolated enum SurfaceFamily: String, Codable, CaseIterable, Hashable, Sendable {
    case paved
    case gravel
    case loose
    case unknown
}

/// One rider-facing surface composition shared by map paint and every route
/// summary. Known dirt includes gravel + loose; unknown stays separate.
struct RouteSurfaceComposition: Equatable, Sendable {
    var pavedMeters = 0.0
    var gravelMeters = 0.0
    var looseMeters = 0.0
    var unknownMeters = 0.0

    var totalMeters: Double { pavedMeters + gravelMeters + looseMeters + unknownMeters }
    var dirtMeters: Double { gravelMeters + looseMeters }

    var dirtPercent: Int { percent(dirtMeters) }
    var pavedPercent: Int { percent(pavedMeters) }
    var gravelPercent: Int { percent(gravelMeters) }
    var loosePercent: Int { percent(looseMeters) }
    var unknownPercent: Int { percent(unknownMeters) }

    func meters(for family: SurfaceFamily) -> Double {
        switch family {
        case .paved: pavedMeters
        case .gravel: gravelMeters
        case .loose: looseMeters
        case .unknown: unknownMeters
        }
    }

    mutating func add(meters: Double, family: SurfaceFamily) {
        guard meters.isFinite, meters > 0 else { return }
        switch family {
        case .paved: pavedMeters += meters
        case .gravel: gravelMeters += meters
        case .loose: looseMeters += meters
        case .unknown: unknownMeters += meters
        }
    }

    static func from(responses: [RouteResponse]) -> RouteSurfaceComposition {
        var result = RouteSurfaceComposition()
        for response in responses {
            let segments = response.segments ?? []
            if !segments.isEmpty {
                var segmentResult = RouteSurfaceComposition()
                let usesLeaves = response.stats?.surfaceFamilyMode == "leaf-v3"
                for segment in segments where segment.structureType != "ferry" {
                    let meters = segment.distanceMeters ?? GeoMath.lineMeters(segment.coordinates)
                    segmentResult.add(
                        meters: meters,
                        family: segment.presentationSurfaceFamily(usesSurfaceLeaves: usesLeaves)
                    )
                }
                if segmentResult.totalMeters > 0 {
                    result.pavedMeters += segmentResult.pavedMeters
                    result.gravelMeters += segmentResult.gravelMeters
                    result.looseMeters += segmentResult.looseMeters
                    result.unknownMeters += segmentResult.unknownMeters
                    continue
                }
            }

            // Legacy saved routes have only their two-bucket summary. Preserve
            // known paved amount and total; do not invent proof of dirt.
            let meters = response.distanceMeters ?? GeoMath.lineMeters(response.coordinates)
            let paved = max(0, min(100, response.pavedPercent))
            result.add(meters: meters * Double(paved) / 100, family: .paved)
            result.add(meters: meters * Double(100 - paved) / 100, family: .unknown)
        }
        return result
    }

    private func percent(_ meters: Double) -> Int {
        guard totalMeters > 0 else { return 0 }
        return Int((meters / totalMeters * 100).rounded())
    }
}

/// Ferry travel is route distance but not a road surface. Count continuous
/// ferry runs for rider-facing notices while preserving the existing surface
/// denominator exactly.
struct RouteFerrySummary: Equatable, Sendable {
    var crossingCount = 0
    var distanceMeters = 0.0

    var hasCrossing: Bool { crossingCount > 0 }

    static func from(responses: [RouteResponse]) -> RouteFerrySummary {
        var result = RouteFerrySummary()
        for response in responses {
            var isInsideCrossing = false
            for segment in response.segments ?? [] {
                let isFerry = segment.structureType?.lowercased() == "ferry"
                if isFerry {
                    if !isInsideCrossing { result.crossingCount += 1 }
                    let meters = segment.distanceMeters ?? GeoMath.lineMeters(segment.coordinates)
                    if meters.isFinite, meters > 0 { result.distanceMeters += meters }
                }
                isInsideCrossing = isFerry
            }
        }
        return result
    }
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

    /// Rider-facing known Dirt% includes gravel + loose. Unknown is separate.
    /// Selection-time coarse dirt is separate and is not computed here.
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
        let dirtM = gravelM + looseM
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
