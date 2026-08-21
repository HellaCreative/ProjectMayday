import Foundation

nonisolated enum ItineraryAction: Equatable, Codable, Sendable {
    case append(coordinate: RouteCoordinate)
    case insert(afterLegID: UUID, coordinate: RouteCoordinate)
    case move(waypointID: UUID, to: RouteCoordinate)
    case delete(waypointID: UUID)
    case setProfile(legID: UUID?, RouteProfile)
    case setHopProfile(legID: UUID, stationID: String, RouteProfile)
    case setAllowUnknown(legID: UUID?, Bool)
    case markImpassable(edgeIDs: Set<String>)
    case replaceAll(
        waypoints: [RouteCoordinate],
        profile: RouteProfile,
        allowUnknown: Bool
    )
    case clear
    case rebuild
}
