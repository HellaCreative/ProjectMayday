import Foundation

/// A stored chosen itinerary, not a request to regenerate one. Flat SavedRoute
/// fields remain available for legacy/imported records and unknown versions.
struct SavedRoutingPlan: Codable, Sendable {
    struct FuelSettings: Codable, Equatable, Sendable {
        let tankMeters: Double
        let usableMeters: Double
        let reservePercent: Double
        let automaticPlanningEnabled: Bool

        init(_ value: FuelRangePrefs.Snapshot) {
            tankMeters = value.tankMeters
            usableMeters = value.usableMeters
            reservePercent = value.reservePercent
            automaticPlanningEnabled = value.automaticPlanningEnabled
        }

        var snapshot: FuelRangePrefs.Snapshot {
            .init(tankMeters: tankMeters, usableMeters: usableMeters,
                  reservePercent: reservePercent, automaticPlanningEnabled: automaticPlanningEnabled)
        }
    }

    let version: Int
    let itinerary: RiderItinerary
    let built: BuiltItinerary
    let ridePreferences: RidePreferences?
    let fuel: FuelSettings
    let profile: RouteProfile
    let allowUnknown: Bool
    let avoidMotorways: Bool
    let preferBackRoads: Bool
    let sourceMode: String
    let loopDistanceKM: Double
    let loopDirection: String
    let loopSummary: String?
    let loopAnchor: RouteCoordinate?

    init(itinerary: RiderItinerary, built: BuiltItinerary,
         ridePreferences: RidePreferences?, fuel: FuelRangePrefs.Snapshot,
         profile: RouteProfile, allowUnknown: Bool, avoidMotorways: Bool, preferBackRoads: Bool,
         sourceMode: String, loopDistanceKM: Double, loopDirection: String,
         loopSummary: String?) {
        version = 1
        self.itinerary = itinerary
        self.built = built
        self.ridePreferences = ridePreferences
        self.fuel = FuelSettings(fuel)
        self.profile = profile
        self.allowUnknown = allowUnknown
        self.avoidMotorways = avoidMotorways
        self.preferBackRoads = preferBackRoads
        self.sourceMode = sourceMode
        self.loopDistanceKM = loopDistanceKM
        self.loopDirection = loopDirection
        self.loopSummary = loopSummary
        loopAnchor = sourceMode == "loop" ? itinerary.waypoints.first?.coordinate : nil
    }

    var isSupported: Bool {
        guard version == 1, ["From here", "Plan a route", "loop"].contains(sourceMode),
              LoopDirection(rawValue: loopDirection) != nil,
              built.generation == itinerary.generation,
              itinerary.waypoints.count >= 2,
              itinerary.legs.count == itinerary.waypoints.count - 1,
              fuel.tankMeters.isFinite, fuel.usableMeters.isFinite,
              fuel.reservePercent.isFinite, fuel.tankMeters >= 0,
              fuel.usableMeters >= 0, fuel.usableMeters <= fuel.tankMeters,
              fuel.reservePercent >= 0, fuel.reservePercent <= 100 else { return false }
        let pointIDs = Set(itinerary.waypoints.map(\.id))
        let legIDs = Set(itinerary.legs.map(\.id))
        guard pointIDs.count == itinerary.waypoints.count,
              legIDs.count == itinerary.legs.count,
              built.legs.allSatisfy({ legIDs.contains($0.riderLegID) }),
              built.riderLegStatus.keys.allSatisfy({ legIDs.contains($0) }),
              built.riderRoutes.keys.allSatisfy({ legIDs.contains($0) }) else { return false }
        return itinerary.legs.enumerated().allSatisfy { index, leg in
            leg.from == itinerary.waypoints[index].id && leg.to == itinerary.waypoints[index + 1].id
        }
    }

    static func decode(_ data: Data?) -> SavedRoutingPlan? {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data),
              value.isSupported else { return nil }
        return value
    }
}
