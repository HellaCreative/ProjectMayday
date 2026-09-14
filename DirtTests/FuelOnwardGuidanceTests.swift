import Foundation
import Testing
@testable import Dirt

struct FuelOnwardGuidanceTests {
    private func station(_ id: String,_ lon: Double) -> POIFeature {
        .init(id: id,category: "fuel",latitude: 45,longitude: lon,name: nil,address: nil,
            brand: nil,openingHours: nil,phone: nil,website: nil)
    }
    @Test func refillExposesStationOutsideInitialTankAndReusesMergedFacts() async throws {
        let first = station("first",-63),second = station("second",-62),remote = station("remote",-58)
        // Initial tank reaches first, not second. After refilling, second fits.
        let initial = FuelItinerary.RoadProgress(originRemainingMeters: 400_000,
            stationRemainingMeters: [first.id: 300_000])
        var batches: [[String]] = []
        let extended = try await FuelOnwardGuidance.extending(initial,candidateID: first.id,
            reachable: [second.id: 100_000],stations: [first,second,remote],sourceIdentity: "verified-source",
            currentIdentity: { "verified-source" },check: {},load: { missing in
                batches.append(missing.map(\.id))
                return .init(originRemainingMeters: 300_000,stationRemainingMeters: [second.id: 200_000])
            })
        #expect(batches == [[second.id]])
        #expect(extended.originRemainingMeters == 400_000)
        let options = FuelItinerary.rankedProgressFuel(fuels: [first,second,remote],
            from: .init(longitude: -63,latitude: 45),to: .init(longitude: -60,latitude: 45),
            reachableMeters: [second.id: 100_000],tankMeters: 150_000,usableRangeMeters: 150_000,
            sessionSeed: 1,excluding: [first.id],roadProgress: .init(
                originRemainingMeters: extended.stationRemainingMeters[first.id]!,
                stationRemainingMeters: extended.stationRemainingMeters))
        #expect(options.contains { $0.id == second.id })
        _ = try await FuelOnwardGuidance.extending(extended,candidateID: first.id,
            reachable: [second.id: 100_000],stations: [first,second],sourceIdentity: "verified-source",
            currentIdentity: { "verified-source" },check: {},load: { _ in
                Issue.record("Previously merged facts should not require another reverse field")
                return nil
            })
    }
    @Test func sourceChangeBeforeQueryAbortsAndNegativeReachabilityDoesNotExpand() async throws {
        let existing = FuelItinerary.RoadProgress(originRemainingMeters: 200,
            stationRemainingMeters: ["first":100])
        let pump = station("second",-62)
        do {
            _ = try await FuelOnwardGuidance.extending(existing,candidateID: "first",
                reachable: [pump.id:50],stations: [pump],sourceIdentity: "old",currentIdentity: { "new" },
                check: {},load: { _ in
                    Issue.record("Changed source must abort before querying")
                    return nil
                })
            Issue.record("Source change must throw")
        } catch FuelOnwardGuidance.Failure.sourceChanged { }
        let unchanged = try await FuelOnwardGuidance.extending(existing,candidateID: "first",
            reachable: [pump.id: -1],stations: [pump],sourceIdentity: "a",currentIdentity: { "a" },
            check: {},load: { _ in
                Issue.record("Negative distance is not reachable")
                return nil
            })
        #expect(unchanged.stationRemainingMeters == existing.stationRemainingMeters)
    }
    @Test func unavailableChangedSourceAndCancellationNeverPublishFacts() async throws {
        let existing = FuelItinerary.RoadProgress(originRemainingMeters: 200,
            stationRemainingMeters: ["first":100])
        let pump = station("second",-62)
        do {
            _ = try await FuelOnwardGuidance.extending(existing,candidateID: "first",
                reachable: [pump.id: 50],stations: [pump],sourceIdentity: "a",currentIdentity: { "a" },
                check: {},load: { _ in nil })
            Issue.record("Incomplete reverse guidance must not become absence")
        } catch FuelOnwardGuidance.Failure.unavailable { }
        var identity = "a"
        do {
            _ = try await FuelOnwardGuidance.extending(existing,candidateID: "first",
                reachable: [pump.id: 50],stations: [pump],sourceIdentity: "a",currentIdentity: { identity },
                check: {},load: { _ in
                    identity = "b"
                    return .init(originRemainingMeters: 100,stationRemainingMeters: [pump.id:50])
                })
            Issue.record("Changed source must reject the result")
        } catch FuelOnwardGuidance.Failure.sourceChanged { }
        do {
            _ = try await FuelOnwardGuidance.extending(existing,candidateID: "first",
                reachable: [pump.id: 50],stations: [pump],sourceIdentity: "a",currentIdentity: { "a" },
                check: { throw CancellationError() },load: { _ in
                    Issue.record("Cancelled work must not load")
                    return nil
                })
            Issue.record("Cancellation must propagate")
        } catch is CancellationError { }
    }
}
