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
        hits.sort { (bboxes[$0]?.area ?? .infinity) < (bboxes[$1]?.area ?? .infinity) }
        return hits[0]
    }

    /// Alias kept for lockstep with live `maritimesOwner`.
    static func maritimesOwner(longitude lon: Double, latitude lat: Double) -> String? {
        polygonOwner(longitude: lon, latitude: lat)
    }

    /// Outer-ring outlines for low-zoom province/state borders. Display only —
    /// Shortbread tile lines do not exist below zoom 7.
    static func lowZoomOutlineRings(stride: Int = 8) -> [(regionId: String, coordinates: [[Double]])] {
        let step = max(1, stride)
        var out: [(String, [[Double]])] = []
        for (id, geom) in geometries {
            let type = geom["type"] as? String ?? ""
            var rings: [[[Double]]] = []
            if type == "Polygon", let one = asRings(geom["coordinates"]) {
                rings = one
            } else if type == "MultiPolygon", let many = asMultiRings(geom["coordinates"]) {
                rings = many.compactMap(\.first)
            }
            for ring in rings {
                guard ring.count >= 4 else { continue }
                var simplified: [[Double]] = []
                simplified.reserveCapacity(ring.count / step + 2)
                for (index, point) in ring.enumerated() where index % step == 0 || index == ring.count - 1 {
                    if simplified.last != point { simplified.append(point) }
                }
                if simplified.count >= 2 { out.append((id, simplified)) }
            }
        }
        return out
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
