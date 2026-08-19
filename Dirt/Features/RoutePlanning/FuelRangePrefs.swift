import Foundation

/// Rider tank range for Plan fuel-assist. `0` disables auto gas waypoints.
enum FuelRangePrefs {
    static let key = "dirt.rider.fuelRangeKm"
    /// Sensible dual-sport default when the rider enables the control blank.
    static let suggestedDefaultKm: Double = 200
    static let minimumKm: Double = 40
    static let maximumKm: Double = 500

    static var kilometers: Double {
        get {
            let raw = UserDefaults.standard.object(forKey: key) as? Double
            return raw ?? 0
        }
        set {
            let clamped: Double
            if newValue <= 0 {
                clamped = 0
            } else {
                clamped = min(maximumKm, max(minimumKm, newValue))
            }
            UserDefaults.standard.set(clamped, forKey: key)
        }
    }

    static var isEnabled: Bool { kilometers > 0 }
}
