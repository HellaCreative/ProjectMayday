import Foundation

nonisolated struct ItineraryChange: Equatable, Sendable {
    let itinerary: RiderItinerary
    let rebuildFromLegIndex: Int?
}

nonisolated func reduce(
    _ itinerary: RiderItinerary,
    _ action: ItineraryAction
) -> ItineraryChange {
    switch action {
    case .append(let coordinate):
        var waypoints = itinerary.waypoints
        waypoints.append(RiderWaypoint(coordinate: coordinate))
        let legs = rebuiltLegs(
            waypoints: waypoints,
            preserving: itinerary.legs,
            fallbackProfile: itinerary.legs.last?.profile ?? .balanced,
            fallbackAllowUnknown: itinerary.legs.last?.allowUnknown ?? false
        )
        return changed(
            itinerary,
            waypoints: waypoints,
            legs: legs,
            rebuildFrom: legs.isEmpty ? nil : legs.count - 1
        )

    case .insert(let afterLegID, let coordinate):
        guard let legIndex = itinerary.legs.firstIndex(where: { $0.id == afterLegID }) else {
            return unchanged(itinerary)
        }
        let split = itinerary.legs[legIndex]
        var waypoints = itinerary.waypoints
        waypoints.insert(RiderWaypoint(coordinate: coordinate), at: legIndex + 1)
        let legs = rebuiltLegs(
            waypoints: waypoints,
            preserving: itinerary.legs,
            fallbackProfile: split.profile,
            fallbackAllowUnknown: split.allowUnknown
        )
        return changed(itinerary, waypoints: waypoints, legs: legs, rebuildFrom: legIndex)

    case .move(let waypointID, let coordinate):
        guard let waypointIndex = itinerary.waypoints.firstIndex(where: { $0.id == waypointID }),
              itinerary.waypoints[waypointIndex].coordinate != coordinate
        else { return unchanged(itinerary) }
        var waypoints = itinerary.waypoints
        waypoints[waypointIndex].coordinate = coordinate
        let rebuildIndex = itinerary.legs.isEmpty ? nil : max(0, waypointIndex - 1)
        return changed(
            itinerary,
            waypoints: waypoints,
            legs: itinerary.legs,
            rebuildFrom: rebuildIndex
        )

    case .delete(let waypointID):
        guard let waypointIndex = itinerary.waypoints.firstIndex(where: { $0.id == waypointID }) else {
            return unchanged(itinerary)
        }
        var waypoints = itinerary.waypoints
        waypoints.remove(at: waypointIndex)
        let fallbackLeg: RiderLeg? = {
            if itinerary.legs.indices.contains(max(0, waypointIndex - 1)) {
                return itinerary.legs[max(0, waypointIndex - 1)]
            }
            return itinerary.legs.last
        }()
        let legs = rebuiltLegs(
            waypoints: waypoints,
            preserving: itinerary.legs,
            fallbackProfile: fallbackLeg?.profile ?? .balanced,
            fallbackAllowUnknown: fallbackLeg?.allowUnknown ?? false
        )
        let joinedIndex = legs.isEmpty ? nil : min(max(0, waypointIndex - 1), legs.count - 1)
        return changed(itinerary, waypoints: waypoints, legs: legs, rebuildFrom: joinedIndex)

    case .setProfile(let legID, let profile):
        var legs = itinerary.legs
        let affected: [Int]
        if let legID {
            guard let index = legs.firstIndex(where: { $0.id == legID }),
                  legs[index].profile != profile
            else { return unchanged(itinerary) }
            affected = [index]
        } else {
            affected = legs.indices.filter { legs[$0].profile != profile }
            guard !affected.isEmpty else { return unchanged(itinerary) }
        }
        for index in affected {
            legs[index].profile = profile
            if profile == .cleanest { legs[index].allowUnknown = false }
        }
        return changed(
            itinerary,
            waypoints: itinerary.waypoints,
            legs: legs,
            rebuildFrom: legID == nil ? 0 : affected.first
        )

    case .setAllowUnknown(let legID, let allowUnknown):
        var legs = itinerary.legs
        let affected: [Int]
        if let legID {
            guard let index = legs.firstIndex(where: { $0.id == legID }) else {
                return unchanged(itinerary)
            }
            let effective = legs[index].profile == .cleanest ? false : allowUnknown
            guard legs[index].allowUnknown != effective else { return unchanged(itinerary) }
            affected = [index]
        } else {
            affected = legs.indices.filter {
                let effective = legs[$0].profile == .cleanest ? false : allowUnknown
                return legs[$0].allowUnknown != effective
            }
            guard !affected.isEmpty else { return unchanged(itinerary) }
        }
        for index in affected {
            legs[index].allowUnknown = legs[index].profile == .cleanest ? false : allowUnknown
        }
        return changed(
            itinerary,
            waypoints: itinerary.waypoints,
            legs: legs,
            rebuildFrom: legID == nil ? 0 : affected.first
        )

    case .markImpassable(let edgeIDs):
        let merged = itinerary.impassableEdgeIDs.union(edgeIDs)
        guard merged != itinerary.impassableEdgeIDs else { return unchanged(itinerary) }
        return changed(
            itinerary,
            waypoints: itinerary.waypoints,
            legs: itinerary.legs,
            impassableEdgeIDs: merged,
            rebuildFrom: itinerary.legs.isEmpty ? nil : 0
        )

    case .replaceAll(let coordinates, let profile, let allowUnknown):
        let waypoints = coordinates.map { RiderWaypoint(coordinate: $0) }
        let legs = rebuiltLegs(
            waypoints: waypoints,
            preserving: [],
            fallbackProfile: profile,
            fallbackAllowUnknown: allowUnknown
        )
        return changed(
            itinerary,
            waypoints: waypoints,
            legs: legs,
            impassableEdgeIDs: [],
            rebuildFrom: legs.isEmpty ? nil : 0
        )

    case .clear:
        guard !itinerary.waypoints.isEmpty || !itinerary.impassableEdgeIDs.isEmpty else {
            return unchanged(itinerary)
        }
        return changed(
            itinerary,
            waypoints: [],
            legs: [],
            impassableEdgeIDs: [],
            rebuildFrom: nil
        )
    }
}

