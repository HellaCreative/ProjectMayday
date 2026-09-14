import Foundation
import Testing
@testable import Dirt

@Suite("Bounded snap bounds queries")
struct ExactSnapBoundsQueryTests {
    private func fixture(_ body: (ExactSnapIndex,URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("index")
        let identity = ExactSnapIndex.Identity(graphSHA256: "fixture",graphBytes: 1,geometrySHA256: "fixture",geometryBytes: 1)
        try ExactSnapIndexBuilder.build(to: url,identity: identity,edgeCount: 7000) { edge in
            let value = Double(edge%10)*0.0001
            return .init(aLon: value,aLat: value,bLon: value,bLat: value,
                minLon: value,maxLon: value,minLat: value,maxLat: value)
        }
        let index = try ExactSnapIndex(url: url,identity: identity)
        try body(index,url)
    }
    @Test("Same-block rows do not re-read or allocate a range per predicate")
    func rowReuse() throws {
        try fixture { index,_ in
            try index.withBoundsQuery { query in
                _ = try query.mayIntersect(edge: 0,latitude: 0,longitude: 0,meters: 100)
                let first = index.statistics
                for edge in 0..<1000 {
                    #expect(try query.mayIntersect(edge: edge,latitude: 0,longitude: 0,meters: 1000))
                }
                let last = index.statistics
                #expect(last.cacheHits == first.cacheHits)
                #expect(last.cacheMisses == first.cacheMisses)
                #expect(last.readCalls == first.readCalls)
                #expect(last.leasedPayloadBytes == 0)
                #expect(last.borrowedPageReferenceBytes == 65_536)
                #expect(last.borrowedPageCount == 1)
                #expect(last.leaseCount == 1)
            }
            #expect(index.statistics.leasedPayloadBytes == 0)
            #expect(index.statistics.borrowedPageCount == 0)
        }
    }
    @Test("Collisions and final partial block preserve exact old predicate")
    func collisions() throws {
        try fixture { index,_ in
            let edges = [0,1637,1638,3276,4914,6552,6999,0,6552,1638]
            let expected = try edges.map { try index.mayIntersect(edge: $0,latitude: 0.0003,longitude: 0.0003,meters: 1) }
            try index.withBoundsQuery { query in
                let actual = try edges.map { try query.mayIntersect(edge: $0,latitude: 0.0003,longitude: 0.0003,meters: 1) }
                #expect(actual == expected)
                #expect(index.statistics.borrowedPageReferenceBytes <= 4*65_536)
                #expect(index.statistics.borrowedPageCount <= 4)
                #expect(index.statistics.peakLivePayloadBytes <= index.statistics.maximumLivePayloadBytes)
            }
        }
    }
    @Test("Mutation of a cached source rejects the entire query result")
    func changedSource() throws {
        try fixture { index,url in
            var queryReturned = false
            #expect(throws: (any Error).self) {
                _ = try index.withBoundsQuery { query in
                    _ = try query.mayIntersect(edge: 0,latitude: 0,longitude: 0,meters: 100)
                    let writer = try FileHandle(forWritingTo: url)
                    try writer.truncate(atOffset: 100); try writer.close()
                    // Owned cached bytes may still be read, but cannot qualify
                    // a completed query after the source identity changed.
                    return try query.mayIntersect(edge: 1,latitude: 0,longitude: 0,meters: 100)
                }
                queryReturned = true
            }
            #expect(!queryReturned)
            #expect(index.statistics.leasedPayloadBytes == 0)
            #expect(index.statistics.borrowedPageCount == 0)
        }
    }
    @Test("Cancellation closes retained queries and releases their leases")
    func cancelledAndEscaped() throws {
        try fixture { index,_ in
            var cancelled = false
            var retained: ExactSnapIndex.BoundsQuery?
            #expect(throws: RoutingPageError.cancelled) {
                try index.withBoundsQuery(cancelled: { cancelled }) { query in
                    retained = query
                    _ = try query.mayIntersect(edge: 0,latitude: 0,longitude: 0,meters: 100)
                    cancelled = true
                }
            }
            let escaped = try #require(retained)
            #expect(throws: RoutingPageError.closed) {
                _ = try escaped.mayIntersect(edge: 0,latitude: 0,longitude: 0,meters: 100)
            }
            #expect(index.statistics.leasedPayloadBytes == 0)
            #expect(index.statistics.borrowedPageCount == 0)
        }
    }
    @Test func nestedReuseSharesReservationsAndRetainsOuterOwnership() throws {
        try fixture { index,_ in
            var retained: ExactSnapIndex.BoundsQuery?
            try index.withBoundsQuery { outer in
                retained = outer
                for edge in [0,1638,3276,4914] {
                    _ = try index.mayIntersect(edge: edge,latitude: 0,longitude: 0,meters: 100,query: outer)
                }
                #expect(index.statistics.borrowedPageCount == 4)
                try index.withBoundsQuery(reusing: outer) { inner in
                    #expect(inner === outer)
                    var count = 0
                    try index.forEachEdge(nearLat: 0,lon: 0,radiusCells: 0,query: inner) { edge in
                        _ = try index.mayIntersect(edge: edge,latitude: 0,longitude: 0,meters: 100,query: inner)
                        count += 1
                        #expect(index.statistics.leaseCount <= 8)
                    }
                    #expect(count == 7000)
                }
                #expect(try outer.mayIntersect(edge: 0,latitude: 0,longitude: 0,meters: 100))
                #expect(index.statistics.peakLivePayloadBytes <= index.statistics.maximumLivePayloadBytes)
            }
            #expect(index.statistics.leaseCount == 0)
            #expect(index.statistics.borrowedPageCount == 0)
            let escaped = try #require(retained)
            #expect(throws: RoutingPageError.closed) {
                _ = try index.mayIntersect(edge: 0,latitude: 0,longitude: 0,meters: 100,query: escaped)
            }
        }
    }

    @Test func sharedQueryRejectsDifferentIndexAndExplicitCancellation() throws {
        try fixture { index,_ in
            try fixture { other,_ in
                try index.withBoundsQuery { query in
                    #expect(throws: ExactSnapIndex.Failure.identityMismatch) {
                        _ = try other.mayIntersect(edge: 0,latitude: 0,longitude: 0,meters: 100,query: query)
                    }
                    #expect(throws: ExactSnapIndex.Failure.identityMismatch) {
                        try other.withBoundsQuery(reusing: query) { _ in Issue.record("Foreign query accepted") }
                    }
                    #expect(throws: (any Error).self) {
                        _ = try index.mayIntersect(edge: 0,latitude: 0,longitude: 0,meters: 100,
                            query: query,cancelled: { true })
                    }
                    var cancelled = false
                    #expect(throws: (any Error).self) {
                        try index.withBoundsQuery(reusing: query,cancelled: { cancelled }) { _ in
                            cancelled = true
                        }
                    }
                }
            }
        }
    }

    @Test func nestedResultCannotQualifyChangedSourceBeforeOuterClose() throws {
        try fixture { index,url in
            var returned = false
            #expect(throws: (any Error).self) {
                _ = try index.withBoundsQuery { outer in
                    _ = try outer.mayIntersect(edge: 0,latitude: 0,longitude: 0,meters: 100)
                    let provisional = try index.withBoundsQuery(reusing: outer) { inner in
                        try inner.mayIntersect(edge: 1,latitude: 0,longitude: 0,meters: 100)
                    }
                    let writer = try FileHandle(forWritingTo: url)
                    try writer.truncate(atOffset: 100)
                    try writer.close()
                    return provisional
                }
                returned = true
            }
            #expect(!returned)
            #expect(index.statistics.leaseCount == 0)
            #expect(index.statistics.borrowedPageCount == 0)
        }
    }

}
