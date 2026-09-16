import Foundation

public struct ProfilePolicy: Sendable {
    public var style: RidingStyle
    public var avoidMajorHighways = true
    public var preferBackRoads = true
    /// Continuous detour appetite in [0, 1]. Full wander (1) is the product default:
    /// wide corridor, soft waypoint pull, substantial coherent dirt detours.
    /// Zero tightens the pull without converting Dirt into Balanced or Clean.
    public var wander = 1.0
    /// Pavement-mode away multiplier at full wander. Zero wander restores the JS ×10.
    /// 2 keeps dirt detours cheap enough to chase 70%+ without the loop-prone ×1 floor.
    public var dirtPavementAwayAtFullWander = 1.0
    /// Balanced dirt mix in [0, 1]. 0 prefers paved, 1 prefers dirt, 0.5 is the
    /// default 50/50 starting weight.
    public var balancedDirtPreference = 0.5
    /// Continuous dirt shorter than this is not meaningful (§2). A detour that
    /// only nibble-grabs below this length is clawed back to paved cost so it
    /// loses to the direct alternative.
    public var minimumMeaningfulDirtMeters = 1_000.0
    /// Paved→dirt→paved grabs shorter than this still count as scraps even when
    /// they clear the 1 km meaningful floor. Leave-abort and post-search scrap
    /// detection use this so on-path 1–2 km orange blips lose to staying paved
    /// or taking the first real dirt corridor.
    public var minimumUsefulDirtMeters = 2_500.0
    /// After this much paved riding without ever completing a meaningful dirt
    /// run, further pavement pays `deferredDirtEntryCost` so Dirt prefers the
    /// first proper dirt turn over a long paved dip that harvests scraps later.
    public var deferredDirtEntryAfterMeters = 3_000.0
    public init(style: RidingStyle) { self.style = style }
    public var appetite: Double { min(1, max(0, wander.isFinite ? wander : 1)) }
    public static func family(_ leaf: String) -> Surface {
        switch leaf.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "asphalt","paved","concrete","chipseal","paving_stones","cobblestone","sett","brick","metal","wood": return .paved
        case "gravel","compacted","fine_gravel","pebblestone","unpaved": return .gravel
        case "dirt","ground","earth","grass","mud","sand","rock","natural","woodchips": return .loose
        default: return .unknown
        }
    }
    public static func tier(_ road: String) -> String {
        switch road {
        case "motorway","motorway_link": return "motorway"
        case "trunk","trunk_link": return "trunk"
        case "primary","primary_link": return "arterial"
        case "secondary","secondary_link": return "collector"
        case "tertiary","tertiary_link","unclassified","unclassified_link": return "local_paved"
        case "residential","living_street": return "destination"
        case "service": return "service"
        case "track","path": return "adventure"
        default: return "unknown"
        }
    }
    func corridorMeters(straightLine: Double) -> Double {
        let span = straightLine.isFinite && straightLine > 0 ? straightLine : 60_000
        let clipped = min(max(span, 8_000), 400_000)
        // Geodesic fallback only. Personality searches with a road compass use
        // `roadSidewaysFraction` / `roadBackwardAllowanceMeters` instead (§5.6).
        let tight = 0.04
        let full = style == .dirt ? 0.25 : 0.18
        return clipped * (tight + (full - tight) * appetite)
    }
    /// Extra ridden meters beyond road-progress toward B. Wander 0 keeps a
    /// modest wiggle; full wander pays for S-curves and wide swings (§5.6).
    func roadExtraMeters(startRemaining: Double) -> Double {
        let remaining = startRemaining.isFinite ? max(0, startRemaining) : 50_000
        let tight = 0.42
        let wide = 0.90
        return remaining * (tight + (wide - tight) * appetite) + 8_000
    }
    /// Share of ridden meters that may go sideways. Diagnostic/legacy; search
    /// uses `roadExtraMeters` so prefixes of a legal S-curve are not killed.
    func roadSidewaysFraction() -> Double {
        if style == .cleanest { return 1 }
        let extra = roadExtraMeters(startRemaining: 100_000)
        return min(1, extra / max(1, 100_000 + extra))
    }
    /// How far remaining-to-B may increase before the label is dropped.
    /// Wander 0 keeps a 2 km jog; full wander opens a share of the remaining ride.
    func roadBackwardAllowanceMeters(startRemaining: Double) -> Double {
        if style == .cleanest { return .infinity }
        let remaining = startRemaining.isFinite ? max(0, startRemaining) : 40_000
        let tight = 8_000.0
        let wide = min(120_000, max(20_000, remaining * 0.30))
        return tight + (wide - tight) * appetite
    }
    /// Geodesic fallback when no road compass is available. Wander 0 is 2 km,
    /// not a fixed 15 km gate; Clean never applies it.
    static func progressRegressionMeters(style: RidingStyle, corridorMeters: Double,
                                         hasRoadCompass: Bool, wander: Double = 1) -> Double {
        _ = hasRoadCompass
        if style == .cleanest || !corridorMeters.isFinite { return .infinity }
        let appetite = min(1, max(0, wander.isFinite ? wander : 1))
        let tight = 2_000.0
        let wide = style == .balanced
            ? 20_000.0
            : min(60_000, max(12_000, corridorMeters * 0.25))
        return tight + (wide - tight) * appetite
    }
    /// JS `approachAwayExtraCost`, including pavement-mode ×10.
    func approachAway(fromRemaining: Double, toRemaining: Double, startRemaining: Double,
                      objective: SearchObjective) -> Double {
        let away = toRemaining - fromRemaining
        guard away > 50, fromRemaining.isFinite, toRemaining.isFinite else { return 0 }
        let kmAway = away / 1000, dFrom = max(0, fromRemaining)
        let extra: Double
        switch style {
        case .dirt:
            extra = kmAway * 9.5 + (dFrom < 2500 ? kmAway * (2 + pow(1 - dFrom / 2500, 2) * 6) : 0)
        case .balanced:
            let mix = min(1, max(0, balancedDirtPreference.isFinite ? balancedDirtPreference : 0.5))
            let horizon = max(4000, (startRemaining.isFinite ? startRemaining : 0) * 0.2)
            extra = kmAway * (8 + (1 - mix) * 172) + (dFrom < horizon ? kmAway * (20 + pow(1 - dFrom / horizon, 2) * 60) * (1 - mix) : 0)
        case .cleanest:
            extra = kmAway * (dFrom < max(2500, (startRemaining.isFinite ? startRemaining : 0) * 0.08) ? 18 : 12)
        }
        guard objective == .pavement && style == .dirt else { return extra }
        let full = max(1, dirtPavementAwayAtFullWander)
        return extra * (full + (1 - appetite) * (10 - full))
    }
    func cleanEligible(pack: any RoadGraph, edge: Int, endpoint: Bool, pavedOnly: Bool) -> Bool {
        if pack.structure(edge) == "ferry" { return true }
        let family = Self.family(pack.surfaceLeaf(edge)), tier = Self.tier(pack.roadClass(edge))
        let paved = family == .paved || (family == .unknown && ["motorway","trunk","arterial","collector","local_paved"].contains(tier))
        if pavedOnly && !paved && !endpoint { return false }
        if pavedOnly && !endpoint && tier == "adventure" { return false }
        return true
    }
    func step(pack: any RoadGraph, edge: Int, meters: Double, objective: SearchObjective,
              from: Coordinate, to: Coordinate, start: Coordinate, end: Coordinate,
              startOnHighway: Bool, endOnHighway: Bool, penalizedDirt: Bool = false,
              previousTier: String? = nil, applyGeodesicPull: Bool = true) -> Double {
        if objective == .distance { return meters / 1000 }
        if pack.structure(edge) == "ferry" {
            let seconds = pack.crossingTime(edge)
            return (seconds > 0 ? seconds : max(60,(meters/1000)/18*3600).rounded())/3600*50
        }
        let km = meters/1000, surface = Int(pack.attributes(edge) & 7)
        let tier = Self.tier(pack.roadClass(edge))
        let family = Self.family(pack.surfaceLeaf(edge))
        let coarse = Self.roadNames[min(Int((pack.attributes(edge) >> 12) & 15), Self.roadNames.count-1)]
        var cost: Double
        if objective == .pavement {
            // JS dirtRideCostPerKm: unknown on paint-as-paved classes is paved, not cheap dirt.
            let unknownPaved = surface == 4 && ["freeway","arterial","ramp","collector","local","service"].contains(coarse)
            // Gravel/loose must stay nearly free so extra coherent dirt does
            // not lose to a shorter paved spine. JS 0.5–0.7/km plus steep
            // away priced those meanders out (section 2).
            let dirtKm = [150.0,0.05,0.02,0.02,0.9]
            cost = km * (penalizedDirt || unknownPaved ? 150 : dirtKm[min(4,surface)])
        } else if style == .cleanest {
            let tiers = ["collector":0.82,"local_paved":0.95,"arterial":8.0,"service":2.4,
                         "destination":1.15,"trunk":40.0,"motorway":80.0,"adventure":120.0,"unknown":2.2]
            let families: [Surface:Double] = [.paved:1,.gravel:14,.loose:90,.unknown:1.05]
            cost = km * tiers[tier,default: 2.2] * families[family,default: 1.05]
            let dTo = to.distance(to: end)
            if (tier == "destination" || tier == "service"), dTo > 2500 {
                cost *= 1 + 2.4 * min(1,(dTo-2500)/8000)
            }
        } else {
            let mix = min(1, max(0, balancedDirtPreference.isFinite ? balancedDirtPreference : 0.5))
            let dirtWeights = [16.0,0.1624,0.0456,0.0168,0.154]
            let avoid = [1.05, 1.25, 1.30, 1.25, 1.10]
            let mid = [1.42, 0.98, 0.92, 0.88, 0.96]
            let prefer = [8.0, 0.08, 0.05, 0.05, 0.70]
            func lerp(_ a: [Double], _ b: [Double], _ t: Double) -> [Double] {
                zip(a, b).map { $0 + ($1 - $0) * t }
            }
            let balancedWeights = mix <= 0.5 ? lerp(avoid, mid, mix * 2) : lerp(mid, prefer, (mix - 0.5) * 2)
            let weights = style == .dirt ? dirtWeights : balancedWeights
            let dirtRoads = ["freeway":14.0,"arterial":9.5,"collector":2.4,"ramp":12,"local":0.78,
                             "service":1.4,"resource":0.4,"recreation":0.38,"track":0.3,"double_track":0.3,"unknown":0.95]
            let balancedRoads = ["freeway":3.2,"arterial":2.4,"collector":1.08,"ramp":2.8,"local":1,
                                 "service":1.15,"resource":0.92,"recreation":0.9,"track":0.92,"double_track":0.92,"unknown":1]
            var surfaceCost = weights[min(4,surface)]
            if surface == 4 && ["freeway","arterial","ramp","collector","local","service"].contains(coarse) {
                surfaceCost = weights[0]
            }
            cost = km * surfaceCost * (style == .dirt ? dirtRoads : balancedRoads)[coarse,default: 1]
        }
        let fromStart = to.distance(to: start), toEnd = to.distance(to: end)
        let pinned = (startOnHighway && fromStart < 6000) || (endOnHighway && toEnd < 6000)
        // Section 2: avoid highways in every style except the pin-join exemption.
        // JS applies the leaf 40/18/8 table only to Clean; keeping it for Dirt
        // and Balanced is an intentional product correction, not parity.
        if avoidMajorHighways && !pinned && style != .cleanest {
            cost *= ["motorway":40.0,"trunk":18.0,"arterial":8.0][tier,default: 1]
        }
        if style == .cleanest && avoidMajorHighways && !pinned, let previousTier {
            let fromHighway = previousTier == "motorway" || previousTier == "trunk"
            let toHighway = tier == "motorway" || tier == "trunk"
            if toHighway && !fromHighway { cost += 6 }
        }
        if objective != .balancedResource && applyGeodesicPull {
            cost += waypointPull(from: from, to: to, start: start, end: end, meters: meters, objective: objective)
        }
        return cost
    }
    /// Soft waypoint preference. JS pavement-mode ×10 away (~95/km) priced out
    /// heading away to reach dirt; section 2 requires that to stay affordable
    /// at full Wander. Low Wander restores the steep JS pull without changing style.
    func waypointPull(from: Coordinate, to: Coordinate, start: Coordinate, end: Coordinate,
                      meters: Double, objective: SearchObjective) -> Double {
        let pull = 1 - appetite
        let away = to.distance(to: end) - from.distance(to: end)
        var extra = 0.0
        if away > 50 {
            let d = from.distance(to: end), ab = start.distance(to: end), kmAway = away/1000
            switch style {
            case .dirt:
                let near = d < 2500 ? 2+pow(1-d/2500,2)*6 : 0
                extra = kmAway * (0.25 + pull * 9.25 + near * (0.05 + pull * 0.95))
                if objective == .pavement { extra *= 1 + pull * 9 }
            case .balanced:
                let h = max(4000,ab*0.2)
                extra = kmAway * ((20 + pull * 160) + (d < h ? 20+pow(1-d/h,2)*60 : 0) * (0.15 + pull * 0.85))
            case .cleanest:
                extra = kmAway * (d < max(2500,ab*0.08) ? 18 : 12)
            }
        }
        if style != .cleanest {
            extra += crossTrackExtra(to: to, start: start, end: end, meters: meters)
        }
        return extra
    }
    func crossTrackExtra(to: Coordinate, start: Coordinate, end: Coordinate, meters: Double) -> Double {
        if style == .cleanest { return 0 }
        let pull = 1 - appetite
        let xt = abs(to.crossTrack(from: start, to: end)) / 1000
        let k = style == .dirt ? (0.0006 + pull * 0.0044) : (0.002 + pull * 0.012)
        return (meters / 1000) * xt * xt * k
    }
    /// Extra cost each time the search enters dirt from a non-dirt surface.
    /// Stacks with `shortDirtClawback` so many separate >1 km grabs lose to
    /// fewer, longer connected dirt runs.
    ///
    /// `hopMeters` is the search's fog-of-war / geodesic span. A flat enter tax
    /// overcorrects on 200 km+ legs (many potential paved→dirt joins make
    /// "stay paved" look cheaper than connected dirt). Dilute past
    /// `dirtEnterTransitionReferenceMeters` so relative preference for one
    /// connected run over many grabs is preserved while absolute tax vs the
    /// paved corridor stays proportional to hop length.
    ///
    /// Dilution never drops below half the base: uncapped From-Here legs were
    /// letting on-path 1–2 km scraps beat staying paved once enter fell to ~tens.
    func dirtEnterTransitionCost(objective: SearchObjective, hopMeters: Double = .infinity) -> Double {
        guard style != .cleanest, objective != .distance else { return 0 }
        let base = dirtEnterTransitionBase(objective: objective)
        guard base > 0 else { return 0 }
        let reference = Self.dirtEnterTransitionReferenceMeters
        guard hopMeters.isFinite, hopMeters > reference, hopMeters > 0 else { return base }
        return max(base * 0.5, base * (reference / hopMeters))
    }
    /// Undiluted paved→dirt barrier. Leave-abort uses this so long hops cannot
    /// erase the scrap penalty by diluting enter alone.
    func dirtEnterTransitionBase(objective: SearchObjective) -> Double {
        guard style != .cleanest, objective != .distance else { return 0 }
        switch objective {
        case .pavement:
            // ~1.9 km of paved at 150/km on a short hop — enough that an
            // isolated 1–2 km dirt patch via a detour loses to the corridor.
            return 280
        case .profile, .balancedResource:
            let mix = min(1, max(0, balancedDirtPreference.isFinite ? balancedDirtPreference : 0.5))
            // Profile surface gap is smaller than pavement-mode; keep the same
            // qualitative barrier at that scale.
            return 8 + mix * 10
        case .distance:
            return 0
        }
    }
    /// Hop length at which `dirtEnterTransitionCost` is still the full barrier.
    static let dirtEnterTransitionReferenceMeters = 50_000.0
    /// Extra cost for dirt meters that do not yet form a meaningful contiguous
    /// run. Callers pass only the meters still under `minimumMeaningfulDirtMeters`.
    /// Prices those meters as paved so a 200–300 m nibble cannot beat staying
    /// on the direct alternative.
    func shortDirtClawback(contiguousDirtMeters: Double, objective: SearchObjective) -> Double {
        guard style != .cleanest, objective != .distance, contiguousDirtMeters > 0 else { return 0 }
        let km = contiguousDirtMeters / 1000
        switch objective {
        case .pavement:
            // Dirt-mode cheap rates are ~0.02–0.05/km; paved is 150/km.
            return km * (150 - 0.05)
        case .profile, .balancedResource:
            let mix = min(1, max(0, balancedDirtPreference.isFinite ? balancedDirtPreference : 0.5))
            // Prefer-dirt profile weight ~0.05; paved weight ~8–16.
            let paved = style == .dirt ? 16.0 : (1.05 + mix * 6.95)
            let dirt = style == .dirt ? 0.05 : (0.98 - mix * 0.9)
            return km * max(0, paved - dirt)
        case .distance:
            return 0
        }
    }
    /// Tax for leaving a dirt run that never became a useful corridor. Full
    /// undiluted enter barrier below the meaningful floor; tapers to zero by
    /// `minimumUsefulDirtMeters` so 1–2 km paved-sandwiched scraps lose.
    func shortDirtLeaveAbortCost(contiguousDirtMeters: Double, objective: SearchObjective) -> Double {
        guard style != .cleanest, objective != .distance, contiguousDirtMeters > 0 else { return 0 }
        let useful = minimumUsefulDirtMeters.isFinite ? max(0, minimumUsefulDirtMeters) : 2_500
        let meaningful = minimumMeaningfulDirtMeters.isFinite ? max(0, minimumMeaningfulDirtMeters) : 1_000
        guard contiguousDirtMeters < useful else { return 0 }
        let full = dirtEnterTransitionBase(objective: objective)
        guard full > 0 else { return 0 }
        if contiguousDirtMeters < meaningful || useful <= meaningful {
            return full
        }
        return full * (useful - contiguousDirtMeters) / (useful - meaningful)
    }
    /// Growing pavement tax while Dirt has not yet completed a meaningful dirt
    /// run. Pushes the search onto the first proper dirt turn instead of a
    /// multi-kilometre paved dip that only harvests scraps later.
    func deferredDirtEntryCost(pavedWithoutMeaningfulMeters: Double, objective: SearchObjective) -> Double {
        guard style == .dirt, objective != .distance else { return 0 }
        let after = deferredDirtEntryAfterMeters.isFinite ? max(0, deferredDirtEntryAfterMeters) : 3_000
        let excess = pavedWithoutMeaningfulMeters - after
        guard excess > 0 else { return 0 }
        let km = excess / 1000
        switch objective {
        case .pavement:
            // A few km of deferred tax ≈ staying on a scrap-free corridor until
            // the first real dirt join; not enough to block necessary pavement.
            return km * 18
        case .profile, .balancedResource:
            return km * 1.2
        case .distance:
            return 0
        }
    }
    // Ordinals come from pack-v2.js, not from display classifications.
    static let roadNames = ["unknown","freeway","arterial","collector","local","service","resource","recreation","track","double_track","ramp"]
}

public enum SearchObjective: String, Sendable { case distance, pavement, profile, balancedResource }
