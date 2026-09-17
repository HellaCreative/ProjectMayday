import Foundation

/// OSM administrative polygons for stamped v3 regions.
/// Lockstep with `scripts/pack-fabric/routing/lib/region-polygons.js`.
enum RegionPolygons {
    private struct BBox {
        var minLon: Double
        var minLat: Double
        var maxLon: Double
        var maxLat: Double
        var area: Double { max(0, maxLon - minLon) * max(0, maxLat - minLat) }
        func contains(lon: Double, lat: Double) -> Bool {
            lon >= minLon && lon <= maxLon && lat >= minLat && lat <= maxLat
        }
    }

    private static let geometries: [String: [String: Any]] = {
        let url = Bundle.main.url(forResource: "RegionPolygons", withExtension: "json")
            ?? Bundle(for: BundleToken.self).url(forResource: "RegionPolygons", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let regions = root["regions"] as? [String: [String: Any]]
        else { return [:] }
        return regions
    }()

    private static let bboxes: [String: BBox] = {
        var out: [String: BBox] = [:]
        for (id, geom) in geometries {
            if let box = geometryBbox(geom) { out[id] = box }
        }
        return out
    }()

    static func contains(_ regionId: String, longitude lon: Double, latitude lat: Double) -> Bool {
        guard let geom = geometries[regionId.lowercased()],
              let type = geom["type"] as? String
        else { return false }
        if let box = bboxes[regionId.lowercased()], !box.contains(lon: lon, lat: lat) {
            return false
        }
        return pointInGeometry(lon: lon, lat: lat, type: type, coordinates: geom["coordinates"])
    }

    /// Admin-polygon owner. Nil when the point is in none of the loaded polygons.
    static func polygonOwner(longitude lon: Double, latitude lat: Double) -> String? {
        var hits: [String] = []
        for id in geometries.keys where contains(id, longitude: lon, latitude: lat) {
            hits.append(id)
        }
        if hits.isEmpty { return nil }
        if hits.count == 1 { return hits[0] }
        if hits.contains("ns"), hits.contains("nb") {
            return lon >= -64.27 ? "ns" : "nb"
        }
        let onHalves = hits.filter { $0 == "on-s" || $0 == "on-n" }
        if !onHalves.isEmpty {
            if lat >= 46.0, onHalves.contains("on-n") { return "on-n" }
            if lat < 46.0, onHalves.contains("on-s") { return "on-s" }
            return onHalves[0]
        }
        let qcHalves = hits.filter { $0 == "qc-s" || $0 == "qc-n" }
        if !qcHalves.isEmpty {
            if lat >= 49.0, qcHalves.contains("qc-n") { return "qc-n" }
            if lat < 49.0, qcHalves.contains("qc-s") { return "qc-s" }
            return qcHalves[0]
        }
        let caHalves = hits.filter { $0 == "ca-s" || $0 == "ca-n" }
        if !caHalves.isEmpty {
            if lat >= 37.0, caHalves.contains("ca-n") { return "ca-n" }
            if lat < 37.0, caHalves.contains("ca-s") { return "ca-s" }
            return caHalves[0]
        }
        let nlHalves = hits.filter { $0 == "nl-island" || $0 == "nl-lab" }
        if !nlHalves.isEmpty {
            if lon <= -56.8, nlHalves.contains("nl-lab") { return "nl-lab" }
            if lon > -56.8, nlHalves.contains("nl-island") { return "nl-island" }
            return nlHalves[0]
        }
        hits.sort { (bboxes[$0]?.area ?? .infinity) < (bboxes[$1]?.area ?? .infinity) }
        return hits[0]
    }

    /// Alias kept for lockstep with live `maritimesOwner`.
    static func maritimesOwner(longitude lon: Double, latitude lat: Double) -> String? {
        polygonOwner(longitude: lon, latitude: lat)
    }

    private static func geometryBbox(_ geom: [String: Any]) -> BBox? {
        var minLon = Double.infinity
        var minLat = Double.infinity
        var maxLon = -Double.infinity
        var maxLat = -Double.infinity
        func walk(_ raw: Any?) {
            guard let raw else { return }
            if let pair = raw as? [Any], pair.count >= 2,
               let lon = (pair[0] as? NSNumber)?.doubleValue,
               let lat = (pair[1] as? NSNumber)?.doubleValue,
               !(pair[0] is [Any]) {
                if lon < minLon { minLon = lon }
                if lat < minLat { minLat = lat }
                if lon > maxLon { maxLon = lon }
                if lat > maxLat { maxLat = lat }
                return
            }
            if let list = raw as? [Any] {
                for child in list { walk(child) }
            }
        }
        walk(geom["coordinates"])
        guard minLon.isFinite else { return nil }
        return BBox(minLon: minLon, minLat: minLat, maxLon: maxLon, maxLat: maxLat)
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
