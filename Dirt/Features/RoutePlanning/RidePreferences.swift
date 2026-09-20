import Foundation

/// A route-build snapshot; nil keeps the accepted profile defaults.
nonisolated struct RidePreferences: Codable, Equatable, Hashable, Sendable {
    var preferDifferentRoads: Bool?
    var wander: Double = 0.5
    var avoidCities: Bool = true
    var avoidHighways: Bool = true
    var avoidFerries: Bool = true

    var normalized: Self {
        var copy = self
        copy.wander = wander.isFinite ? min(1, max(0, wander)) : 0.5
        return copy
    }
}

nonisolated enum RidePreferenceContext {
    @TaskLocal static var current: RidePreferences?
}

/// Fresh generation seed for a new create. Saved/resume/nav freeze it.
nonisolated enum RoutingSessionContext {
    @TaskLocal static var seed: UInt64?
}

// Older saves predate ferry avoidance. Preserve their existing settings when
// decoding the new preference rather than rejecting the whole snapshot.
extension RidePreferences {
    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        preferDifferentRoads = try values.decodeIfPresent(Bool.self, forKey: .preferDifferentRoads)
        wander = try values.decodeIfPresent(Double.self, forKey: .wander) ?? 0.5
        avoidCities = try values.decodeIfPresent(Bool.self, forKey: .avoidCities) ?? true
        avoidHighways = try values.decodeIfPresent(Bool.self, forKey: .avoidHighways) ?? true
        avoidFerries = try values.decodeIfPresent(Bool.self, forKey: .avoidFerries) ?? true
    }
}
