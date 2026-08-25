import CoreLocation
import Foundation

/// Soft urban-core avoidance for every routing profile.
///
/// Boxes cover the practical through-route core, not merely a downtown point;
/// otherwise a router can still treat the surrounding city grid as free fabric.
/// Crossing is penalized (Clean ×10 with major highways off, ×2 with them on)
/// but passable so a short graze beats a
/// hundreds-of-kilometre detour. Lockstep: `scripts/pack-fabric/routing/lib/hop-search.js`.
nonisolated enum UrbanCore {
    struct Box: Sendable {
        var minLat: Double
        var maxLat: Double
        var minLon: Double
        var maxLon: Double
        var name: String

        func contains(_ lat: Double, _ lon: Double) -> Bool {
            lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon
        }

        func contains(_ c: CLLocationCoordinate2D) -> Bool {
            contains(c.latitude, c.longitude)
        }
    }

    /// Recognized Canadian urban cores. This is a product-wide routing policy,
    /// not a city-specific exception. Keep it in lockstep with hop-search.js.
    static let boxes: [Box] = [
        Box(minLat: 49.00, maxLat: 49.42, minLon: -123.32, maxLon: -122.70, name: "vancouver"),
        Box(minLat: 49.00, maxLat: 49.14, minLon: -122.45, maxLon: -122.15, name: "abbotsford"),
        Box(minLat: 49.08, maxLat: 49.20, minLon: -122.05, maxLon: -121.85, name: "chilliwack"),
        Box(minLat: 48.40, maxLat: 48.52, minLon: -123.45, maxLon: -123.30, name: "victoria"),
        Box(minLat: 49.80, maxLat: 50.00, minLon: -119.65, maxLon: -119.30, name: "kelowna"),
        Box(minLat: 50.62, maxLat: 50.75, minLon: -120.50, maxLon: -120.15, name: "kamloops"),
        Box(minLat: 53.82, maxLat: 54.00, minLon: -122.85, maxLon: -122.65, name: "prince-george"),
        Box(minLat: 44.55, maxLat: 44.78, minLon: -63.75, maxLon: -63.40, name: "halifax"),
        Box(minLat: 45.85, maxLat: 46.20, minLon: -64.95, maxLon: -64.55, name: "moncton"),
        Box(minLat: 45.20, maxLat: 45.35, minLon: -66.20, maxLon: -65.95, name: "saint-john"),
        Box(minLat: 45.90, maxLat: 46.05, minLon: -66.75, maxLon: -66.55, name: "fredericton"),
        Box(minLat: 46.75, maxLat: 46.90, minLon: -71.35, maxLon: -71.10, name: "quebec-city"),
        Box(minLat: 50.85, maxLat: 51.22, minLon: -114.32, maxLon: -113.85, name: "calgary"),
        Box(minLat: 53.40, maxLat: 53.70, minLon: -113.72, maxLon: -113.28, name: "edmonton"),
        Box(minLat: 43.58, maxLat: 43.85, minLon: -79.64, maxLon: -79.12, name: "toronto"),
        Box(minLat: 45.38, maxLat: 45.72, minLon: -73.98, maxLon: -73.48, name: "montreal"),
        Box(minLat: 45.32, maxLat: 45.48, minLon: -75.85, maxLon: -75.62, name: "ottawa"),
        Box(minLat: 49.80, maxLat: 50.00, minLon: -97.30, maxLon: -96.95, name: "winnipeg"),
        Box(minLat: 50.38, maxLat: 50.52, minLon: -104.75, maxLon: -104.50, name: "regina"),
        Box(minLat: 52.05, maxLat: 52.22, minLon: -106.80, maxLon: -106.55, name: "saskatoon")
    ]

    private struct SettlementRow: Decodable {
        let minLat: Double
        let maxLat: Double
        let minLon: Double
        let maxLon: Double
        let name: String
    }

    private struct SettlementFile: Decodable {
        let regions: [String: [SettlementRow]]
    }

    private static let fallbackSettlementsByRegion: [String: [Box]] = {
        let url = Bundle.main.url(forResource: "UrbanSettlements", withExtension: "json")
            ?? Bundle(for: UrbanSettlementBundleToken.self)
                .url(forResource: "UrbanSettlements", withExtension: "json")
        guard let url,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(SettlementFile.self, from: data)
        else { return [:] }
        return decoded.regions.mapValues { rows in
            rows.map {
                Box(
                    minLat: $0.minLat,
                    maxLat: $0.maxLat,
                    minLon: $0.minLon,
                    maxLon: $0.maxLon,
                    name: $0.name
                )
            }
        }
    }()

    /// Embedded pack metadata is authoritative; compatibility data only fills an empty v3 pack.
    static func settlementBoxes(
        embedded: [Box],
        regionId: String?,
        profile: RouteProfile
    ) -> [Box] {
        if !embedded.isEmpty { return embedded }
        guard profile == .cleanest else { return [] }
        return fallbackSettlementsByRegion[regionId?.lowercased() ?? ""] ?? []
    }

    static func box(containing c: CLLocationCoordinate2D, boxes candidateBoxes: [Box]? = nil) -> Box? {
        (candidateBoxes ?? boxes).first { $0.contains(c) }
    }

    static func contains(_ c: CLLocationCoordinate2D, boxes candidateBoxes: [Box]? = nil) -> Bool {
        box(containing: c, boxes: candidateBoxes) != nil
    }

    static func isNear(
        _ point: CLLocationCoordinate2D,
        boxes candidateBoxes: [Box],
        clearanceMeters: Double = 5_000
    ) -> Bool {
        candidateBoxes.contains { box in
            let nearest = CLLocationCoordinate2D(
                latitude: max(box.minLat, min(box.maxLat, point.latitude)),
                longitude: max(box.minLon, min(box.maxLon, point.longitude))
            )
            return CLLocation(latitude: point.latitude, longitude: point.longitude)
                .distance(from: CLLocation(latitude: nearest.latitude, longitude: nearest.longitude)) < clearanceMeters
        }
    }

    private static func segmentIntersects(
        _ a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D,
        box: Box
    ) -> Bool {
        let dx = b.longitude - a.longitude
        let dy = b.latitude - a.latitude
        var low = 0.0
        var high = 1.0
        let tests = [
            (-dx, a.longitude - box.minLon),
            (dx, box.maxLon - a.longitude),
            (-dy, a.latitude - box.minLat),
            (dy, box.maxLat - a.latitude)
        ]
        for (p, q) in tests {
            if p == 0 {
                if q < 0 { return false }
                continue
            }
            let ratio = q / p
            if p < 0 { low = max(low, ratio) }
            else { high = min(high, ratio) }
            if low > high { return false }
        }
        return true
    }

    /// Ban travel through an urban core unless A or B is inside that same box.
    /// Used for detection / diagnostics; routing applies `fallbackMultiplier`
    /// instead of hard-blocking these points.
    static func blocks(
        point: CLLocationCoordinate2D,
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D,
        boxes candidateBoxes: [Box]? = nil
    ) -> Bool {
        guard let box = box(containing: point, boxes: candidateBoxes) else { return false }
        if box.contains(start) || box.contains(end) { return false }
        return true
    }

    static func blocks(
        segmentFrom: CLLocationCoordinate2D,
        segmentTo: CLLocationCoordinate2D,
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D,
        boxes candidateBoxes: [Box]? = nil
    ) -> Bool {
        for box in candidateBoxes ?? boxes {
            if box.contains(start) || box.contains(end) { continue }
            if segmentIntersects(segmentFrom, segmentTo, box: box) { return true }
        }
        return false
    }

    /// Strong but passable urban-core penalty. Favours the shortest necessary
    /// crossing while preserving the A/B-inside exemption. Applied on every
    /// search (not only last-resort), so cities stay expensive without forcing
    /// province-scale detours.
    /// - Parameter penalty: generic fallback default 120. Clean passes its ×5 policy.
    static func fallbackMultiplier(
        point: CLLocationCoordinate2D,
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D,
        boxes candidateBoxes: [Box]? = nil,
        edgeFrom: CLLocationCoordinate2D? = nil,
        penalty: Double = 120
    ) -> Double {
        let p = penalty.isFinite && penalty > 0 ? penalty : 120
        if blocks(point: point, start: start, end: end, boxes: candidateBoxes) { return p }
        if let edgeFrom,
           blocks(segmentFrom: edgeFrom, segmentTo: point, start: start, end: end, boxes: candidateBoxes) {
            return p
        }
        return 1
    }

    /// Clean city policy follows the major-highway control; tester override remains 1…20.
    static func resolveCleanMetroPenalty(
        profile: RouteProfile,
        override: Double?,
        avoidMajorHighways: Bool
    ) -> Double {
        guard profile == .cleanest else { return 120 }
        guard let raw = override, raw.isFinite else { return avoidMajorHighways ? 10 : 2 }
        return min(20, max(1, raw))
    }

    /// Pack-derived towns share Clean's bounded city control. Adventure profiles
    /// retain the existing finite ×5 settlement preference.
    static func resolveSettlementPenalty(
        profile: RouteProfile,
        override: Double?,
        avoidMajorHighways: Bool
    ) -> Double {
        profile == .cleanest
            ? resolveCleanMetroPenalty(
                profile: profile,
                override: override,
                avoidMajorHighways: avoidMajorHighways
            )
            : 5
    }

    /// Smaller OSM cities/towns are strongly penalized so a practical wilderness
    /// alternative wins without severing the only through-road.
    static func settlementFallbackMultiplier(
        point: CLLocationCoordinate2D,
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D,
        boxes candidateBoxes: [Box],
        penalty: Double = 5
    ) -> Double {
        let bounded = penalty.isFinite ? min(20, max(1, penalty)) : 5
        return blocks(point: point, start: start, end: end, boxes: candidateBoxes) ? bounded : 1
    }
}

private final class UrbanSettlementBundleToken {}
