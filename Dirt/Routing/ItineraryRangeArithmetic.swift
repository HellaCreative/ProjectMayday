import Foundation

nonisolated enum ItineraryRangeArithmetic {
    static let fuelWaypointSnapMeters = 150.0
    static func comfortCapMeters(
        firstLegMaxMeters: Double,
        usableRangeMeters: Double
    ) -> Double {
        guard usableRangeMeters > 0, firstLegMaxMeters >= 0 else { return 0 }
        return min(firstLegMaxMeters, usableRangeMeters)
    }

    static func fuelStopCountNeeded(
        profileMeters: Double,
        firstLegMaxMeters: Double,
        usableRangeMeters: Double
    ) -> Int {
        guard profileMeters.isFinite, profileMeters >= 0, usableRangeMeters > 0 else { return 0 }
        let firstCap = min(firstLegMaxMeters, usableRangeMeters)
        if profileMeters > firstCap + 1 {
            return Int(ceil((profileMeters - firstCap) / usableRangeMeters))
        }
        // Crossing the watch or preferred zone never manufactures a stop. A
        // reachable destination wins unless its destination-escape requirement
        // proves that a prior refuel is necessary.
        return 0
    }
}
