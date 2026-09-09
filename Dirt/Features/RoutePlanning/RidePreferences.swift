import Foundation

/// A route-build snapshot; nil keeps the accepted profile defaults.
nonisolated struct RidePreferences: Codable, Equatable, Hashable, Sendable {
    var wander: Double = 1
    var avoidCities: Bool = true
    var avoidHighways: Bool = false

    var normalized: Self {
        var copy = self
        copy.wander = wander.isFinite ? min(1, max(0, wander)) : 1
        return copy
    }
}

nonisolated enum RidePreferenceContext {
    @TaskLocal static var current: RidePreferences?
}
