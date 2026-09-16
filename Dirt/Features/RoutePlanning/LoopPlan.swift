import CoreLocation
import Foundation

/// Compass helpers for placing a far pin relative to the start. Circuit geometry
/// is chosen by the ride (`LoopPlanner`); this type does not invent a far point.
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
}
