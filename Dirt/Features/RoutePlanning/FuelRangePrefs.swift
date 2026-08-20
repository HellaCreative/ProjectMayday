import Foundation

/// Rider tank range for Plan fuel-assist. `0` disables auto gas waypoints.
enum FuelRangePrefs {
    static let key = "dirt.rider.fuelRangeKm"
    static let lastEnabledKey = "dirt.rider.lastEnabledFuelRangeKm"
    static let reservePercentKey = "dirt.rider.fuelReservePercent"
    /// Sensible dual-sport default when the rider enables the control blank.
    static let suggestedDefaultKm: Double = 200
    static let minimumKm: Double = 40
    static let maximumKm: Double = 500
    static let suggestedReservePercent: Double = 10
    static let minimumReservePercent: Double = 0
    static let maximumReservePercent: Double = 30

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

    /// Range held back for wind, elevation, closures, and station uncertainty.
    /// The rider enters real tank range; fuel planning uses the remainder.
    static var reservePercent: Double {
        get {
            guard let raw = UserDefaults.standard.object(forKey: reservePercentKey) as? Double else {
                return suggestedReservePercent
            }
            return min(maximumReservePercent, max(minimumReservePercent, raw))
        }
        set {
            let clamped = min(maximumReservePercent, max(minimumReservePercent, newValue))
            UserDefaults.standard.set(clamped, forKey: reservePercentKey)
        }
    }

    static func usableKilometers(for tankKilometers: Double, reservePercent: Double? = nil) -> Double {
        guard tankKilometers > 0 else { return 0 }
        let reserve = min(
            maximumReservePercent,
            max(minimumReservePercent, reservePercent ?? self.reservePercent)
        )
        return tankKilometers * (1 - reserve / 100)
    }

    /// Turning fuel assist off must not erase the rider's tank setting. The
    /// zero value only means disabled; this stores the last real slider value.
    static var lastEnabledKilometers: Double {
        get {
            let raw = UserDefaults.standard.object(forKey: lastEnabledKey) as? Double
            guard let raw, raw > 0 else { return suggestedDefaultKm }
            return min(maximumKm, max(minimumKm, raw))
        }
        set {
            guard newValue > 0 else { return }
            let clamped = min(maximumKm, max(minimumKm, newValue))
            UserDefaults.standard.set(clamped, forKey: lastEnabledKey)
        }
    }
}
