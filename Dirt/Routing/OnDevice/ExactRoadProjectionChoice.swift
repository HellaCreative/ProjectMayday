import CoreLocation

/// The existing per-road projection minimum, independent of direction/profile
/// ranking. Strict improvement preserves the first segment on an exact tie.
nonisolated struct ExactRoadProjectionChoice {
    struct Value {
        let distance: Double, along: Double
        let segment: Int
        let projected: CLLocationCoordinate2D
    }
    private(set) var value: Value?
    @inline(__always) mutating func consider(distance: Double,maximum: Double,along: Double,
        segment: Int,projected: CLLocationCoordinate2D) {
        guard distance <= maximum else { return }
        if let previous = value, !(distance < previous.distance) { return }
        value = Value(distance: distance,along: along,segment: segment,projected: projected)
    }
}
