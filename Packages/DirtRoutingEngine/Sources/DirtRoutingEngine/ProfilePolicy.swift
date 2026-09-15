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
    /// Sweep 10/4/2/1 on Dirt matrix routes; 4 keeps detours cheaper than paved
    /// (38/km away vs 150/km paved) without the loop-prone ×1 floor.
    public var dirtPavementAwayAtFullWander = 4.0
    /// Balanced dirt mix in [0, 1]. 0 prefers paved, 1 prefers dirt, 0.5 is the
    /// default 50/50 starting weight.
    public var balancedDirtPreference = 0.5
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
        let base = style == .dirt ? 60_000.0 : 40_000.0
        // Full wander keeps the JS 60/40 km comparison bands. Lower wander
        // shrinks them; it does not change surface weights.
        return base * (0.40 + 0.60 * appetite)
    }
    /// JS `progressRegressionForAttempt` / `MAX_PROGRESS_REGRESSION_M`.
    /// JS turns this off once a turn-state compass exists. Our compass is
    /// node-level, so Dirt/Balanced keep the forward gate as well as away-tax.
    static func progressRegressionMeters(style: RidingStyle, corridorMeters: Double,
                                         hasRoadCompass: Bool) -> Double {
        _ = hasRoadCompass
        if style == .cleanest || !corridorMeters.isFinite { return .infinity }
        if style == .balanced { return 10_000 }
        return max(15_000, min(60_000, corridorMeters * 0.25))
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
            extra = kmAway * (dFrom < max(2500, (startRemaining.isFinite ? startRemaining : 0) * 0.08) ? 2.5 : 2)
        }
        guard objective == .pavement && style == .dirt else { return extra }
        let full = max(1, dirtPavementAwayAtFullWander)
        return extra * (full + (1 - appetite) * (10 - full))
    }
    func cleanEligible(pack: any RoadGraph, edge: Int, endpoint: Bool, pavedOnly: Bool) -> Bool {
        if pack.structure(edge) == "ferry" { return true }
        let family = Self.family(pack.surfaceLeaf(edge)), tier = Self.tier(pack.roadClass(edge))
        let paved = family == .paved || (family == .unknown && ["motorway","trunk","arterial","collector","local_paved"].contains(tier))
        if pavedOnly && !paved { return false }
        if endpoint || !pavedOnly { return true }
        return tier != "destination" && tier != "adventure"
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
            let tiers = ["collector":0.92,"local_paved":1.0,"arterial":0.96,"service":2.8,
                         "destination":1.15,"trunk":1.0,"motorway":1.0,"adventure":120.0,"unknown":2.2]
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
        if avoidMajorHighways && !pinned {
            cost *= ["motorway":40.0,"trunk":18.0,"arterial":8.0][tier,default: 1]
        }
        // JS e4FlagsForProfile never enables preferBackRoads. Apply it only to
        // Clean so Dirt/Balanced are not silently retuned toward paved collectors.
        if preferBackRoads && style == .cleanest {
            cost *= ["arterial":4.5,"collector":0.82][tier,default: 1]
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
                extra = kmAway * (d < max(2500,ab*0.08) ? 2.5 : 2)
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
    // Ordinals come from pack-v2.js, not from display classifications.
    static let roadNames = ["unknown","freeway","arterial","collector","local","service","resource","recreation","track","double_track","ramp"]
}

public enum SearchObjective: String, Sendable { case distance, pavement, profile, balancedResource }
