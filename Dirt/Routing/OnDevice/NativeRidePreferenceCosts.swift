import Foundation

/// Existing ride-preferences.js coefficients, in native per-kilometre units.
/// These preference charges leave legal eligibility and profile surface costs intact.
nonisolated enum NativeRidePreferenceCosts {
    static func distancePenalty(_ preferences: RidePreferences) -> Double {
        30 * pow(1 - preferences.normalized.wander, 2)
    }

    static func edgeCost(base: Double, meters: Double, roadClass: String,
                         preferences: RidePreferences) -> Double {
        let major = ["motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link", "freeway"].contains(roadClass)
        return (base + meters / 1_000 * distancePenalty(preferences))
            * (preferences.avoidHighways && major ? 10 : 1)
    }

    static func dirtCandidateCost(meters: Double, dirtMeters: Double,
                                  preferences: RidePreferences) -> Double {
        let dirt = min(meters, max(0, dirtMeters))
        return ((meters - dirt) * HopSearchPolicy.dirtRidePavedPerKm
            + dirt * HopSearchPolicy.dirtRideGravelPerKm
            + meters * distancePenalty(preferences)) / 1_000
    }
}