private nonisolated func rebuiltLegs(
    waypoints: [RiderWaypoint],
    preserving existing: [RiderLeg],
    fallbackProfile: RouteProfile,
    fallbackAllowUnknown: Bool
) -> [RiderLeg] {
    guard waypoints.count > 1 else { return [] }
    let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    return (0..<(waypoints.count - 1)).map { index in
        let from = waypoints[index].id
        let to = waypoints[index + 1].id
        let id = RiderItinerary.legID(from: from, to: to)
        if let preserved = existingByID[id] { return preserved }
        return RiderLeg(
            from: from,
            to: to,
            profile: fallbackProfile,
            allowUnknown: fallbackAllowUnknown
        )
    }
}

private nonisolated func unchanged(_ itinerary: RiderItinerary) -> ItineraryChange {
    ItineraryChange(itinerary: itinerary, rebuildFromLegIndex: nil)
}

private nonisolated func changed(
    _ prior: RiderItinerary,
    waypoints: [RiderWaypoint],
    legs: [RiderLeg],
    impassableEdgeIDs: Set<String>? = nil,
    rebuildFrom: Int?
) -> ItineraryChange {
    let itinerary = RiderItinerary(
        waypoints: waypoints,
        legs: legs,
        generation: prior.generation + 1,
        impassableEdgeIDs: impassableEdgeIDs ?? prior.impassableEdgeIDs
    )
    return ItineraryChange(itinerary: itinerary, rebuildFromLegIndex: rebuildFrom)
}
