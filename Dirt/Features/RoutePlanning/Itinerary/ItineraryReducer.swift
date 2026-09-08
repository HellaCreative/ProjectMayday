import Foundation

nonisolated struct ItineraryChange: Equatable, Sendable {
    let itinerary: RiderItinerary
    let rebuildFromLegIndex: Int?
    /// Inclusive rider-leg boundary for a local option edit. Nil means the
    /// rebuild may continue through the remaining itinerary.
    let rebuildThroughLegIndex: Int?
    let replanFromStationID: String?
}

nonisolated func reduce(
    _ itinerary: RiderItinerary,
    _ action: ItineraryAction,
    automaticFuelEnabled: Bool = true
) -> ItineraryChange {
    switch action {
    case .append(let coordinate):
        var waypoints = itinerary.waypoints
        waypoints.append(RiderWaypoint(coordinate: coordinate))
        let legs = rebuiltLegs(
            waypoints: waypoints,
            preserving: itinerary.legs,
            fallbackProfile: itinerary.legs.last?.profile ?? .balanced,
            fallbackAllowUnknown: itinerary.legs.last?.allowUnknown ?? false,
            fallbackAvoidMotorways: itinerary.legs.last?.avoidMotorways ?? false,
            fallbackPreferBackRoads: itinerary.legs.last?.preferBackRoads ?? false
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
        var legs = rebuiltLegs(
            waypoints: waypoints,
            preserving: itinerary.legs,
            fallbackProfile: split.profile,
            fallbackAllowUnknown: split.allowUnknown,
            fallbackAvoidMotorways: split.avoidMotorways,
            fallbackPreferBackRoads: split.preferBackRoads
        )
        let rebuildThrough = automaticFuelEnabled ? nil : min(legIndex + 1, legs.count - 1)
        refreshRouteSeeds(
            in: &legs,
            from: legIndex,
            through: rebuildThrough
        )
        return changed(
            itinerary,
            waypoints: waypoints,
            legs: legs,
            rebuildFrom: legIndex,
            rebuildThrough: rebuildThrough
        )

    case .move(let waypointID, let coordinate):
        guard let waypointIndex = itinerary.waypoints.firstIndex(where: { $0.id == waypointID }),
              itinerary.waypoints[waypointIndex].coordinate != coordinate
        else { return unchanged(itinerary) }
        var waypoints = itinerary.waypoints
        waypoints[waypointIndex].coordinate = coordinate
        let rebuildIndex = itinerary.legs.isEmpty ? nil : max(0, waypointIndex - 1)
        let rebuildThrough: Int? = {
            guard rebuildIndex != nil else { return nil }
            if waypointIndex == 0 || automaticFuelEnabled { return nil }
            return min(waypointIndex, itinerary.legs.count - 1)
        }()
        var legs = itinerary.legs
        refreshRouteSeeds(in: &legs, from: rebuildIndex, through: rebuildThrough)
        return changed(
            itinerary,
            waypoints: waypoints,
            legs: legs,
            rebuildFrom: rebuildIndex,
            rebuildThrough: rebuildThrough
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
        var legs = rebuiltLegs(
            waypoints: waypoints,
            preserving: itinerary.legs,
            fallbackProfile: fallbackLeg?.profile ?? .balanced,
            fallbackAllowUnknown: fallbackLeg?.allowUnknown ?? false,
            fallbackAvoidMotorways: fallbackLeg?.avoidMotorways ?? false,
            fallbackPreferBackRoads: fallbackLeg?.preferBackRoads ?? false
        )
        let joinedIndex = legs.isEmpty ? nil : min(max(0, waypointIndex - 1), legs.count - 1)
        let rebuildThrough = automaticFuelEnabled ? nil : joinedIndex
        refreshRouteSeeds(in: &legs, from: joinedIndex, through: rebuildThrough)
        return changed(
            itinerary,
            waypoints: waypoints,
            legs: legs,
            rebuildFrom: joinedIndex,
            rebuildThrough: rebuildThrough
        )

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
            legs[index].hopOverrides.removeAll()
            legs[index].hopAvoidMotorways.removeAll()
            legs[index].hopAllowUnknown.removeAll()
            legs[index].fuelStopOverrides.removeAll()
            if profile == .cleanest {
                legs[index].allowUnknown = false
                legs[index].avoidMotorways = true
                legs[index].preferBackRoads = false
            } else {
                legs[index].avoidMotorways = false
                legs[index].preferBackRoads = false
            }
        }
        return changed(
            itinerary,
            waypoints: itinerary.waypoints,
            legs: legs,
            rebuildFrom: legID == nil ? 0 : affected.first,
            rebuildThrough: legID == nil ? nil : affected.first
        )

    case .setHopProfile(let legID, let stationID, let profile):
        guard !stationID.isEmpty,
              let index = itinerary.legs.firstIndex(where: { $0.id == legID }),
              itinerary.legs[index].effectiveProfile(departingFrom: stationID) != profile
        else { return unchanged(itinerary) }
        var legs = itinerary.legs
        legs[index].hopOverrides[stationID] = profile
        return changed(
            itinerary,
            waypoints: itinerary.waypoints,
            legs: legs,
            rebuildFrom: index,
            rebuildThrough: index,
            replanFromStationID: stationID == legs[index].from.uuidString ? nil : stationID
        )

    case .setHopAvoidMotorways(let legID, let stationID, let avoidMotorways):
        guard !stationID.isEmpty,
              let index = itinerary.legs.firstIndex(where: { $0.id == legID }),
              itinerary.legs[index].effectiveProfile(departingFrom: stationID) == .cleanest,
              itinerary.legs[index].avoidsMajorHighways(departingFrom: stationID)
                != avoidMotorways
        else { return unchanged(itinerary) }
        var legs = itinerary.legs
        legs[index].hopAvoidMotorways[stationID] = avoidMotorways
        return changed(
            itinerary,
            waypoints: itinerary.waypoints,
            legs: legs,
            rebuildFrom: index,
            rebuildThrough: index,
            replanFromStationID: stationID == legs[index].from.uuidString ? nil : stationID
        )

    case .setHopAllowUnknown(let legID, let stationID, let allowUnknown):
        guard !stationID.isEmpty,
              let index = itinerary.legs.firstIndex(where: { $0.id == legID })
        else { return unchanged(itinerary) }
        let profile = itinerary.legs[index].effectiveProfile(departingFrom: stationID)
        let effective = profile == .cleanest ? false : allowUnknown
        guard itinerary.legs[index].allowsUnknown(
            departingFrom: stationID,
            effectiveProfile: profile
        ) != effective else { return unchanged(itinerary) }
        var legs = itinerary.legs
        legs[index].hopAllowUnknown[stationID] = effective
        return changed(
            itinerary,
            waypoints: itinerary.waypoints,
            legs: legs,
            rebuildFrom: index,
            rebuildThrough: index,
            replanFromStationID: stationID == legs[index].from.uuidString ? nil : stationID
        )

    case .setFuelStopOverride(let legID, let departureAnchorID, let stationID):
        guard !departureAnchorID.isEmpty, !stationID.isEmpty,
              let index = itinerary.legs.firstIndex(where: { $0.id == legID }),
              itinerary.legs[index].fuelStopOverrides[departureAnchorID] != stationID
        else { return unchanged(itinerary) }
        var legs = itinerary.legs
        legs[index].fuelStopOverrides[departureAnchorID] = stationID
        legs[index].routeSeed = RiderLeg.mintRouteSeed()
        return changed(
            itinerary,
            waypoints: itinerary.waypoints,
            legs: legs,
            rebuildFrom: index,
            rebuildThrough: index,
            replanFromStationID: departureAnchorID == legs[index].from.uuidString
                ? nil
                : departureAnchorID
        )

    case .clearFuelStopOverrides(let legID):
        guard let index = itinerary.legs.firstIndex(where: { $0.id == legID }),
              !itinerary.legs[index].fuelStopOverrides.isEmpty
        else { return unchanged(itinerary) }
        var legs = itinerary.legs
        legs[index].fuelStopOverrides.removeAll()
        legs[index].routeSeed = RiderLeg.mintRouteSeed()
        return changed(
            itinerary,
            waypoints: itinerary.waypoints,
            legs: legs,
            rebuildFrom: index,
            rebuildThrough: index
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
            legs[index].hopAllowUnknown.removeAll()
        }
        return changed(
            itinerary,
            waypoints: itinerary.waypoints,
            legs: legs,
            rebuildFrom: legID == nil ? 0 : affected.first,
            rebuildThrough: legID == nil ? nil : affected.first
        )

    case .setAvoidMotorways(let legID, let avoidMotorways):
        var legs = itinerary.legs
        let affected: [Int]
        if let legID {
            guard let index = legs.firstIndex(where: { $0.id == legID }),
                  legs[index].profile == .cleanest,
                  legs[index].avoidMotorways != avoidMotorways
            else { return unchanged(itinerary) }
            affected = [index]
        } else {
            affected = legs.indices.filter {
                legs[$0].profile == .cleanest && legs[$0].avoidMotorways != avoidMotorways
            }
            guard !affected.isEmpty else { return unchanged(itinerary) }
        }
        for index in affected { legs[index].avoidMotorways = avoidMotorways }
        return changed(
            itinerary,
            waypoints: itinerary.waypoints,
            legs: legs,
            rebuildFrom: legID == nil ? 0 : affected.first,
            rebuildThrough: legID == nil ? nil : affected.first
        )

    case .setPreferBackRoads:
        // Retained for itinerary compatibility; Clean no longer applies a
        // separate primary-road penalty.
        return unchanged(itinerary)

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

    case .replaceAll(let coordinates, let profile, let allowUnknown, let avoidMotorways, let preferBackRoads):
        let waypoints = coordinates.map { RiderWaypoint(coordinate: $0) }
        let legs = rebuiltLegs(
            waypoints: waypoints,
            preserving: [],
            fallbackProfile: profile,
            fallbackAllowUnknown: allowUnknown,
            fallbackAvoidMotorways: avoidMotorways,
            fallbackPreferBackRoads: preferBackRoads
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

    case .rebuild:
        guard !itinerary.legs.isEmpty else { return unchanged(itinerary) }
        return changed(
            itinerary,
            waypoints: itinerary.waypoints,
            legs: itinerary.legs,
            rebuildFrom: 0
        )
    }
}

private nonisolated func refreshRouteSeeds(
    in legs: inout [RiderLeg],
    from start: Int?,
    through end: Int?
) {
    guard let start, legs.indices.contains(start) else { return }
    let last = min(end ?? (legs.count - 1), legs.count - 1)
    guard start <= last else { return }
    for index in start...last {
        legs[index].routeSeed = RiderLeg.mintRouteSeed()
    }
}

private nonisolated func rebuiltLegs(
    waypoints: [RiderWaypoint],
    preserving existing: [RiderLeg],
    fallbackProfile: RouteProfile,
    fallbackAllowUnknown: Bool,
    fallbackAvoidMotorways: Bool = false,
    fallbackPreferBackRoads: Bool = false
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
            allowUnknown: fallbackAllowUnknown,
            avoidMotorways: fallbackAvoidMotorways,
            preferBackRoads: fallbackPreferBackRoads
        )
    }
}

private nonisolated func unchanged(_ itinerary: RiderItinerary) -> ItineraryChange {
    ItineraryChange(
        itinerary: itinerary,
        rebuildFromLegIndex: nil,
        rebuildThroughLegIndex: nil,
        replanFromStationID: nil
    )
}

private nonisolated func changed(
    _ prior: RiderItinerary,
    waypoints: [RiderWaypoint],
    legs: [RiderLeg],
    impassableEdgeIDs: Set<String>? = nil,
    rebuildFrom: Int?,
    rebuildThrough: Int? = nil,
    replanFromStationID: String? = nil
) -> ItineraryChange {
    let itinerary = RiderItinerary(
        waypoints: waypoints,
        legs: legs,
        generation: prior.generation + 1,
        impassableEdgeIDs: impassableEdgeIDs ?? prior.impassableEdgeIDs
    )
    return ItineraryChange(
        itinerary: itinerary,
        rebuildFromLegIndex: rebuildFrom,
        rebuildThroughLegIndex: rebuildThrough,
        replanFromStationID: replanFromStationID
    )
}
