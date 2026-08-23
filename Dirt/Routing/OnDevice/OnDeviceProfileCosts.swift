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

    static func isMajorHighway(_ road: String, profile: RouteProfile = .dirt) -> Bool {
        if road == "freeway" || road == "ramp" { return true }
        if profile == .cleanest { return false }
        return road == "arterial"
    }

    /// Pin counts as “on a major highway” only when the tap is on that carriageway.
    static let majorHighwayPinMeters = 18.0
    /// How close to A/B we may use a major highway to reach a pin that sits on one.
    static let majorHighwayJoinMeters = 6_000.0

    /// Major highways stay expensive except to enter/leave a pin on that class.
    /// Clean avoids freeway+ramp only; arterial is normal Clean pavement.
    static func majorHighwayAvoidMult(
        profile: RouteProfile,
        roadClassCode: Int,
        metersFromStart: Double,
        metersToDestination: Double,
        startOnMajorHighway: Bool,
        endOnMajorHighway: Bool
    ) -> Double {
        let road = GraphV2Pack.roadClassName(roadClassCode)
        guard isMajorHighway(road, profile: profile) else { return 1 }
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
        let target = 3.0
        if current >= target { return 1 }
        return target / current
    }

    /// Extra cost for meters walked *away* from B.
    /// Strong soft forward fan: regressing must cost more than grazing a city
    /// (×120) or a short highway connector. Slight backtracks around water OK.
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
            // Applied with ×10 in pavement mode → ~95–150/km effective.
            let mid = kmAway * 9.5
            let horizon = 2_500.0
            var near = 0.0
            if dFrom < horizon {
                let t = 1 - dFrom / horizon
                near = kmAway * (2.0 + t * t * 6.0)
            }
            return mid + near
        case .direct:
            let nearBand = max(3200.0, ab * 0.3)
            let w = dFrom < nearBand ? 200.0 : 150.0
            return kmAway * w
        case .balanced:
            let mid = kmAway * 180.0
            let horizon = max(4_000.0, ab * 0.2)
            var near = 0.0
            if dFrom < horizon {
                let t = 1 - dFrom / horizon
                near = kmAway * (20.0 + t * t * 60.0)
            }
            return mid + near
        case .cleanest:
            // Gravity toward B only — ~2/km away keeps a 15 km dip below ~60 km extra pavement.
            let nearBand = max(2500.0, ab * 0.08)
            let w = dFrom < nearBand ? 2.5 : 2.0
            return kmAway * w
        }
    }

    /// Quadratic penalty on perpendicular distance to the A→B great-circle.
    /// Clean has none — around-the-lake pavement that flows toward B is legal.
    /// Direct strongest, then Balanced, then Dirt.
    static func corridorCrossTrackExtra(
        profile: RouteProfile,
        point: CLLocationCoordinate2D,
        lineFrom: CLLocationCoordinate2D,
        lineTo: CLLocationCoordinate2D,
        edgeMeters: Double
    ) -> Double {
        guard edgeMeters > 0 else { return 0 }
        if profile == .cleanest { return 0 }
        let k: Double
        switch profile {
        case .direct: k = 0.018
        case .balanced: k = 0.014
        case .dirt: k = 0.005
        case .cleanest: k = 0
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

    /// Clean paved-only gate: genuine paved, or untagged surface on major
    /// classes only (freeway/arterial/ramp/collector). Gravel/track/access and
    /// untagged local/service are impassable under Clean's pavement constraint.
    static func isBlockedForCleanPavement(surfaceName: String, roadClassName: String) -> Bool {
        if surfaceName == "paved" { return false }
        if surfaceName == "unknown" {
            switch roadClassName {
            case "freeway", "arterial", "ramp", "collector":
                return false
            default:
                return true
            }
        }
        return true
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

    // Phase G1 — ferries (lockstep scripts/pack-fabric/routing/lib/ferry.js).
    static let ferrySpeedKmh: Double = 18
    static let ferryCostReferenceKmh: Double = 50
    static let ferryCrossingLabel = "Ferry crossing"

    static func ferryCrossingSeconds(distanceMeters: Double, storedSeconds: UInt32) -> Double {
        if storedSeconds > 0 { return Double(storedSeconds) }
        guard distanceMeters > 0 else { return 300 }
        return max(60, (distanceMeters / 1000.0) / ferrySpeedKmh * 3600.0)
    }

    static func ferryRelaxStepCost(crossingSeconds: Double) -> Double {
        guard crossingSeconds > 0 else { return 0 }
        return (crossingSeconds / 3600.0) * ferryCostReferenceKmh
    }

    // Phase G2 — structure labels (lockstep scripts/pack-fabric/routing/lib/structure.js).
    private static let structureLabelByLeaf: [String: String] = [
        "ford": "Ford",
        "stepping_stones": "Ford",
        "stream": "Ford",
        "tidal": "Ford",
        "seasonal": "Ford",
        "low_water_crossing": "Low-water crossing",
        "boardwalk": "Boardwalk",
        "viaduct": "Viaduct",
        "culvert": "Culvert",
        "building_passage": "Building passage",
        "tunnel": "Tunnel",
        "bridge": "Bridge"
    ]

    static func normalizeStructureLeaf(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !s.isEmpty else { return nil }
        return s
    }

    static func isWaterCrossing(structureCode: Int, structureLeaf: String?) -> Bool {
        if structureCode == GraphV2Pack.structureFord { return true }
        guard let leaf = normalizeStructureLeaf(structureLeaf) else { return false }
        return leaf == "ford"
            || leaf == "low_water_crossing"
            || leaf == "stepping_stones"
            || leaf == "stream"
            || leaf == "tidal"
    }

    static func structureCrossingLabel(
        structureCode: Int,
        structureLeaf: String?,
        layer: Int
    ) -> String? {
        if structureCode == GraphV2Pack.structureFerry { return ferryCrossingLabel }
        let leaf = normalizeStructureLeaf(structureLeaf)
        if let leaf, let named = structureLabelByLeaf[leaf], leaf != "bridge" {
            return named
        }
        if structureCode == GraphV2Pack.structureTunnel || leaf == "tunnel" {
            return "Tunnel"
        }
        if structureCode == GraphV2Pack.structureFord || leaf == "ford" {
            return "Ford"
        }
        if structureCode == GraphV2Pack.structureBridge || leaf == "bridge" {
            if layer > 0 { return "Overpass" }
            if layer < 0 { return "Underpass" }
            return "Bridge"
        }
        if layer > 0 { return "Overpass" }
        if layer < 0 { return "Underpass" }
        return nil
    }
}
