import Foundation
import Testing
@testable import Dirt

struct StationCellCoverageTests {
    @Test func nearbyStationsReuseOnlyCompleteCellCoverageAndReevaluateTheirOwnBounds() throws {
        let owner = NSObject(), index = NSObject(), cache = StationCoverageCache()
        var scans = 0
        func run(_ latitude: Double, _ longitude: Double, _ radius: Double, _ superset: Bool,
                 _ accepted: Int) throws -> [Int] {
            var seen: [Int] = []
            try cache.enumerate(owner: owner, index: index, latitude: latitude, longitude: longitude,
                meters: radius, cellSuperset: superset, cancelled: { false }, visit: {
                    // Independent station-specific bounds/distance predicate.
                    if $0 == accepted { seen.append($0) }
                }) { emit in scans += 1; try emit(1); try emit(2) }
            return seen
        }
        #expect(try run(45.011,-63.011,550,true,1) == [1])
        #expect(try run(45.019,-63.019,550,true,2) == [2])
        #expect(scans == 1)
        // Same ring coverage is safe even if the precise distance changes.
        #expect(try run(45.019,-63.019,600,true,2) == [2])
        #expect(scans == 1)
        _ = try run(45.061,-63.011,550,true,1)
        _ = try run(45.011,-63.061,550,true,1)
        _ = try run(45.011,-63.011,6000,true,1)
        #expect(scans == 4)
        // Point-filtered coverage must never share a nearby station's key.
        _ = try run(45.011,-63.011,550,false,1)
        _ = try run(45.019,-63.019,550,false,2)
        #expect(scans == 6)
    }
    @Test func sharedCoverageNeverPublishesAPartialEnumeration() throws {
        enum Stop: Error { case found }
        let owner = NSObject(), index = NSObject(), cache = StationCoverageCache()
        #expect(throws: Stop.found) {
            try cache.enumerate(owner: owner,index: index,latitude: 45.011,longitude: -63.011,
                meters: 550,cellSuperset: true,cancelled: { false },visit: { _ in throw Stop.found }) {
                    emit in try emit(1);try emit(2)
                }
        }
        var rescanned = false, seen: [Int] = []
        try cache.enumerate(owner: owner,index: index,latitude: 45.019,longitude: -63.019,
            meters: 550,cellSuperset: true,cancelled: { false },visit: { seen.append($0) }) {
                emit in rescanned = true;try emit(1);try emit(2)
            }
        #expect(rescanned && seen == [1,2])
    }
    @Test func malformedCoverageRadiusDoesNotTrapOrCreateAKey() {
        for radius in [Double.nan,Double.infinity,-1,Double.greatestFiniteMagnitude] {
            #expect(throws: ExactSnapIndex.Failure.invalidFormat) {
                _ = try StationCoverageCache.coverageRadius(meters: radius)
            }
        }
    }
}
