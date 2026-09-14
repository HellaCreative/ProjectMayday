import Foundation

/// Exact contribution of committed native traversals. Owning rider-leg scope
/// is assigned by orchestration; this value does not include an inherited prefix.
/// Total distance retains ferry and stitch travel. Those are not known surfaces.
/// This foundation does not change the native selection objective or denominator.
nonisolated struct NativeRideSurfaceContext: Codable, Hashable, Sendable {
    /// Exact native resource numerator when the selected search exposes it.
    /// Nil is unavailable; it is never inferred from leaf reporting.
    let nativeScoredDirtMeters: Double?
    let pavedMeters: Double
    let gravelMeters: Double
    let looseMeters: Double
    let unknownMeters: Double
    let ferryMeters: Double
    let stitchMeters: Double

    var knownUnpavedMeters: Double { gravelMeters + looseMeters }
    var totalMeters: Double {
        pavedMeters + gravelMeters + looseMeters + unknownMeters + ferryMeters + stitchMeters
    }
    static let zero = NativeRideSurfaceContext(pavedMeters: 0, gravelMeters: 0,
        looseMeters: 0, unknownMeters: 0, ferryMeters: 0, stitchMeters: 0, nativeScoredDirtMeters: 0)!

    init?(pavedMeters: Double, gravelMeters: Double, looseMeters: Double,
          unknownMeters: Double, ferryMeters: Double, stitchMeters: Double, nativeScoredDirtMeters: Double? = nil) {
        let values = [pavedMeters, gravelMeters, looseMeters, unknownMeters, ferryMeters, stitchMeters]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              values.reduce(0, +).isFinite else { return nil }
        let total = values.reduce(0, +)
        if let scored = nativeScoredDirtMeters {
            // Allow only a few representational ULPs when independently
            // grouped category sums differ from the search accumulation.
            // Larger discrepancies are unavailable, never silently clamped.
            let tolerance = max(1, total).ulp * 8
            guard scored.isFinite, scored >= 0,
                  scored <= total || scored - total <= tolerance else { return nil }
        }
        self.nativeScoredDirtMeters = nativeScoredDirtMeters
        self.pavedMeters = pavedMeters; self.gravelMeters = gravelMeters
        self.looseMeters = looseMeters; self.unknownMeters = unknownMeters
        self.ferryMeters = ferryMeters; self.stitchMeters = stitchMeters
    }

    func adding(_ other: Self) -> Self? {
        Self(pavedMeters: pavedMeters + other.pavedMeters,
             gravelMeters: gravelMeters + other.gravelMeters,
             looseMeters: looseMeters + other.looseMeters,
             unknownMeters: unknownMeters + other.unknownMeters,
             ferryMeters: ferryMeters + other.ferryMeters,
             stitchMeters: stitchMeters + other.stitchMeters)?
            .withNativeScoredDirtMeters(nativeScoredDirtMeters.flatMap { left in other.nativeScoredDirtMeters.map { left + $0 } })
    }

    private enum CodingKeys: String, CodingKey {
        case pavedMeters, gravelMeters, looseMeters, unknownMeters, ferryMeters, stitchMeters, nativeScoredDirtMeters
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = try Self(pavedMeters: c.decode(Double.self, forKey: .pavedMeters),
            gravelMeters: c.decode(Double.self, forKey: .gravelMeters),
            looseMeters: c.decode(Double.self, forKey: .looseMeters),
            unknownMeters: c.decode(Double.self, forKey: .unknownMeters),
            ferryMeters: c.decode(Double.self, forKey: .ferryMeters),
            stitchMeters: c.decode(Double.self, forKey: .stitchMeters),
            nativeScoredDirtMeters: c.decodeIfPresent(Double.self, forKey: .nativeScoredDirtMeters)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid exact native surface contribution"))
        }
        self = value
    }

    func withNativeScoredDirtMeters(_ value: Double?) -> Self? {
        // Legacy reconstruction can prune a searched excursion. Its old
        // resource numerator then is not an exact contribution of these legs.
        // Keep the authoritative surface facts but withhold that numerator.
        Self(pavedMeters: pavedMeters,gravelMeters: gravelMeters,looseMeters: looseMeters,
             unknownMeters: unknownMeters,ferryMeters: ferryMeters,stitchMeters: stitchMeters,
             nativeScoredDirtMeters: value) ?? Self(pavedMeters: pavedMeters,gravelMeters: gravelMeters,
             looseMeters: looseMeters,unknownMeters: unknownMeters,ferryMeters: ferryMeters,
             stitchMeters: stitchMeters,nativeScoredDirtMeters: nil)
    }
    static func localContribution(legs: [OnDeviceRouter.Leg], hasSurfaceLeaves: Bool) -> Self? {
        var paved = 0.0, gravel = 0.0, loose = 0.0, unknown = 0.0, ferry = 0.0, stitch = 0.0
        for leg in legs {
            let meters = leg.distanceMeters
            guard meters.isFinite, meters >= 0 else { return nil }
            if leg.edgeId.hasPrefix("soft-stitch-") || leg.edgeId.hasPrefix("perm-stitch-") {
                stitch += meters
            } else if leg.structureType?.lowercased() == "ferry" {
                ferry += meters
            } else {
                // Never use paintSurfaceName: an untagged road's paint inference
                // is not proof of its surface. Nil V3/V4 leaves remain unknown.
                let family = SurfaceFamilyStats.family(of: hasSurfaceLeaves ? leg.surfaceLeaf : leg.surfaceName)
                switch family {
                case .paved: paved += meters
                case .gravel: gravel += meters
                case .loose: loose += meters
                case .unknown: unknown += meters
                }
            }
        }
        return Self(pavedMeters: paved, gravelMeters: gravel, looseMeters: loose,
                    unknownMeters: unknown, ferryMeters: ferry, stitchMeters: stitch)
    }
}

extension OnDeviceRouter.Result {
    /// Derive from actual clipped traversals, never rounded percentages or a
    /// parent edge's full length. Concatenation appends local legs exactly once.
    var localSurfaceContribution: NativeRideSurfaceContext? {
        switch aggregatedSurfaceContribution {
        case .available(let value): return value
        case .unavailable: return nil
        case nil:
            return NativeRideSurfaceContext.localContribution(legs: legs, hasSurfaceLeaves: hasSurfaceLeaves)?
                .withNativeScoredDirtMeters(searchMeta.resourceSelectionDirtMeters)
        }
    }
}

/// nil on Result means aggregation has not occurred; unavailable means an
/// attempted aggregate lacked an exact component and must not be re-derived.
nonisolated enum NativeRideSurfaceAggregation: Sendable {
    case available(NativeRideSurfaceContext)
    case unavailable
}
