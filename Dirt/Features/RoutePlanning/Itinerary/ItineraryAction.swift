import Foundation

nonisolated enum ItineraryAction: Equatable, Codable, Sendable {
    case append(coordinate: RouteCoordinate)
    case insert(afterLegID: UUID, coordinate: RouteCoordinate)
    case move(waypointID: UUID, to: RouteCoordinate)
    case delete(waypointID: UUID)
    case setProfile(legID: UUID?, RouteProfile)
    case setAllowUnknown(legID: UUID?, Bool)
    case markImpassable(edgeIDs: Set<String>)
    case replaceAll(
        waypoints: [RouteCoordinate],
        profile: RouteProfile,
        allowUnknown: Bool
    )
    case clear
    case rebuild
    case replaceFuelStop(
        id: UUID,
        stationID: String,
        coordinate: RouteCoordinate,
        name: String?
    )
    case setHopProfile(
        id: UUID,
        riderLegID: UUID,
        sequence: Int,
        RouteProfile
    )
    case setHopAllowUnknown(
        id: UUID,
        riderLegID: UUID,
        sequence: Int,
        Bool
    )
}
