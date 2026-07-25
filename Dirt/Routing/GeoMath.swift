import CoreLocation
import Foundation

enum GeoMath {
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
}
