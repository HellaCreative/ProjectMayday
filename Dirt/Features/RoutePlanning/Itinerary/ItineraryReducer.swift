import Foundation

nonisolated struct ItineraryChange: Equatable, Sendable {
    let itinerary: RiderItinerary
    let rebuildFromLegIndex: Int?
    let rebuildFromFuelSequence: Int
    let preserveFuelStops: Bool

    init(
        itinerary: RiderItinerary,
        rebuildFromLegIndex: Int?,
        rebuildFromFuelSequence: Int = 0,
        preserveFuelStops: Bool = false
    ) {
        self.itinerary = itinerary
        self.rebuildFromLegIndex = rebuildFromLegIndex
        self.rebuildFromFuelSequence = rebuildFromFuelSequence
        self.preserveFuelStops = preserveFuelStops
    }
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
            fuelAnchors: [],
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
            fuelAnchors: [],
            rebuildFrom: nil
        )

    case .rebuild:
        guard !itinerary.legs.isEmpty else { return unchanged(itinerary) }
        return changed(
            itinerary,
            waypoints: itinerary.waypoints,
            legs: itinerary.legs,
            rebuildFrom: 0
        )

    case .replaceFuelStop(let id, let stationID, let coordinate, let name):
        guard let anchorIndex = itinerary.fuelAnchors.firstIndex(where: { $0.id == id }),
              let legIndex = itinerary.legs.firstIndex(where: {
                  $0.id == itinerary.fuelAnchors[anchorIndex].riderLegID
              })
        else { return unchanged(itinerary) }
        var anchors = itinerary.fuelAnchors
        var target = anchors[anchorIndex]
        if target.stationID == stationID, target.coordinate == coordinate, target.isPinned {
            return unchanged(itinerary)
        }
        target.stationID = stationID
        target.coordinate = coordinate
        target.name = name
        target.isPinned = true
        let riderLegID = target.riderLegID
        let sequence = target.sequence
        anchors[anchorIndex] = target
        anchors.removeAll { anchor in
            if anchor.id == id { return false }
            if anchor.riderLegID == riderLegID { return anchor.sequence > sequence }
            guard let otherIndex = itinerary.legs.firstIndex(where: { $0.id == anchor.riderLegID })
            else { return true }
            return otherIndex > legIndex
        }
        var overrides = itinerary.hopOverrides
        overrides.removeAll { override in
            if override.riderLegID == riderLegID { return override.sequence > sequence }
            guard let otherIndex = itinerary.legs.firstIndex(where: { $0.id == override.riderLegID })
            else { return true }
            return otherIndex > legIndex
        }
        return changed(
            itinerary,
            waypoints: itinerary.waypoints,
            legs: itinerary.legs,
            fuelAnchors: anchors,
            hopOverrides: overrides,
            rebuildFrom: legIndex,
            rebuildFromFuelSequence: sequence
        )

    case .setHopProfile(let id, let riderLegID, let sequence, let profile):
        guard let legIndex = itinerary.legs.firstIndex(where: { $0.id == riderLegID }) else {
            return unchanged(itinerary)
        }
        let riderLeg = itinerary.legs[legIndex]
        let current = itinerary.hopPolicy(riderLeg: riderLeg, sequence: sequence)
        guard current.profile != profile else { return unchanged(itinerary) }
        var overrides = itinerary.hopOverrides
        if let index = overrides.firstIndex(where: { $0.id == id }) {
            overrides[index].profile = profile
            if profile == .cleanest { overrides[index].allowUnknown = false }
        } else {
            overrides.append(HopOverride(
                id: id,
                riderLegID: riderLegID,
                sequence: sequence,
                profile: profile,
                allowUnknown: profile == .cleanest ? false : riderLeg.allowUnknown
            ))
        }
        return changed(
            itinerary,
            waypoints: itinerary.waypoints,
            legs: itinerary.legs,
            hopOverrides: overrides,
            rebuildFrom: legIndex,
            rebuildFromFuelSequence: sequence,
            preserveFuelStops: true
        )

    case .setHopAllowUnknown(let id, let riderLegID, let sequence, let allowUnknown):
        guard let legIndex = itinerary.legs.firstIndex(where: { $0.id == riderLegID }) else {
            return unchanged(itinerary)
        }
        let riderLeg = itinerary.legs[legIndex]
        let current = itinerary.hopPolicy(riderLeg: riderLeg, sequence: sequence)
        let effective = current.profile == .cleanest ? false : allowUnknown
        guard current.allowUnknown != effective else { return unchanged(itinerary) }
        var overrides = itinerary.hopOverrides
        if let index = overrides.firstIndex(where: { $0.id == id }) {
            overrides[index].allowUnknown = overrides[index].profile == .cleanest ? false : effective
        } else {
            overrides.append(HopOverride(
                id: id,
                riderLegID: riderLegID,
                sequence: sequence,
                profile: riderLeg.profile,
                allowUnknown: riderLeg.profile == .cleanest ? false : effective
            ))
        }
        return changed(
            itinerary,
            waypoints: itinerary.waypoints,
            legs: itinerary.legs,
            hopOverrides: overrides,
            rebuildFrom: legIndex,
            rebuildFromFuelSequence: sequence,
            preserveFuelStops: true
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
    fuelAnchors: [FuelAnchor]? = nil,
    hopOverrides: [HopOverride]? = nil,
    rebuildFrom: Int?,
    rebuildFromFuelSequence: Int = 0,
    preserveFuelStops: Bool = false
) -> ItineraryChange {
    let anchors = fuelAnchors ?? retainedFuelAnchors(prior.fuelAnchors, legs: legs)
    let overrides = hopOverrides ?? retainedHopOverrides(prior.hopOverrides, legs: legs)
    let itinerary = RiderItinerary(
        waypoints: waypoints,
        legs: legs,
        generation: prior.generation + 1,
        impassableEdgeIDs: impassableEdgeIDs ?? prior.impassableEdgeIDs,
        fuelAnchors: anchors,
        hopOverrides: overrides
    )
    return ItineraryChange(
        itinerary: itinerary,
        rebuildFromLegIndex: rebuildFrom,
        rebuildFromFuelSequence: rebuildFromFuelSequence,
        preserveFuelStops: preserveFuelStops
    )
}

private nonisolated func retainedFuelAnchors(
    _ anchors: [FuelAnchor],
    legs: [RiderLeg]
) -> [FuelAnchor] {
    let ids = Set(legs.map(\.id))
    return anchors.filter { ids.contains($0.riderLegID) }
}

private nonisolated func retainedHopOverrides(
    _ overrides: [HopOverride],
    legs: [RiderLeg]
) -> [HopOverride] {
    let ids = Set(legs.map(\.id))
    return overrides.filter { ids.contains($0.riderLegID) }
}
