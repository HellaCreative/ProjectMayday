import CoreLocation
import Foundation

/// Shared surface + road-class weight tables with pack-fabric `routing/lib/profile-costs.js`.
/// Profile intent (the dial — there is no separate Wander control):
///   Clean    → pavement only. Avoid town cores and major highways unless A/B is there.
///   Direct   → dirt on the crow-flies line. No hunt. Pavement OK when dirt loops.
///   Balanced → dual-sport mix (~50/50 when fabric allows)
///   Dirt     → adventure ride: progress generally toward B, meander for yellow/white/blue
///              dirt; pavement only when forced. Allow Unknown stays OFF unless the rider
///              opts in (legal risk) — purple Access is gated by that toggle.
///   All profiles skip freeway / arterial / ramp except to join a pin that
///   actually sits on that highway (last/first ~6 km). A 401 destination does
///   not unlock motorways from Barrie.
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
            // Geometry first. Surface is a mild tie-break between roads that
            // make similar progress near the A→B line.
            table = [1.15, 1.00, 0.95, 0.90, 1.00]
        case .balanced:
            // Dual-sport ~50/50. Cross-track keeps it on the A→B corridor;
            // without that it hunts like Dirt.
            table = [1.42, 0.98, 0.92, 0.88, 0.96]
        case .dirt:
            // Adventure: tagged gravel/track/resource. Untagged yellow/white OSM
            // roads paint paved — cost them as paved or Dirt and Balanced both
            // sit on the same 50/50 mix. 16× (not 36×) still allows a short
            // paved connector onto an FSR.
            table = [16.0, 0.28, 0.12, 0.06, 0.28]
        case .cleanest:
            table = [1.0, 60.0, 80.0, 100.0, 12.0]
        }
        let idx = min(max(surfaceCode, 0), table.count - 1)
        let road = GraphV2Pack.roadClassName(roadClassCode)
        // Untagged highway is pavement, not adventure fuel — match rider paint.
        if idx == 4, paintsAsPavedRoadClass(road) {
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
            // Highway around towns. Local/service is the city grid — extra tax
            // in `cleanCityStreetMult` eases only near A/B.
            table = [
                "freeway": 0.94, "arterial": 0.98, "collector": 1.18, "ramp": 0.96,
                "local": 2.6, "service": 3.2, "resource": 1.0, "recreation": 1.0,
                "track": 1.0, "double_track": 1.0, "unknown": 1.0
            ]
        case .direct:
            table = [
                "freeway": 1.7, "arterial": 1.45, "collector": 1.06, "ramp": 1.6,
                "local": 0.98, "service": 1.12, "resource": 0.90, "recreation": 0.88,
                "track": 0.90, "double_track": 0.90, "unknown": 1.0
            ]
        case .balanced:
            table = [
                "freeway": 3.2, "arterial": 2.4, "collector": 1.08, "ramp": 2.8,
                "local": 1.0, "service": 1.15, "resource": 0.92, "recreation": 0.90,
                "track": 0.92, "double_track": 0.92, "unknown": 1.0
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
    /// `pavedBias` is Balanced ratio-seeking only (1 = table as written).
    static func edgeCostPerKm(
        profile: RouteProfile,
        surfaceCode: Int,
        roadClassCode: Int,
        regionId: String? = nil,
        accessCode: Int = 1,
        confidenceCode: Int = 1,
        pavedBias: Double = 1
    ) -> Double {
        var w = surfaceWeight(
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
        if surfaceCode == 0, pavedBias != 1, pavedBias > 0 {
            w *= pavedBias
        }
        return w
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
        case 2: m *= profile == .balanced ? 1.22 : 1.25
        default: break
        }
        let access = accessName(accessCode)
        // Unknown access is only reachable when Allow is ON — still prefer verified/permissive.
        if access == "motorized_unknown" {
            m *= profile == .balanced ? 1.15 : 1.35
        }
        let surface = surfaceName(code: surfaceCode)
        let road = GraphV2Pack.roadClassName(roadClassCode)
        if surface == "gravel", road == "track" || road == "double_track" || road == "resource" || road == "local" {
            m *= profile == .balanced ? 0.9 : 0.72
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

    /// Clean: city grid (local / service) is expensive unless the pin is in that town.
    /// A stage waypoint as B is the pin — that city is allowed.
    static func cleanCityStreetMult(
        profile: RouteProfile,
        roadClassCode: Int,
        distanceToDestinationMeters: Double
    ) -> Double {
        guard profile == .cleanest else { return 1 }
        let road = GraphV2Pack.roadClassName(roadClassCode)
        guard road == "local" || road == "service" else { return 1 }
        let nearBand = 2_500.0
        let dTo = max(0, distanceToDestinationMeters)
        guard dTo > nearBand else { return 1 }
        let t = min(1, (dTo - nearBand) / 8_000.0)
        return 1 + 2.4 * t
    }

    static func isMajorHighway(_ road: String) -> Bool {
        road == "freeway" || road == "arterial" || road == "ramp"
    }

    /// Pin counts as “on a major highway” only when the tap is on that carriageway.
    static let majorHighwayPinMeters = 18.0
    /// How close to A/B we may use a major highway to reach a pin that sits on one.
    static let majorHighwayJoinMeters = 6_000.0

    /// Major highways stay expensive except to enter/leave a pin on that class.
    static func majorHighwayAvoidMult(
        profile: RouteProfile,
        roadClassCode: Int,
        metersFromStart: Double,
        metersToDestination: Double,
        startOnMajorHighway: Bool,
        endOnMajorHighway: Bool
    ) -> Double {
        let road = GraphV2Pack.roadClassName(roadClassCode)
        guard isMajorHighway(road) else { return 1 }
        let join = majorHighwayJoinMeters
        let nearPinnedHighway =
            (endOnMajorHighway && metersToDestination < join)
            || (startOnMajorHighway && metersFromStart < join)
        let current = roadClassWeight(profile: profile, roadClassCode: roadClassCode)
        if nearPinnedHighway {
            if profile == .cleanest { return 1 }
            let target = 2.0
            if current <= target { return 1 }
            return target / current
        }
        let target = 12.0
        if current >= target { return 1 }
        return target / current
    }

    /// Extra cost for meters walked *away* from B.
    /// Dirt: hunt dirt for the ride. A/B are endpoints. Only a small *arrival*
    /// clamp in the last ~2.5 km of B so the line does not orbit the pin.
    /// Direct: same dirt prices, strong crow-flies (no meander).
    /// Balanced: medium mix. Clean: pavement toward B, skip towns unless the pin is there.
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
            // Hunt dirt, but still pay to walk away from B — 0.4 still allowed a
            // province-scale loop when track was nearly free.
            let mid = kmAway * 1.45
            // Arrival only — not a 12 km hunt ban. Short A→B hops must still hunt.
            let horizon = 2_500.0
            var near = 0.0
            if dFrom < horizon {
                let t = 1 - dFrom / horizon
                near = kmAway * (0.12 + t * t * 0.9)
            }
            let raw = mid + near
            // Track is ~0.017/km; paved is 16/km. Away must not invert that.
            let cap = kmAway * 16.0 * 0.12
            return min(raw, cap)
        case .direct:
            // Progress-toward-B only. Corridor bound is `corridorCrossTrackExtra`.
            let nearBand = max(3200.0, ab * 0.3)
            let w = dFrom < nearBand ? 12.0 : 7.0
            return kmAway * w
        case .balanced:
            let mid = kmAway * 2.2
            let horizon = max(4_000.0, ab * 0.2)
            var near = 0.0
            if dFrom < horizon {
                let t = 1 - dFrom / horizon
                near = kmAway * (0.4 + t * t * 2.4)
            }
            return mid + near
        case .cleanest:
            let nearBand = max(2800.0, ab * 0.28)
            let w = dFrom < nearBand ? 6.5 : 3.2
            return kmAway * w
        }
    }

    /// Quadratic penalty on perpendicular distance to the A→B great-circle.
    /// A wide arc that still gets closer to B never trips `approachAwayExtra`.
    /// Direct strongest, Balanced enough to stop a Williams Lake hunt, Dirt
    /// allows nearby valleys but not a 200 km north detour.
    static func corridorCrossTrackExtra(
        profile: RouteProfile,
        point: CLLocationCoordinate2D,
        lineFrom: CLLocationCoordinate2D,
        lineTo: CLLocationCoordinate2D,
        edgeMeters: Double
    ) -> Double {
        guard edgeMeters > 0 else { return 0 }
        let k: Double
        switch profile {
        case .direct: k = 0.018
        case .balanced: k = 0.014
        case .dirt: k = 0.005
        case .cleanest: return 0
        }
        let xtKm = abs(GeoMath.crossTrackMeters(point: point, lineFrom: lineFrom, to: lineTo)) / 1000.0
        let km = edgeMeters / 1000.0
        return km * xtKm * xtKm * k
    }

    static func directCrossTrackExtra(
        profile: RouteProfile,
        point: CLLocationCoordinate2D,
        lineFrom: CLLocationCoordinate2D,
        lineTo: CLLocationCoordinate2D,
        edgeMeters: Double
    ) -> Double {
        corridorCrossTrackExtra(
            profile: profile,
            point: point,
            lineFrom: lineFrom,
            lineTo: lineTo,
            edgeMeters: edgeMeters
        )
    }

    /// Adventure meters share — OSM highway stack is pavement when untagged.
    /// Track / resource / gravel stay dirt. `unknown` on a road class is paved.
    static func isAdventureSurface(_ name: String) -> Bool {
        switch name {
        // `unknown` only reaches here after riderPaintSurface has already
        // remapped untagged highway/local/service classes to paved. What remains
        // is an untagged track/resource edge, which the live engine counts as
        // dirt. Keep phone and live route selection/statistics identical.
        case "gravel", "access", "resource", "track", "double_track", "single", "unpaved", "dirt", "unknown":
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

    /// Selected-route paint keeps two independent OSM facts separate:
    /// surface material and confidence that motorcycles may use the way.
    /// Unknown motor access wins visually; otherwise an untagged track/path
    /// remains an adventure surface instead of being shown as black pavement.
    static func selectedRoutePaintKey(
        surfaceName: String,
        roadClassName: String,
        accessName: String
    ) -> String {
        if accessName == "motorized_unknown" {
            return "unknown_access"
        }
        return riderPaintSurface(
            surfaceName: surfaceName,
            roadClassName: roadClassName
        )
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
