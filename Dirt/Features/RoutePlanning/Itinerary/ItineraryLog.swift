import Foundation

nonisolated enum ItineraryLog {
    static func line(
        action: ItineraryAction,
        before: RiderItinerary,
        after: RiderItinerary,
        source: String? = nil
    ) -> String {
        let sourceSuffix = source.map { " source=\($0)" } ?? ""
        let generation = "gen=\(before.generation)→\(after.generation)"
        switch action {
        case .insert(let legID, _):
            return "itinerary action=insert afterLeg=\(legID.uuidString) \(generation) before=\(coordinates(before)) after=\(coordinates(after))\(sourceSuffix)"
        case .move(let waypointID, _):
            return "itinerary action=move id=\(waypointID.uuidString) \(generation) before=\(coordinates(before)) after=\(coordinates(after))\(sourceSuffix)"
        case .delete(let waypointID):
            return "itinerary action=delete id=\(waypointID.uuidString) \(generation) before=\(coordinates(before)) after=\(coordinates(after))\(sourceSuffix)"
        case .append:
            return "itinerary action=append \(generation) before=\(coordinates(before)) after=\(coordinates(after))\(sourceSuffix)"
        case .setProfile(let legID, let profile):
            return "itinerary action=setProfile leg=\(legID?.uuidString ?? "all") profile=\(profile.rawValue) \(generation)\(sourceSuffix)"
        case .setHopProfile(let legID, let stationID, let profile):
            return "fuel hop override station=\(stationID) profile=\(profile.rawValue) replanFrom=\(stationID) riderLeg=\(legID.uuidString) \(generation)\(sourceSuffix)"
        case .setFuelStopOverride(let legID, let departureAnchorID, let stationID):
            return "fuel stop override riderLeg=\(legID.uuidString) from=\(departureAnchorID) to=\(stationID) \(generation)\(sourceSuffix)"
        case .clearFuelStopOverrides(let legID):
            return "fuel stop override revert riderLeg=\(legID.uuidString) \(generation)\(sourceSuffix)"
        case .setAllowUnknown(let legID, let allow):
            return "itinerary action=setAllowUnknown leg=\(legID?.uuidString ?? "all") allow=\(allow) \(generation)\(sourceSuffix)"
        case .markImpassable(let edgeIDs):
            return "itinerary action=markImpassable edges=\(edgeIDs.sorted().joined(separator: ",")) \(generation)\(sourceSuffix)"
        case .replaceAll:
            return "itinerary action=replaceAll \(generation) before=\(coordinates(before)) after=\(coordinates(after))\(sourceSuffix)"
        case .clear:
            return "itinerary action=clear \(generation)\(sourceSuffix)"
        case .rebuild:
            return "itinerary action=rebuild \(generation)\(sourceSuffix)"
        }
    }

    private static func coordinates(_ itinerary: RiderItinerary) -> String {
        let body = itinerary.waypoints.map {
            String(format: "%.6f,%.6f", $0.coordinate.latitude, $0.coordinate.longitude)
        }.joined(separator: ";")
        return "[\(body)]"
    }
}
