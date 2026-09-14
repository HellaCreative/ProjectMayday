import CoreLocation
import Foundation

/// Unactivated preparation result. Estimates order work; none proves a route,
/// useful progress, remaining range, access or a fuel gap. Unknown rows stay pending.
nonisolated enum LazyOnwardStationPreparation {
    static let version = 2
    // Work budget only; every station remains eligible for exact refinement.
    static let maximumSampledParentRecords = 64
    struct Point: Codable, Equatable, Sendable {
        let latitude: Double, longitude: Double
        init(_ value: CLLocationCoordinate2D) { latitude = value.latitude; longitude = value.longitude }
        var coordinate: CLLocationCoordinate2D { .init(latitude: latitude,longitude: longitude) }
    }
    struct Request: Codable, Equatable, Sendable {
        let source: ExactSnapIndex.Identity
        let origin: Point, destination: Point
        let stations: [Point]
        let profile: RouteProfile
        let allowUnknown: Bool
        let usableMeters: Double
        let radiusMeters: Double
        let formatVersion: Int
    }
    enum Confidence: String, Codable, Sendable { case orderingOnly, partialOrderingOnly, unknown }
    struct Hint: Codable, Equatable, Sendable {
        let stationIndex: Int
        let forwardEstimate: Double?
        let remainingEstimate: Double?
        // Samples are not complete attachment bounds; nil means unknown, never unreachable.
        var hasBothEstimates: Bool { forwardEstimate != nil && remainingEstimate != nil }
        var confidence: Confidence {
            hasBothEstimates ? .orderingOnly : (forwardEstimate != nil || remainingEstimate != nil ? .partialOrderingOnly : .unknown)
        }
    }
    struct Statistics: Codable, Sendable {
        let elapsedSeconds: Double
        let completedFields: Int
        let parentMembershipVisits: Int
        let retainedHintPayloadBytes: Int
        let stationProjectionQueries: Int
    }
    struct Prepared: Codable, Sendable {
        let request: Request
        let hints: [Hint]
        let statistics: Statistics
        var orderedStationIndices: [Int] {
            // Sampled graph-field order only. Every input remains present.
            hints.sorted {
                let a = $0.forwardEstimate.map { $0 <= request.usableMeters } ?? false
                let b = $1.forwardEstimate.map { $0 <= request.usableMeters } ?? false
                if a != b { return a }
                let ar = $0.remainingEstimate ?? .infinity, br = $1.remainingEstimate ?? .infinity
                if ar != br { return ar < br }
                let af = $0.forwardEstimate ?? .infinity, bf = $1.forwardEstimate ?? .infinity
                return af == bf ? $0.stationIndex < $1.stationIndex : af < bf
            }.map(\.stationIndex)
        }
    }
    enum Outcome { case prepared(Prepared), requiresExactPreparation(String) }
    enum Failure: Error, Equatable { case incompatibleSource, invalidInput }
    struct Limits {
        // A bounded supported slice of existing field preparation, not a
        // consumer regional-size/candidate limit. Exceeding it requires fallback.
        var maximumNodes = 262_144
        var maximumArcs = 1_048_576
        var maximumStations = 4_096
        var maximumHintPayloadBytes = 1_048_576
    }
}
