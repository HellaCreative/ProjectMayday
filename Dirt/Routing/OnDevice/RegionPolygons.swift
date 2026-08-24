import Foundation

/// OSM administrative polygons for Nova Scotia and New Brunswick.
/// Lockstep with `scripts/pack-fabric/routing/lib/region-polygons.js`.
enum RegionPolygons {
    private static let geometries: [String: [String: Any]] = {
        let url = Bundle.main.url(forResource: "RegionPolygons", withExtension: "json")
            ?? Bundle(for: BundleToken.self).url(forResource: "RegionPolygons", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let regions = root["regions"] as? [String: [String: Any]]
        else { return [:] }
        return regions
    }()

    static func contains(_ regionId: String, longitude lon: Double, latitude lat: Double) -> Bool {
        guard let geom = geometries[regionId.lowercased()],
              let type = geom["type"] as? String
        else { return false }
        return pointInGeometry(lon: lon, lat: lat, type: type, coordinates: geom["coordinates"])
    }

    /// Admin-polygon owner for NS/NB. Nil when the point is in neither polygon.
    static func maritimesOwner(longitude lon: Double, latitude lat: Double) -> String? {
        let ns = contains("ns", longitude: lon, latitude: lat)
        let nb = contains("nb", longitude: lon, latitude: lat)
        if ns && !nb { return "ns" }
        if nb && !ns { return "nb" }
        if ns && nb { return lon >= -64.27 ? "ns" : "nb" }
        return nil
    }

    private static func pointInGeometry(lon: Double, lat: Double, type: String, coordinates: Any?) -> Bool {
        if type == "Polygon", let rings = asRings(coordinates) {
            return pointInPolygon(lon: lon, lat: lat, rings: rings)
        }
        if type == "MultiPolygon", let polygons = asMultiRings(coordinates) {
            return polygons.contains { pointInPolygon(lon: lon, lat: lat, rings: $0) }
        }
        return false
    }

    private static func asRings(_ raw: Any?) -> [[[Double]]]? {
        guard let rings = raw as? [Any] else { return nil }
        return rings.compactMap { asRing($0) }
    }

    private static func asMultiRings(_ raw: Any?) -> [[[[Double]]]]? {
        guard let polygons = raw as? [Any] else { return nil }
        return polygons.compactMap { asRings($0) }
    }

    private static func asRing(_ raw: Any) -> [[Double]]? {
        guard let points = raw as? [Any] else { return nil }
        return points.compactMap { point in
            guard let pair = point as? [Any], pair.count >= 2,
                  let lon = (pair[0] as? NSNumber)?.doubleValue,
                  let lat = (pair[1] as? NSNumber)?.doubleValue
            else { return nil }
            return [lon, lat]
        }
    }

    private static func pointInPolygon(lon: Double, lat: Double, rings: [[[Double]]]) -> Bool {
        guard let outer = rings.first, pointInRing(lon: lon, lat: lat, ring: outer) else { return false }
        for hole in rings.dropFirst() where pointInRing(lon: lon, lat: lat, ring: hole) {
            return false
        }
        return true
    }

    private static func pointInRing(lon: Double, lat: Double, ring: [[Double]]) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let xi = ring[i][0], yi = ring[i][1]
            let xj = ring[j][0], yj = ring[j][1]
            let intersect = (yi > lat) != (yj > lat)
                && lon < (xj - xi) * (lat - yi) / (yj - yi) + xi
            if intersect { inside.toggle() }
            j = i
        }
        return inside
    }
}

private final class BundleToken {}
