import CoreLocation
import Foundation

/// Result of projecting a GPS location onto a route polyline.
struct PolylineProjection {
    /// Perpendicular distance from the location to the nearest segment (metres).
    let offMeters: Double
    /// Cumulative along-route distance to the projected point (metres).
    let alongMeters: Double
    /// Zero-based index of the segment the projection falls on.
    let segmentIndex: Int
}

/// Pure geometry helpers — opted out of `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// so nav cues / on-device routing can call these off the main actor.
nonisolated enum GeoMath {
    static func meters(_ a: RouteCoordinate, _ b: RouteCoordinate) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    static func lineMeters(_ coordinates: [RouteCoordinate]) -> Double {
        guard coordinates.count > 1 else { return 0 }
        var total = 0.0
        for index in 1..<coordinates.count {
            total += meters(coordinates[index - 1], coordinates[index])
        }
        return total
    }

    /// Cumulative distance at each vertex, in meters.
    static func cumulativeMeters(_ coordinates: [RouteCoordinate]) -> [Double] {
        guard !coordinates.isEmpty else { return [] }
        var result = [0.0]
        result.reserveCapacity(coordinates.count)
        for index in 1..<coordinates.count {
            result.append(result[index - 1] + meters(coordinates[index - 1], coordinates[index]))
        }
        return result
    }

    static func nearestVertex(to location: CLLocation, in coordinates: [RouteCoordinate]) -> (index: Int, meters: Double)? {
        guard !coordinates.isEmpty else { return nil }
        var bestIndex = 0
        var bestMeters = Double.greatestFiniteMagnitude
        for (index, coordinate) in coordinates.enumerated() {
            let d = location.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            if d < bestMeters {
                bestMeters = d
                bestIndex = index
            }
        }
        return (bestIndex, bestMeters)
    }

    /// Projects `location` onto the segment [a, b] and returns the clamped
    /// nearest point and its Haversine distance in metres.
    /// Uses an equirectangular approximation — accurate to within ~1 % for
    /// segments ≤ 50 km (more than sufficient for a 500 m snap radius).
    static func projectPoint(
        _ location: CLLocation,
        ontoSegmentFrom a: RouteCoordinate,
        to b: RouteCoordinate
    ) -> (coordinate: RouteCoordinate, meters: Double) {
        let lat0 = (a.latitude + b.latitude) / 2 * .pi / 180
        let cos0 = cos(lat0)

        let ax = a.longitude * cos0, ay = a.latitude
        let bx = b.longitude * cos0, by = b.latitude
        let px = location.coordinate.longitude * cos0, py = location.coordinate.latitude

        let dx = bx - ax, dy = by - ay
        let lenSq = dx * dx + dy * dy
        let t: Double = lenSq < 1e-18 ? 0 : max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / lenSq))

        let projLon = (ax + t * dx) / cos0
        let projLat = ay + t * dy
        let proj = RouteCoordinate(longitude: projLon, latitude: projLat)
        let dist = location.distance(from: CLLocation(latitude: projLat, longitude: projLon))
        return (proj, dist)
    }

    /// Nearest point on the polyline (on a segment, not just at vertices)
    /// within `maxMeters`.  Returns nil when the polyline is empty or every
    /// segment is farther than `maxMeters`.
    static func nearestPointOnPolyline(
        _ location: CLLocation,
        in coordinates: [RouteCoordinate],
        maxMeters: Double = .infinity
    ) -> (coordinate: RouteCoordinate, meters: Double)? {
        guard coordinates.count > 1 else {
            guard let only = coordinates.first else { return nil }
            let d = location.distance(from: CLLocation(latitude: only.latitude, longitude: only.longitude))
            return d <= maxMeters ? (only, d) : nil
        }
        var bestMeters = Double.greatestFiniteMagnitude
        var bestCoord: RouteCoordinate?
        for i in 0..<(coordinates.count - 1) {
            let (proj, dist) = projectPoint(location, ontoSegmentFrom: coordinates[i], to: coordinates[i + 1])
            if dist < bestMeters {
                bestMeters = dist
                bestCoord = proj
            }
        }
        guard let coord = bestCoord, bestMeters <= maxMeters else { return nil }
        return (coord, bestMeters)
    }

    /// Projects `location` onto the nearest segment of the polyline and returns
    /// a `PolylineProjection` containing the perpendicular off-route distance
    /// AND the along-route distance to the projected point.
    ///
    /// This is the correct primitive for off-route detection: it avoids false
    /// alerts caused by `nearestVertex` measuring to discrete vertices rather
    /// than to the actual line between them. A rider mid-segment on a curved
    /// road can sit 50+ m from the nearest vertex while being directly on the
    /// road surface — vertex-only distance triggers spurious off-route alarms.
    ///
    /// `cumulative` must have the same count as `coordinates` and contain the
    /// cumulative haversine distance (metres) at each vertex as produced by
    /// `GeoMath.cumulativeMeters(_:)`.
    static func nearestProjection(
        to location: CLLocation,
        in coordinates: [RouteCoordinate],
        cumulative: [Double]
    ) -> PolylineProjection? {
        guard coordinates.count > 1, cumulative.count == coordinates.count else { return nil }
        var bestOff = Double.greatestFiniteMagnitude
        var bestAlong = 0.0
        var bestSegment = 0
        for i in 0..<(coordinates.count - 1) {
            let a = coordinates[i], b = coordinates[i + 1]
            // Equirectangular projection — same as projectPoint, so consistent.
            let lat0 = (a.latitude + b.latitude) / 2 * .pi / 180
            let cos0 = cos(lat0)
            let ax = a.longitude * cos0, ay = a.latitude
            let bx = b.longitude * cos0, by = b.latitude
            let px = location.coordinate.longitude * cos0, py = location.coordinate.latitude
            let dx = bx - ax, dy = by - ay
            let lenSq = dx * dx + dy * dy
            let t: Double = lenSq < 1e-18 ? 0 : max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / lenSq))
            let projLon = (ax + t * dx) / cos0
            let projLat = ay + t * dy
            let dist = location.distance(from: CLLocation(latitude: projLat, longitude: projLon))
            if dist < bestOff {
                bestOff = dist
                let segLen = cumulative[i + 1] - cumulative[i]
                bestAlong = cumulative[i] + t * segLen
                bestSegment = i
            }
        }
        guard bestOff < Double.greatestFiniteMagnitude else { return nil }
        return PolylineProjection(offMeters: bestOff, alongMeters: bestAlong, segmentIndex: bestSegment)
    }
}
