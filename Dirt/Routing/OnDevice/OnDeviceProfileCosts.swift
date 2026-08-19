import Foundation

/// Shared surface + road-class weight tables with pack-fabric `routing/lib/profile-costs.js`.
/// Profile intent (the dial — there is no separate Wander control):
///   Clean    → pavement / highway first (ETA)
///   Direct   → crow-flies toward B; dirt only when it barely detours
///   Balanced → dual-sport mix (~50/50 when fabric allows)
///   Dirt     → adventure ride: progress generally toward B, meander for yellow/white/blue
///              dirt; pavement only when forced. Allow Unknown stays OFF unless the rider
///              opts in (legal risk) — purple Access is gated by that toggle.
/// Opted out of `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` for `Task.detached` search.
nonisolated enum OnDeviceProfileCosts {
    /// Packed surface codes: paved=0 gravel=1 access=2 track=3 unknown=4.
    static func surfaceName(code: Int) -> String {
        switch code {
        case 0: return "paved"
        case 1: return "gravel"
        case 2: return "access"
        case 3: return "track"
        default: return "unknown"
        }
    }

    /// Extra Dirt discount on tagged unpaved so track / resource beats a dirt road’s
    /// straight line — collect the trails, not just the through-FSR.
    private static let dirtUnpavedMult: [Double] = [
        1.0,   // paved — unused
        0.58,  // gravel
        0.38,  // access / resource
        0.28,  // track
        0.55   // unknown surface (only used when class is not a paved road)
    ]

    static func surfaceWeight(
        profile: RouteProfile,
        surfaceCode: Int,
        regionId: String? = nil,
        roadClassCode: Int = 0
    ) -> Double {
        _ = regionId
        let table: [Double]
        switch profile {
        case .direct:
            // Length first. Mild dirt preference among near-equal options only.
            table = [1.18, 0.96, 0.93, 0.90, 0.95] // paved gravel access track unknown
        case .balanced:
            // Dual-sport: leave crow-flies pavement for track corridors (~50/50 pull).
            table = [4.2, 0.72, 0.58, 0.48, 0.68]
        case .dirt:
            // Adventure: tagged gravel/track/resource. Untagged yellow/white OSM
            // roads paint paved — cost them as paved or Dirt and Balanced both
            // sit on the same 50/50 mix. 16× (not 36×) still allows a short
            // paved connector onto an FSR.
            table = [16.0, 0.28, 0.12, 0.06, 0.28]
        case .cleanest:
            table = [1.0, 8.0, 10.0, 14.0, 6.0]
        }
        let idx = min(max(surfaceCode, 0), table.count - 1)
        let road = GraphV2Pack.roadClassName(roadClassCode)
        // Untagged highway is pavement, not adventure fuel — match rider paint.
        if idx == 4, paintsAsPavedRoadClass(road), profile == .dirt || profile == .balanced {
            return table[0]
        }
        var w = table[idx]
        if profile == .dirt, idx > 0 {
            w *= dirtUnpavedMult[idx]
        }
        return w
    }

    static func isHighwayClass(_ road: String) -> Bool {
        road == "freeway" || road == "arterial" || road == "ramp"
    }

    /// Same set `riderPaintSurface` remaps from unknown → paved.
    static func paintsAsPavedRoadClass(_ road: String) -> Bool {
        isHighwayClass(road) || road == "collector" || road == "local" || road == "service"
    }

    /// Road-track multipliers — parity with `PROFILE_ROAD_CLASS_WEIGHTS` in profile-costs.js.
    static func roadClassWeight(profile: RouteProfile, roadClassCode: Int) -> Double {
        let key = GraphV2Pack.roadClassName(roadClassCode)
        let table: [String: Double]
        switch profile {
        case .cleanest:
            table = [
                "freeway": 0.94, "arterial": 0.95, "collector": 0.97, "ramp": 0.96,
                "local": 1.0, "service": 1.08, "resource": 1.0, "recreation": 1.0,
                "track": 1.0, "double_track": 1.0, "unknown": 1.0
            ]
        case .direct:
            // Crow-flies. Highway penalties must stay close to Clean — 4.4× freeway
            // made Direct take the same 178 km mixed corridor as Dirt (Hope→Princeton).
            table = [
                "freeway": 1.55, "arterial": 1.35, "collector": 1.06, "ramp": 1.45,
                "local": 0.95, "service": 1.12, "resource": 0.92, "recreation": 0.9,
                "track": 0.88, "double_track": 0.88, "unknown": 1.0
            ]
        case .balanced:
            table = [
                "freeway": 5.6, "arterial": 4.2, "collector": 1.1, "ramp": 5.0,
                "local": 0.86, "service": 1.28, "resource": 0.76, "recreation": 0.74,
                "track": 0.7, "double_track": 0.7, "unknown": 1.0
            ]
        case .dirt:
            // Highway-class tax carries the spine hate. Collector (OSM secondary)
            // was ~free and kept Dirt on the same 50/50 mix as Balanced.
            table = [
                "freeway": 14.0, "arterial": 9.5, "collector": 2.4, "ramp": 12.0,
                "local": 0.78, "service": 1.4, "resource": 0.40, "recreation": 0.38,
                "track": 0.30, "double_track": 0.30, "unknown": 0.95
            ]
        }
        return table[key] ?? table["unknown"] ?? 1.0
    }

    /// Combined km cost for one undirected edge (surface × road class × passable quality).
    static func edgeCostPerKm(
        profile: RouteProfile,
        surfaceCode: Int,
        roadClassCode: Int,
        regionId: String? = nil,
        accessCode: Int = 1,
        confidenceCode: Int = 1
    ) -> Double {
        surfaceWeight(
                profile: profile,
                surfaceCode: surfaceCode,
                regionId: regionId,
                roadClassCode: roadClassCode
            )
            * roadClassWeight(profile: profile, roadClassCode: roadClassCode)
            * passableQualityMult(
                profile: profile,
                surfaceCode: surfaceCode,
                roadClassCode: roadClassCode,
                accessCode: accessCode,
                confidenceCode: confidenceCode
            )
    }

    /// Prefer physically passable dirt (gravel/track, medium+ confidence, permissive)
    /// and yellow/white local roads. Allow Unknown still gates motorized_unknown edges.
    static func passableQualityMult(
        profile: RouteProfile,
        surfaceCode: Int,
        roadClassCode: Int,
        accessCode: Int,
        confidenceCode: Int
    ) -> Double {
        switch profile {
        case .dirt, .balanced:
            break
        default:
            return 1
        }
        var m = 1.0
        // Confidence: 0 high, 1 medium, 2 low
        switch confidenceCode {
        case 0: m *= 0.90
        case 2: m *= profile == .dirt ? 1.25 : 1.22
        default: break
        }
        let access = accessName(accessCode)
        // Unknown access is only reachable when Allow is ON — still prefer verified/permissive.
        if access == "motorized_unknown" {
            m *= profile == .dirt ? 1.35 : 1.15
        }
        let surface = surfaceName(code: surfaceCode)
        let road = GraphV2Pack.roadClassName(roadClassCode)
        if surface == "gravel", road == "track" || road == "double_track" || road == "resource" || road == "local" {
            m *= profile == .dirt ? 0.72 : 0.9
        }
        return m
    }

    private static func accessName(_ code: Int) -> String {
        switch code {
        case 0: return "motorized_verified"
        case 1: return "motorized_permissive"
        case 2: return "motorized_unknown"
        case 3: return "motorized_restricted"
        case 4: return "motorized_excluded"
        default: return "motorized_unknown"
        }
    }

    /// Extra paved tax while still far from B.
    /// Dirt stays off highway spines until forced; Balanced milder; Direct/Clean skip.
    static func pavementLateJoinMult(
        profile: RouteProfile,
        surfaceCode: Int,
        distanceToDestinationMeters: Double,
        abMeters: Double
    ) -> Double {
        guard surfaceCode == 0 else { return 1 }
        switch profile {
        case .dirt, .balanced:
            break
        default:
            return 1
        }
        let nearBand = 1200.0
        let dTo = max(0, distanceToDestinationMeters)
        guard dTo > nearBand else { return 1 }
        let farBand = max(abMeters * 0.45, profile == .dirt ? 14_000.0 : 7000.0)
        let t = min(1, (dTo - nearBand) / max(1, farBand - nearBand))
        let baseExtra = profile == .dirt ? 0.75 : 0.95
        return 1 + baseExtra * t
    }

    /// Extra cost for meters walked *away* from B.
    /// Dirt: adventure meander OK (NW/E/NE zig-zag toward B). Only soft progress
    /// pressure — this is NOT Clean/Direct ETA routing.
    /// Direct: strong crow-flies. Balanced: medium. Clean: pavement toward B.
    static func approachAwayExtra(
        profile: RouteProfile,
        dFromMeters: Double,
        dToMeters: Double,
        abMeters: Double,
        minAwayMeters: Double = 50,
        regionId: String? = nil
    ) -> Double {
        _ = regionId
        let away = dToMeters - dFromMeters
        guard away > minAwayMeters else { return 0 }
        let dFrom = max(0, dFromMeters)
        let ab = abMeters > 0 ? abMeters : 0
        let kmAway = away / 1000.0

        switch profile {
        case .dirt:
            // Soft mid-route: lateral adventure is the product. "Near B" is the
            // last ~12 km — a 0.75×AB horizon made most of a long ride "near"
            // and collapsed Dirt onto Balanced.
            let mid = kmAway * 0.06
            let horizon = 12_000.0
            var near = 0.0
            if dFrom < horizon {
                let t = 1 - dFrom / horizon
                near = kmAway * (0.15 + t * t * 3.2)
            }
            return mid + near
        case .direct:
            let nearBand = max(3200.0, ab * 0.3)
            let w = dFrom < nearBand ? 10.0 : 4.2
            return kmAway * w
        case .balanced:
            let mid = kmAway * 1.1
            let horizon = max(8000.0, ab * 0.4)
            var near = 0.0
            if dFrom < horizon {
                let t = 1 - dFrom / horizon
                near = kmAway * (0.4 + t * t * 5.5)
            }
            return mid + near
        case .cleanest:
            let nearBand = max(2800.0, ab * 0.28)
            let w = dFrom < nearBand ? 6.5 : 3.2
            return kmAway * w
        }
    }

    /// Adventure meters share — OSM highway stack is pavement when untagged.
    /// Track / resource / gravel stay dirt. `unknown` on a road class is paved.
    static func isAdventureSurface(_ name: String) -> Bool {
        switch name {
        case "gravel", "access", "resource", "track", "double_track", "single", "unpaved", "dirt":
            return true
        default:
            return false
        }
    }

    /// Untagged OSM highway (motorway…unclassified/service) paints as paved.
    /// Track / path / ATV stay adventure. This is the OSM class winning over
    /// a missing `surface=` tag — the field bug of asphalt shown as dirt.
    static func riderPaintSurface(surfaceName: String, roadClassName: String) -> String {
        if surfaceName == "paved" { return "paved" }
        if surfaceName == "unknown" {
            switch roadClassName {
            case "freeway", "arterial", "ramp", "collector", "local", "service":
                return "paved"
            default:
                return surfaceName
            }
        }
        return surfaceName
    }

    static func isAdventureRoadClass(_ code: Int) -> Bool {
        switch GraphV2Pack.roadClassName(code) {
        case "track", "double_track", "resource", "recreation", "local":
            return true
        default:
            return false
        }
    }
}
