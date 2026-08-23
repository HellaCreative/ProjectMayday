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
    /// Phase E4: strong soft-avoid motorway + trunk.
    var avoidMotorways: Bool
    /// Phase E4: penalize arterial / prefer collector.
    var preferBackRoads: Bool
    /// A generated fuel hop inherits the rider-leg profile unless the pump it
    /// departs from has an explicit rider override.
    var hopOverrides: [String: RouteProfile]
    /// Rider-selected pump keyed by the departure waypoint/station anchor.
    /// This is distinct from hopOverrides, which changes routing profile only.
    var fuelStopOverrides: [String: String]

    init(
        from: UUID,
        to: UUID,
        profile: RouteProfile,
        allowUnknown: Bool,
        avoidMotorways: Bool = false,
        preferBackRoads: Bool = false,
        hopOverrides: [String: RouteProfile] = [:],
        fuelStopOverrides: [String: String] = [:]
    ) {
        id = RiderItinerary.legID(from: from, to: to)
        self.from = from
        self.to = to
        self.profile = profile
        self.allowUnknown = profile == .cleanest ? false : allowUnknown
        self.avoidMotorways = avoidMotorways
        self.preferBackRoads = preferBackRoads
        self.hopOverrides = hopOverrides
        self.fuelStopOverrides = fuelStopOverrides
    }

    private enum CodingKeys: String, CodingKey {
        case id, from, to, profile, allowUnknown, avoidMotorways, preferBackRoads, hopOverrides, fuelStopOverrides
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        from = try container.decode(UUID.self, forKey: .from)
        to = try container.decode(UUID.self, forKey: .to)
        profile = try container.decode(RouteProfile.self, forKey: .profile)
        allowUnknown = try container.decode(Bool.self, forKey: .allowUnknown)
        avoidMotorways = try container.decodeIfPresent(Bool.self, forKey: .avoidMotorways) ?? false
        preferBackRoads = try container.decodeIfPresent(Bool.self, forKey: .preferBackRoads) ?? false
        hopOverrides = try container.decodeIfPresent(
            [String: RouteProfile].self, forKey: .hopOverrides
        ) ?? [:]
        fuelStopOverrides = try container.decodeIfPresent(
            [String: String].self, forKey: .fuelStopOverrides
        ) ?? [:]
    }
}

/// The rider-owned route intent. Fuel never appears here; pumps and routed
/// geometry are disposable output produced from this ordered waypoint chain.
nonisolated struct RiderItinerary: Equatable, Codable, Sendable {
    private(set) var waypoints: [RiderWaypoint]
    private(set) var legs: [RiderLeg]
    private(set) var generation: Int
    private(set) var impassableEdgeIDs: Set<String>

    init() {
        waypoints = []
        legs = []
        generation = 0
        impassableEdgeIDs = []
        assertInvariants()
    }

    init(
        waypoints: [RiderWaypoint],
        legs: [RiderLeg],
        generation: Int,
        impassableEdgeIDs: Set<String>
    ) {
        self.waypoints = waypoints
        self.legs = legs
        self.generation = generation
        self.impassableEdgeIDs = impassableEdgeIDs
        assertInvariants()
    }

    var invariantsHold: Bool {
        guard legs.count == max(0, waypoints.count - 1),
              Set(waypoints.map(\.id)).count == waypoints.count
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
        return true
    }

    func assertInvariants(
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        assert(invariantsHold, "RiderItinerary invariant violation", file: file, line: line)
    }

    mutating func pruneHopOverrides(to activeStationIDs: [UUID: Set<String>]) {
        for index in legs.indices where !legs[index].hopOverrides.isEmpty {
            var active = activeStationIDs[legs[index].id] ?? []
            active.insert(legs[index].from.uuidString)
            legs[index].hopOverrides = legs[index].hopOverrides.filter { active.contains($0.key) }
        }
    }

    mutating func pruneFuelStopOverrides(to activeStationIDs: [UUID: Set<String>]) {
        for index in legs.indices where !legs[index].fuelStopOverrides.isEmpty {
            var activeAnchors = activeStationIDs[legs[index].id] ?? []
            activeAnchors.insert(legs[index].from.uuidString)
            let activeStations = activeStationIDs[legs[index].id] ?? []
            legs[index].fuelStopOverrides = legs[index].fuelStopOverrides.filter {
                activeAnchors.contains($0.key) && activeStations.contains($0.value)
            }
        }
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        waypoints = try container.decode([RiderWaypoint].self, forKey: .waypoints)
        legs = try container.decode([RiderLeg].self, forKey: .legs)
        generation = try container.decode(Int.self, forKey: .generation)
        impassableEdgeIDs = try container.decode(Set<String>.self, forKey: .impassableEdgeIDs)
        guard invariantsHold else {
            throw DecodingError.dataCorruptedError(
                forKey: .legs,
                in: container,
                debugDescription: "RiderItinerary invariant violation"
            )
        }
    }
}
