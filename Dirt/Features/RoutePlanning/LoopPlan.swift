import CoreLocation
import Foundation

/// Clockwise compass choices; north is the default without any map interaction.
nonisolated enum LoopDirection: String, CaseIterable, Identifiable {
    case north = "North", northeast = "Northeast", east = "East", southeast = "Southeast"
    case south = "South", southwest = "Southwest", west = "West", northwest = "Northwest"

    var id: String { rawValue }
    var bearing: Double { Double(Self.allCases.firstIndex(of: self)!) * .pi / 4 }
    func guide(from start: RouteCoordinate) -> RouteCoordinate {
        LoopPlan.point(from: start, meters: 10_000, bearing: bearing)
    }
}

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
        // Three sides around a centre ahead of the rider, in both travel directions.
        // Broad circuits offer independent outward and return corridors.
        let heading = bearing(from: start, toward: direction)
        let radius = targetMeters / (2 * .pi * 1.35)
        let centre = point(from: start, meters: radius, bearing: heading)
        let width = variant % 3 == 1 ? 1.25 : 1.0
        let left = point(from: centre, meters: radius * width, bearing: heading - .pi / 2)
        let far = point(from: centre, meters: radius, bearing: heading)
        let right = point(from: centre, meters: radius * width, bearing: heading + .pi / 2)
        return variant % 2 == 0 ? [start, left, far, right, start] : [start, right, far, left, start]
    }

    /// Area retained by the actual circuit relative to its convex hull. A folded
    /// route loses signed area, even when its branches use nearby parallel roads.
    static func circuitFill(paths: [[RouteCoordinate]]) -> Double {
        let coordinates = paths.flatMap { $0 }
        guard let origin = coordinates.first, coordinates.count > 3 else { return 0 }
        struct Point: Equatable { let x: Double; let y: Double }
        let scale = cos(origin.latitude * .pi / 180)
        let points = coordinates.map { Point(x: ($0.longitude - origin.longitude) * scale,
                                             y: $0.latitude - origin.latitude) }
        func cross(_ a: Point, _ b: Point, _ c: Point) -> Double {
            (b.x-a.x)*(c.y-a.y) - (b.y-a.y)*(c.x-a.x)
        }
        func area(_ p: [Point]) -> Double {
            guard p.count > 2 else { return 0 }
            return abs(p.indices.reduce(0) { result, i in
                let next = p[(i+1) % p.count]
                return result + p[i].x * next.y - next.x * p[i].y
            }) / 2
        }
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        var lower: [Point] = [], upper: [Point] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count-2], lower[lower.count-1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count-2], upper[upper.count-1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        let hullArea = area(Array(lower.dropLast()) + Array(upper.dropLast()))
        return hullArea > 0 ? min(1, area(points) / hullArea) : 0
    }

    static func acceptable(distance: Double, repeated: Double, fill: Double, target: Double? = nil) -> Bool {
        let fitsDistance = target.map { distance >= $0 * 0.5 && distance <= $0 * 1.5 } ?? true
        return fitsDistance && distance > 0 && repeated <= max(3000, distance * 0.15) && fill >= 0.35
    }

    /// Compare whole circuits. Repeated physical geometry is counted irrespective of direction.
    static func repeatedMeters(paths: [[RouteCoordinate]]) -> Double {
        var seen = Set<String>(), repeated = 0.0
        var previous: String?
        var repeatingCell = false
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
                        repeatingCell = seen.contains(key)
                        seen.insert(key)
                    }
                    if repeatingCell { repeated += length / Double(steps) }
                    previous = key
                }
            }
        }
        return repeated
    }

    static func score(distance: Double, repeated: Double, target: Double, reusedStops: Int, fill: Double = 1) -> Double {
        abs(distance - target) / max(target, 1) + 8 * repeated / max(distance, 1) + 2 * (1 - fill) + Double(reusedStops) * 0.2
    }
}
