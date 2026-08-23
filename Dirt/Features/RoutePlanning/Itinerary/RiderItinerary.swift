import Foundation

nonisolated struct RiderWaypoint: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var coordinate: RouteCoordinate

    init(id: UUID = UUID(), coordinate: RouteCoordinate) {
        self.id = id
        self.coordinate = coordinate
    }
}

nonisolated struct RiderLeg: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let from: UUID
    let to: UUID
    var profile: RouteProfile
    var allowUnknown: Bool

    init(
        from: UUID,
        to: UUID,
        profile: RouteProfile,
        allowUnknown: Bool
    ) {
        id = RiderItinerary.legID(from: from, to: to)
        self.from = from
        self.to = to
        self.profile = profile
        self.allowUnknown = profile == .cleanest ? false : allowUnknown
    }
}

nonisolated struct FuelAnchor: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let riderLegID: UUID
    let sequence: Int
    var stationID: String
    var coordinate: RouteCoordinate
    var name: String?
    var isPinned: Bool
}

/// Per-hop ride type and Allow Unknown, keyed by fuel-stop identity or the
/// rider-leg id for the hop that ends at the rider waypoint.
nonisolated struct HopOverride: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let riderLegID: UUID
    let sequence: Int
    var profile: RouteProfile
    var allowUnknown: Bool
}

/// The rider-owned route intent. Generated pumps are recorded here only as
/// stable fuel identities and rider-pinned replacements. Routed geometry stays
/// in `BuiltItinerary`.
nonisolated struct RiderItinerary: Equatable, Codable, Sendable {
    private(set) var waypoints: [RiderWaypoint]
    private(set) var legs: [RiderLeg]
    private(set) var generation: Int
    private(set) var impassableEdgeIDs: Set<String>
    private(set) var fuelAnchors: [FuelAnchor]
    private(set) var hopOverrides: [HopOverride]

    init() {
        waypoints = []
        legs = []
        generation = 0
        impassableEdgeIDs = []
        fuelAnchors = []
        hopOverrides = []
        assertInvariants()
    }

    init(
        waypoints: [RiderWaypoint],
        legs: [RiderLeg],
        generation: Int,
        impassableEdgeIDs: Set<String>,
        fuelAnchors: [FuelAnchor] = [],
        hopOverrides: [HopOverride] = []
    ) {
        self.waypoints = waypoints
        self.legs = legs
        self.generation = generation
        self.impassableEdgeIDs = impassableEdgeIDs
        self.fuelAnchors = fuelAnchors
        self.hopOverrides = hopOverrides
        assertInvariants()
    }

    var invariantsHold: Bool {
        guard legs.count == max(0, waypoints.count - 1),
              Set(waypoints.map(\.id)).count == waypoints.count,
              Set(fuelAnchors.map(\.id)).count == fuelAnchors.count,
              Set(hopOverrides.map(\.id)).count == hopOverrides.count
        else { return false }
        for index in legs.indices {
            guard legs[index].from == waypoints[index].id,
                  legs[index].to == waypoints[index + 1].id,
                  legs[index].id == Self.legID(
                    from: waypoints[index].id,
                    to: waypoints[index + 1].id
                  )
            else { return false }
        }
        let legIDs = Set(legs.map(\.id))
        var sequences = Set<String>()
        for anchor in fuelAnchors {
            guard legIDs.contains(anchor.riderLegID), anchor.sequence >= 0 else { return false }
            let key = "\(anchor.riderLegID.uuidString):\(anchor.sequence)"
            guard sequences.insert(key).inserted else { return false }
        }
        for override in hopOverrides {
            guard legIDs.contains(override.riderLegID), override.sequence >= 0 else { return false }
        }
        return true
    }

    func hopOverrideID(riderLegID: UUID, sequence: Int) -> UUID {
        fuelAnchors.first { $0.riderLegID == riderLegID && $0.sequence == sequence }?.id
            ?? riderLegID
    }

    func hopPolicy(riderLeg: RiderLeg, sequence: Int) -> (profile: RouteProfile, allowUnknown: Bool) {
        let key = hopOverrideID(riderLegID: riderLeg.id, sequence: sequence)
        guard let override = hopOverrides.first(where: { $0.id == key }) else {
            return (riderLeg.profile, riderLeg.allowUnknown)
        }
        let allow = override.profile == .cleanest ? false : override.allowUnknown
        return (override.profile, allow)
    }

    func assertInvariants(
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        assert(invariantsHold, "RiderItinerary invariant violation", file: file, line: line)
    }

    /// Stable, process-independent identity for an ordered endpoint pair.
    /// This is identity derivation, not security; two independent FNV streams
    /// provide the 128 deterministic bits used by UUID.
    static func legID(from: UUID, to: UUID) -> UUID {
        let bytes = Array("\(from.uuidString.lowercased())>\(to.uuidString.lowercased())".utf8)
        var high: UInt64 = 14_695_981_039_346_656_037
        var low: UInt64 = 10_995_116_282_111
        for byte in bytes {
            high = (high ^ UInt64(byte)) &* 1_099_511_628_211
            low = (low &+ UInt64(byte)) &* 14_029_467_366_897_019_727
        }
        var output = withUnsafeBytes(of: high.bigEndian, Array.init)
        output.append(contentsOf: withUnsafeBytes(of: low.bigEndian, Array.init))
        output[6] = (output[6] & 0x0F) | 0x50
        output[8] = (output[8] & 0x3F) | 0x80
        return UUID(uuid: (
            output[0], output[1], output[2], output[3],
            output[4], output[5], output[6], output[7],
            output[8], output[9], output[10], output[11],
            output[12], output[13], output[14], output[15]
        ))
    }

    private enum CodingKeys: String, CodingKey {
        case waypoints
        case legs
        case generation
        case impassableEdgeIDs
        case fuelAnchors
        case hopOverrides
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        waypoints = try container.decode([RiderWaypoint].self, forKey: .waypoints)
        legs = try container.decode([RiderLeg].self, forKey: .legs)
        generation = try container.decode(Int.self, forKey: .generation)
        impassableEdgeIDs = try container.decode(Set<String>.self, forKey: .impassableEdgeIDs)
        fuelAnchors = try container.decodeIfPresent([FuelAnchor].self, forKey: .fuelAnchors) ?? []
        hopOverrides = try container.decodeIfPresent([HopOverride].self, forKey: .hopOverrides) ?? []
        guard invariantsHold else {
            throw DecodingError.dataCorruptedError(
                forKey: .legs,
                in: container,
                debugDescription: "RiderItinerary invariant violation"
            )
        }
    }
}
