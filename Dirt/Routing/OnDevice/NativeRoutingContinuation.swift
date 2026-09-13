import Foundation

/// Legal arrival state, separate from recreational backtracking history.
/// A fraction is measured in travel direction along `incoming`, from zero to
/// one. It must resume on that parent road, not be rematched to a nearby road.
nonisolated struct NativeRoutingContinuation: Codable, Hashable, Sendable {
    struct Road: Codable, Hashable, Sendable {
        let wayID: Int64
        let fromNodeID: Int64
        let toNodeID: Int64
    }

    enum Location: Codable, Hashable, Sendable {
        case node(Int64)
        case edge(fraction: Double)
    }

    struct RestrictionSignature: Codable, Hashable, Sendable {
        let relationID: Int64
        let kind: UInt8
        let only: Bool
        let vehicleMask: UInt16
        let viaNodeID: Int64?
        /// Ordered restriction members; member endpoint order is canonical,
        /// while `incoming` separately preserves actual travel direction.
        let members: [Road]
    }

    struct RestrictionProgress: Codable, Hashable, Sendable {
        let relationID: Int64
        let memberIndex: Int
    }

    let version: Int
    let sourceEpoch: String
    let incoming: Road
    let location: Location
    let restrictionContext: [RestrictionSignature]
    let activeRestrictions: [RestrictionProgress]
}

nonisolated enum NativeRoutingContinuationError: Error, Equatable, Sendable {
    case unsupportedVersion
    case unavailableSourceEpoch
    case incompatibleSourceEpoch
    case invalidLocation
    case unavailableRoad
    case ambiguousRoad
    case illegalDirection
    case incompatibleRestrictionContext
    case unavailableLegalState
}
