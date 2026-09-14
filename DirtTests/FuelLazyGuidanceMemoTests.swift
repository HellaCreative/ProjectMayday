import CoreLocation
import Foundation
import Testing
@testable import Dirt

@MainActor struct FuelLazyGuidanceMemoTests {
    private func key(epoch: String = "source",from: Double = 1,cap: Double = 180_000) -> FuelLazyGuidanceMemo.Key {
        .init(epoch: epoch,graph: "graph",geometry: "geometry",from: .init(longitude: from,latitude: 45),
            to: .init(longitude: 4,latitude: 45),station: .init(longitude: 2,latitude: 45),
            profile: "dirt",allowUnknown: false,cap: cap)
    }
    private func prepared() -> LazyOnwardStationPreparation.Prepared {
        let point = LazyOnwardStationPreparation.Point(.init(latitude: 45,longitude: -63))
        let request = LazyOnwardStationPreparation.Request(source: .init(graphSHA256: "graph",graphBytes: 1,geometrySHA256: "geometry",geometryBytes: 1),
            origin: point,destination: point,stations: [point,point,point],profile: .dirt,allowUnknown: false,
            usableMeters: 180_000,radiusMeters: 550,formatVersion: LazyOnwardStationPreparation.version)
        return .init(request: request,hints: [.init(stationIndex: 0,forwardEstimate: 50,remainingEstimate: 10),
            .init(stationIndex: 1,forwardEstimate: nil,remainingEstimate: nil),
            .init(stationIndex: 2,forwardEstimate: 100,remainingEstimate: 20)],statistics: .init(elapsedSeconds: 0,
                completedFields: 2,parentMembershipVisits: 0,retainedHintPayloadBytes: 0,stationProjectionQueries: 0))
    }
    @Test func unknownHintsRemainEligibleAfterEarlierCandidatesFail() {
        let order = FuelLazyGuidanceMemo.eligibleIndices(prepared(),ids: ["first","later-unknown","third"],excluding: [])
        #expect(Set(order) == Set([0,1,2]))
        // Only the unknown-hint station later has a proven continuation.
        #expect(order.first(where: { $0 == 1 }) == 1)
        let required = FuelLazyGuidanceMemo.eligibleIndices(prepared(),ids: ["first","later-unknown","third"],excluding: [],required: "later-unknown")
        #expect(required == [1])
        let excluded = FuelLazyGuidanceMemo.eligibleIndices(prepared(),ids: ["osm:a20","osm:w10","third"],excluding: ["osm:w10"])
        #expect(excluded == [2])
    }
    @Test func failedContinuationAdvancesToUnknownHintAndStopsAfterProof() async throws {
        let order = FuelLazyGuidanceMemo.eligibleIndices(prepared(),ids: ["first","later-unknown","third"],excluding: [])
        var visited: [Int] = []
        let accepted = try await FuelLazyGuidanceMemo.firstProvenIndex(order) { index in
            visited.append(index);return index == 1
        }
        #expect(accepted == 1)
        #expect(visited.count == 3) // Both earlier hinted candidates failed.
        let exhausted = try await FuelLazyGuidanceMemo.firstProvenIndex(order) { _ in false }
        #expect(exhausted == nil) // No gap classification is produced by the queue.
        var active = true
        await #expect(throws: (any Error).self) {
            try await FuelLazyGuidanceMemo.firstProvenIndex(order,check: {
                if !active { throw RoutingPageError.cancelled }
            }) { _ in active = false;return true }
        }
    }
    @Test func onlyCompletedExactFactsAreReusedAndDirectionRangeRemainDistinct() async throws {
        let memo = FuelLazyGuidanceMemo()
        let fact = FuelLazyGuidanceMemo.Fact(forward: 100,originRemaining: 1_000,remaining: 800)
        var loads = 0
        for _ in 0..<2 {
            _ = try await memo.resolve(key(),currentIdentity: { "source" }) { loads += 1;return fact }
        }
        #expect(loads == 1 && memo.hits == 1)
        // Same pump approached from another direction or with another tank cap
        // cannot consume the previous field fact.
        _ = try await memo.resolve(key(from: 3),currentIdentity: { "source" }) { loads += 1;return fact }
        _ = try await memo.resolve(key(cap: 500),currentIdentity: { "source" }) { loads += 1;return fact }
        #expect(loads == 3)
        for _ in 0..<2 {
            _ = try await memo.resolve(key(cap: 600),currentIdentity: { "source" }) {
                loads += 1;return .init(forward: nil,originRemaining: nil,remaining: nil)
            }
        }
        #expect(loads == 5) // Unknown is not cached as a demonstrated fuel gap.
    }
    @Test func sourceChangesAndCancellationNeverReturnAnOldFact() async throws {
        let memo = FuelLazyGuidanceMemo()
        var epoch = "source"
        let fact = FuelLazyGuidanceMemo.Fact(forward: 100,originRemaining: 1_000,remaining: 800)
        await #expect(throws: (any Error).self) {
            try await memo.resolve(key(),currentIdentity: { epoch }) { epoch = "replacement";return fact }
        }
        epoch = "source"
        _ = try await memo.resolve(key(),currentIdentity: { epoch }) { fact }
        await #expect(throws: (any Error).self) {
            try await memo.resolve(key(),currentIdentity: { epoch },check: { throw RoutingPageError.cancelled }) { fact }
        }
        #expect(memo.hits == 0)
    }
}
