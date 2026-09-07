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
    /// Internal inverse of the Clean "Allow major highways" control.
    var avoidMotorways: Bool
    /// Legacy persisted field. Clean no longer adds a primary-road penalty.
    var preferBackRoads: Bool
    /// A generated fuel hop inherits the rider-leg profile unless the pump it
    /// departs from has an explicit rider override.
    var hopOverrides: [String: RouteProfile]
    /// Clean's major-highway policy is owned by the same generated fuel hop
    /// that owns its profile override. Values are the internal inverse of the
    /// rider-facing "Allow major highways" control.
    var hopAvoidMotorways: [String: Bool]
    /// Unknown-access permission is owned by the generated stage that departs
    /// from this rider waypoint or fuel stop. Keeping explicit false values is
    /// important: a stage can opt out even when the parent rider leg opts in.
    var hopAllowUnknown: [String: Bool]
    /// Rider-selected pump keyed by the departure waypoint/station anchor.
    /// This is distinct from hopOverrides, which changes routing profile only.
    var fuelStopOverrides: [String: String]

    init(
        from: UUID,
        to: UUID,
        profile: RouteProfile,
        allowUnknown: Bool,
        avoidMotorways: Bool = true,
        preferBackRoads: Bool = false,
        hopOverrides: [String: RouteProfile] = [:],
        hopAvoidMotorways: [String: Bool] = [:],
        hopAllowUnknown: [String: Bool] = [:],
        fuelStopOverrides: [String: String] = [:]
    ) {
        id = RiderItinerary.legID(from: from, to: to)
        self.from = from
        self.to = to
        self.profile = profile
        self.allowUnknown = profile == .cleanest ? false : allowUnknown
        self.avoidMotorways = profile == .cleanest ? avoidMotorways : false
        self.preferBackRoads = false
        self.hopOverrides = hopOverrides
        self.hopAvoidMotorways = hopAvoidMotorways
        self.hopAllowUnknown = hopAllowUnknown
        self.fuelStopOverrides = fuelStopOverrides
    }

    func effectiveProfile(departingFrom anchorID: String) -> RouteProfile {
        hopOverrides[anchorID] ?? profile
    }

    func avoidsMajorHighways(
        departingFrom anchorID: String,
        effectiveProfile: RouteProfile? = nil
    ) -> Bool {
        let activeProfile = effectiveProfile ?? self.effectiveProfile(departingFrom: anchorID)
        guard activeProfile == .cleanest else { return false }
        if let hopValue = hopAvoidMotorways[anchorID] { return hopValue }
        // A Clean override on a Dirt/Balanced parent has no parent Clean
        // preference to inherit. Its honest default is rider-facing Allow OFF.
        return profile == .cleanest ? avoidMotorways : true
    }

    func allowsUnknown(
        departingFrom anchorID: String,
        effectiveProfile: RouteProfile? = nil
    ) -> Bool {
        let activeProfile = effectiveProfile ?? self.effectiveProfile(departingFrom: anchorID)
        guard activeProfile != .cleanest else { return false }
        return hopAllowUnknown[anchorID] ?? allowUnknown
    }

    private enum CodingKeys: String, CodingKey {
        case id, from, to, profile, allowUnknown, avoidMotorways, preferBackRoads
        case hopOverrides, hopAvoidMotorways, hopAllowUnknown, fuelStopOverrides
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        from = try container.decode(UUID.self, forKey: .from)
        to = try container.decode(UUID.self, forKey: .to)
        profile = try container.decode(RouteProfile.self, forKey: .profile)
        allowUnknown = try container.decode(Bool.self, forKey: .allowUnknown)
        avoidMotorways = try container.decodeIfPresent(Bool.self, forKey: .avoidMotorways)
            ?? (profile == .cleanest)
        preferBackRoads = try container.decodeIfPresent(Bool.self, forKey: .preferBackRoads) ?? false
        if profile == .cleanest {
            allowUnknown = false
            preferBackRoads = false
        } else {
            avoidMotorways = false
            preferBackRoads = false
        }
        hopOverrides = try container.decodeIfPresent(
            [String: RouteProfile].self, forKey: .hopOverrides
        ) ?? [:]
        hopAvoidMotorways = try container.decodeIfPresent(
            [String: Bool].self, forKey: .hopAvoidMotorways
        ) ?? [:]
        hopAllowUnknown = try container.decodeIfPresent(
            [String: Bool].self, forKey: .hopAllowUnknown
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

    /// Move a pin to the snapped road without bumping generation (no rebuild).
    mutating func relocateWaypoint(at index: Int, to coordinate: RouteCoordinate) {
        guard waypoints.indices.contains(index) else { return }
        waypoints[index].coordinate = coordinate
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
        for index in legs.indices where
            !legs[index].hopOverrides.isEmpty
                || !legs[index].hopAvoidMotorways.isEmpty
                || !legs[index].hopAllowUnknown.isEmpty {
            var active = activeStationIDs[legs[index].id] ?? []
            active.insert(legs[index].from.uuidString)
            legs[index].hopOverrides = legs[index].hopOverrides.filter { active.contains($0.key) }
            legs[index].hopAvoidMotorways = legs[index].hopAvoidMotorways.filter {
                active.contains($0.key)
            }
            legs[index].hopAllowUnknown = legs[index].hopAllowUnknown.filter {
                active.contains($0.key)
            }
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
