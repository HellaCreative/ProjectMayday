import Foundation
import Testing
@testable import Dirt

@MainActor
struct DestinationReservationRetryTests {
    @Test func waitsForPlausibleRoadThenReservesOnceWithoutResettingWindow() async throws {
        let retry = DestinationReservationRetry(arrivalUsedLimitMeters: nil)
        var calls = 0
        let originalDeadline = RoutingWorkContext.deadline
        func estimate() async throws -> Double? {
            calls += 1
            #expect(RoutingWorkContext.deadline == originalDeadline)
            return 12_758
        }
        try await retry.prepareIfNeeded(enabled: true, approachMeters: 200_000,
            availableMeters: 180_000, usableMeters: 180_000, estimate: estimate)
        #expect(calls == 0 && !retry.attempted)
        try await retry.prepareIfNeeded(enabled: true, approachMeters: 160_000,
            availableMeters: 180_000, usableMeters: 180_000, estimate: estimate)
        #expect(calls == 1 && retry.arrivalUsedLimitMeters == 167_242)
        try await retry.prepareIfNeeded(enabled: true, approachMeters: 100_000,
            availableMeters: 180_000, usableMeters: 180_000, estimate: estimate)
        #expect(calls == 1)
        // Previously spent fuel remains charged; this is an arrival-use limit.
        #expect(PackRoutingSource.destinationApproachCap(usableRangeMeters: 180_000,
            remainingMeters: 170_000, arrivalUsedLimitMeters: retry.arrivalUsedLimitMeters) == 157_242)
    }

    @Test func existingReservationAndDisabledEscapeDoNotInvokePreparation() async throws {
        let cases: [(Double?, Bool)] = [(150_000, true), (nil, false)]
        for (existing, enabled) in cases {
            let retry = DestinationReservationRetry(arrivalUsedLimitMeters: existing)
            try await retry.prepareIfNeeded(enabled: enabled, approachMeters: 100,
                availableMeters: 180_000, usableMeters: 180_000) {
                Issue.record("Unnecessary reservation preparation"); return 10
            }
            #expect(retry.arrivalUsedLimitMeters == existing)
        }
    }

    @Test func absentEstimateDoesNotInventFuelProofOrLoop() async throws {
        let retry = DestinationReservationRetry(arrivalUsedLimitMeters: nil)
        var calls = 0
        for _ in 0..<2 {
            try await retry.prepareIfNeeded(enabled: true, approachMeters: 100,
                availableMeters: 180_000, usableMeters: 180_000) { calls += 1; return nil }
        }
        #expect(calls == 1 && retry.arrivalUsedLimitMeters == nil)
    }

    @Test func expiredInheritedWindowCannotBeRestarted() async {
        let retry = DestinationReservationRetry(arrivalUsedLimitMeters: nil)
        await RoutingWorkContext.$deadline.withValue(0) {
            do {
                try await retry.prepareIfNeeded(enabled: true, approachMeters: 100,
                    availableMeters: 180_000, usableMeters: 180_000) {
                    Issue.record("Expired reservation accessed graph"); return 10
                }
                Issue.record("Expected inherited deadline failure")
            } catch { }
        }
        #expect(retry.arrivalUsedLimitMeters == nil && !retry.attempted)
    }
}
