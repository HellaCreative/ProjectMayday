import Foundation
import Testing
@testable import Dirt

@MainActor
struct DestinationFuelRecoveryTests {
    private let destination = RouteCoordinate(longitude: -63, latitude: 46)
    private func response(_ status: String) -> FuelChainResponse {
        .init(status: status, error: nil, message: nil, regionIds: nil,
              stops: [], graphMeters: [], diagnostics: nil, windowComplete: status == "complete")
    }
    private func retainedRoad() throws -> FuelChainResponse {
        let road = try JSONDecoder().decode(RouteResponse.self, from: Data(
            """
            {"status":"complete","distanceMeters":179000,"geometry":[[-63,45],[-63,46]],"stats":{"dirtPercent":60,"pavedPercent":40}}
            """.utf8))
        return .init(status: "unknown", error: "destination_escape_unverified",
            message: "Escape unproved", regionIds: nil, stops: [],
            graphMeters: [179_000], diagnostics: nil,
            foundationRoute: road,
            windowComplete: false)
    }
    @Test func completedFuelRepairReplacesUnknownRoadWithoutRenewingDeadline() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        var pumpWasConsidered = false
        let result = try await RoutingWorkContext.$deadline.withValue(deadline) {
            try await PackRoutingSource.continuingFuelPlanning { recovery in
                recovery.completeRoad = try retainedRoad()
                #expect(RoutingWorkContext.deadline == deadline)
                pumpWasConsidered = true
                var repaired = response("complete")
                repaired.destinationEscapeMeters = 1_000
                return repaired
            }
        }
        #expect(pumpWasConsidered)
        #expect(result.status == "complete")
        #expect(result.destinationEscapeMeters == 1_000)
    }
    @Test func unsuccessfulPumpChoicesRetainCompleteDestinationAsFuelUnknown() async throws {
        for status in ["gap", "unknown"] {
            let result = try await PackRoutingSource.continuingFuelPlanning { recovery in
                recovery.completeRoad = try retainedRoad()
                return response(status)
            }
            #expect(result.status == "unknown")
            #expect(result.error == "destination_escape_unverified")
            #expect(result.foundationRoute?.geometry?.last == destination)
            #expect(result.destinationEscapeMeters == nil)
        }
    }
    @Test func timedOutRepairKeepsRoadButCancellationCannotReviveIntent() async throws {
        let result = try await PackRoutingSource.continuingFuelPlanning { recovery in
            recovery.completeRoad = try retainedRoad()
            throw RoutingError.fuelUnknown("window expired")
        }
        #expect(result.status == "unknown")
        #expect(result.foundationRoute?.geometry?.last == destination)
        do {
            _ = try await PackRoutingSource.continuingFuelPlanning { recovery in
                recovery.completeRoad = try retainedRoad()
                throw CancellationError()
            }
            Issue.record("Cancelled intent was revived")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    }
}
