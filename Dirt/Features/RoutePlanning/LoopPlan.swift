import CoreLocation
import Foundation

/// Candidate geometry only; every segment is subsequently routed and fuel-checked.
nonisolated enum LoopPlan {
    static func bearing(from a: RouteCoordinate, toward b: RouteCoordinate) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let delta = (b.longitude - a.longitude) * .pi / 180
        return atan2(sin(delta) * cos(lat2), cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(delta))
    }

    static func point(from start: RouteCoordinate, meters: Double, bearing: Double) -> RouteCoordinate {
        let arc = meters / 6_371_000, lat = start.latitude * .pi / 180, lon = start.longitude * .pi / 180
        let nextLat = asin(sin(lat) * cos(arc) + cos(lat) * sin(arc) * cos(bearing))
        let nextLon = lon + atan2(sin(bearing) * sin(arc) * cos(lat), cos(arc) - sin(lat) * sin(nextLat))
        return RouteCoordinate(longitude: (nextLon * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180,
                               latitude: nextLat * 180 / .pi)
    }

    static func anchors(start: RouteCoordinate, direction: RouteCoordinate, targetMeters: Double, variant: Int) -> [RouteCoordinate] {
        let spread = [30.0, 55.0, 40.0][variant % 3] * .pi / 180
        let radius = targetMeters / ((2 + 2 * sin(spread)) * 1.45)
        let heading = bearing(from: start, toward: direction)
        let a = point(from: start, meters: radius, bearing: heading - spread)
        let b = point(from: start, meters: radius, bearing: heading + spread)
        return variant == 2 ? [start, b, a, start] : [start, a, b, start]
    }

    /// Compare whole circuits. Repeated physical geometry is counted irrespective of direction.
    static func repeatedMeters(paths: [[RouteCoordinate]]) -> Double {
        var seen = Set<String>(), repeated = 0.0
        var previous: String?
        for path in paths {
            for (a, b) in zip(path, path.dropFirst()) {
                let length = CLLocation(latitude: a.latitude, longitude: a.longitude)
                    .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
                guard length > 0 else { continue }
                let steps = max(1, Int(ceil(length / 25)))
                for step in 0..<steps {
                    let fraction = (Double(step) + 0.5) / Double(steps)
                    let lat = a.latitude + (b.latitude - a.latitude) * fraction
                    let lon = a.longitude + (b.longitude - a.longitude) * fraction
                    let key = "\(Int((lat * 111_195 / 30).rounded())):\(Int((lon * 111_195 * cos(lat * .pi / 180) / 30).rounded()))"
                    if key != previous {
                        if seen.contains(key) { repeated += length / Double(steps) }
                        seen.insert(key)
                    }
                    previous = key
                }
            }
        }
        return repeated
    }

    static func score(distance: Double, repeated: Double, target: Double, reusedStops: Int) -> Double {
        abs(distance - target) / max(target, 1) + 4 * repeated / max(distance, 1) + Double(reusedStops) * 0.1
    }
}
