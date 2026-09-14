import Foundation

/// Request-local planning allowance only. A distance estimate never establishes
/// fuel safety after a particular incoming road/turn state.
@MainActor
final class DestinationReservationRetry {
    private(set) var arrivalUsedLimitMeters: Double?
    private(set) var attempted = false
    init(arrivalUsedLimitMeters: Double?) { self.arrivalUsedLimitMeters = arrivalUsedLimitMeters }

    func prepareIfNeeded(enabled: Bool, approachMeters: Double?, availableMeters: Double,
        usableMeters: Double, estimate: () async throws -> Double?) async throws {
        guard enabled, arrivalUsedLimitMeters == nil, !attempted,
              let approachMeters, approachMeters.isFinite, approachMeters >= 0,
              availableMeters.isFinite, approachMeters <= availableMeters,
              usableMeters.isFinite, usableMeters > 0 else { return }
        try RoutingWorkContext.check()
        attempted = true
        let meters = try await estimate()
        try RoutingWorkContext.check()
        guard let meters, meters.isFinite, meters >= 0, meters <= usableMeters else { return }
        arrivalUsedLimitMeters = usableMeters - meters
    }
}
