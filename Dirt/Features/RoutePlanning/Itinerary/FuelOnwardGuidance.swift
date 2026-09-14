import Foundation

/// Extends request-local reverse facts only for pumps reachable after this
/// refill. The original rider-stage origin distance never becomes the pump's.
struct FuelOnwardGuidance {
    enum Failure: Error { case unavailable, sourceChanged }
    static func extending(
        _ existing: FuelItinerary.RoadProgress,
        candidateID: String,
        reachable: [String: Double],
        stations: [POIFeature],
        sourceIdentity: String,
        currentIdentity: () -> String,
        check: () throws -> Void,
        load: ([POIFeature]) async throws -> FuelItinerary.RoadProgress?
    ) async throws -> FuelItinerary.RoadProgress {
        try check()
        guard currentIdentity() == sourceIdentity else { throw Failure.sourceChanged }
        let missing = stations.filter {
            guard let distance = reachable[$0.id], distance.isFinite, distance >= 0 else { return false }
            return existing.stationRemainingMeters[$0.id] == nil
        }
        guard !missing.isEmpty else { return existing }
        guard let fresh = try await load(missing), fresh.originRemainingMeters.isFinite else {
            throw Failure.unavailable
        }
        try check()
        guard currentIdentity() == sourceIdentity else { throw Failure.sourceChanged }
        var combined = existing.stationRemainingMeters
        combined.merge(fresh.stationRemainingMeters,uniquingKeysWith: min)
        // An independently matched candidate must agree on destination intent;
        // don't replace an existing verified remaining-distance fact.
        if combined[candidateID] == nil { combined[candidateID] = fresh.originRemainingMeters }
        return .init(originRemainingMeters: existing.originRemainingMeters,stationRemainingMeters: combined)
    }
}
