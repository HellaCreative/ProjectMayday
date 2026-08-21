import Foundation

/// Rider tank range used by every navigable itinerary.
enum FuelRangePrefs {
    nonisolated struct Snapshot: Equatable, Sendable {
        let tankMeters: Double
        let usableMeters: Double
        let reservePercent: Double

        init(
            tankMeters: Double,
            usableMeters: Double,
            reservePercent: Double
        ) {
            self.tankMeters = tankMeters
            self.usableMeters = usableMeters
            self.reservePercent = reservePercent
        }

        /// Internal route-only diagnostics retain a zero-range snapshot so the
        /// benchmark can isolate routing from fuel-chain behaviour. Product UI
        /// never selects this state.
        static let routeOnly = Snapshot(
            tankMeters: 0,
            usableMeters: 0,
            reservePercent: 0
        )
    }
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
            guard let raw, raw > 0 else { return lastEnabledKilometers }
            return min(maximumKm, max(minimumKm, raw))
        }
        set {
            let clamped = newValue > 0
                ? min(maximumKm, max(minimumKm, newValue))
                : lastEnabledKilometers
            UserDefaults.standard.set(clamped, forKey: key)
        }
    }

    static var snapshot: Snapshot {
        let tankKm = kilometers
        let reserve = reservePercent
        return Snapshot(
            tankMeters: tankKm * 1_000,
            usableMeters: usableKilometers(for: tankKm, reservePercent: reserve) * 1_000,
            reservePercent: reserve
        )
    }

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

    /// Migration fallback for riders whose older toggle stored a zero range.
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
