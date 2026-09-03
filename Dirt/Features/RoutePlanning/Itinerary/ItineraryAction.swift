import Foundation

nonisolated enum ItineraryAction: Equatable, Codable, Sendable {
    case append(coordinate: RouteCoordinate)
    case insert(afterLegID: UUID, coordinate: RouteCoordinate)
    case move(waypointID: UUID, to: RouteCoordinate)
    case delete(waypointID: UUID)
    case setProfile(legID: UUID?, RouteProfile)
    case setHopProfile(legID: UUID, stationID: String, RouteProfile)
    case setHopAvoidMotorways(legID: UUID, stationID: String, Bool)
    case setHopAllowUnknown(legID: UUID, stationID: String, Bool)
    case setFuelStopOverride(legID: UUID, departureAnchorID: String, stationID: String)
    case clearFuelStopOverrides(legID: UUID)
    case setAllowUnknown(legID: UUID?, Bool)
    case setAvoidMotorways(legID: UUID?, Bool)
    case setPreferBackRoads(legID: UUID?, Bool)
    case markImpassable(edgeIDs: Set<String>)
    case replaceAll(
        waypoints: [RouteCoordinate],
        profile: RouteProfile,
        allowUnknown: Bool,
        avoidMotorways: Bool,
        preferBackRoads: Bool
    )
    case clear
    case rebuild
}
