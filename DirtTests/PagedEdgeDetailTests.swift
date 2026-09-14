import CryptoKit
import Foundation
import Testing
@testable import Dirt

@Suite("Paged V4 edge detail", .serialized)
struct PagedEdgeDetailTests {
    private func fixture(edges: Int = 20_000, crossing: Bool = true) -> Data {
        // Deliberately unaligned: a crossing value spans a 64KiB page.
        let first = 141
        let crossingAt = first+edges*7
        var data = Data(count: crossingAt+(crossing ? edges*4 : 0))
        func put<T: FixedWidthInteger>(_ value: T, _ offset: Int) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<(offset+$0.count),with: $0) }
        }
        put(GraphV2Pack.magicV4,0); put(UInt16(4),4)
        put(UInt16(8|2|(crossing ? 4 : 0)),6); put(UInt32(edges),12); put(UInt32(140),20)
        for column in 0..<7 {
            put(UInt32(first+column*edges),72+column*4)
            for edge in 0..<edges { data[first+column*edges+edge] = UInt8(truncatingIfNeeded: edge+column*37) }
        }
        if crossing {
            put(UInt32(crossingAt),100)
            for edge in 0..<edges { put(UInt32(truncatingIfNeeded: edge*7919),crossingAt+edge*4) }
        }
        return data
    }
    private func expected(_ edge: Int, crossing: Bool = true) -> PagedEdgeDetail.Row {
        .init(surface: UInt8(truncatingIfNeeded: edge),roadClass: UInt8(truncatingIfNeeded: edge+37),
            grade: UInt8(truncatingIfNeeded: edge+74),layer: Int8(bitPattern: UInt8(truncatingIfNeeded: edge+111)),
            structure: UInt8(truncatingIfNeeded: edge+148),accessLeaf: UInt8(truncatingIfNeeded: edge+185),
            flags: UInt8(truncatingIfNeeded: edge+222),crossingSeconds: crossing ? UInt32(truncatingIfNeeded: edge*7919) : nil)
    }
    private func file(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("edge-detail-"+UUID().uuidString)
        try data.write(to: url); return url
    }
    private func identity(_ data: Data,edges: Int = 20_000) -> PagedEdgeDetail.Identity {
        .init(sha256: SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined(),bytes: data.count,edgeCount: edges)
    }
    @Test func oneColumnDoesNotBorrowOtherColumnsAndFullRowRemainsExact() throws {
        // Every column begins in a different page. Header/hash preparation is
        // outside the query counters; a scalar surface lookup needs one lease.
        let count = 65_536, data = fixture(edges: 65_536), url = try file(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try PagedEdgeDetail(url: url,identity: identity(data,edges: count))
        try reader.withQuery { query in
            let surface = try query.value(.surface,at: 17)
            #expect(surface == 17)
            #expect(query.statistics.pageBorrows == 1)
            try reader.withQuery { other in
                let reused = try other.value(.surface,at: 17)
                #expect(reused == 17 && other.statistics.rowHits == 1)
                #expect(other.statistics.pageBorrows == 0)
            }
            let row = try query.row(at: 17)
            #expect(row == expected(17))
            #expect(query.statistics.pageBorrows == 8)
            let expectedValues: [UInt32?] = [UInt32(row.surface),UInt32(row.roadClass),
                UInt32(row.grade),UInt32(UInt8(bitPattern: row.layer)),UInt32(row.structure),
                UInt32(row.accessLeaf),UInt32(row.flags),row.crossingSeconds]
            for (field,value) in zip(PagedEdgeDetail.Field.allCases,expectedValues) {
                let actual = try query.value(field,at: 17)
                #expect(actual == value)
            }
            #expect(query.statistics.pageBorrows == 8)
            #expect(query.statistics.allocatedRowPayloadBytes == reader.sharedRowPayloadBytes)
            #expect(reader.sharedRowPayloadBytes <= 16_384)
        }
    }
    @Test func partialPresenceDoesNotLeakAcrossCollisionOrAbsentCrossing() throws {
        var limits = PagedEdgeDetail.Limits(); limits.rowSlots = 1
        let reader = try PagedEdgeDetail(data: fixture(edges: 3,crossing: false),
            expectedEdgeCount: 3,limits: limits)
        try reader.withQuery { query in
            _ = try query.value(.surface,at: 0)
            let road = try query.value(.roadClass,at: 1)
            #expect(road == UInt32(expected(1).roadClass))
            let row = try query.row(at: 0)
            #expect(row == expected(0,crossing: false))
            let crossing = try query.value(.crossingSeconds,at: 0)
            #expect(crossing == nil)
        }
    }
    @Test func selectiveCachedReadsStillHonorCancellationAndClosingSourceValidation() throws {
        let data = fixture(edges: 3),url = try file(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try PagedEdgeDetail(url: url,identity: identity(data,edges: 3))
        var cancelled = false
        #expect(throws: RoutingPageError.cancelled) {
            try reader.withQuery(cancelled: { cancelled }) { query in
                _ = try query.value(.surface,at: 0); cancelled = true
                _ = try query.value(.surface,at: 0)
            }
        }
        #expect(throws: RoutingPageError.sourceChanged) {
            try reader.withQuery { query in
                _ = try query.value(.surface,at: 0)
                var changed = data; changed.append(0)
                try changed.write(to: url)
                // Cache hits do not exempt the enclosing operation's validation.
                _ = try query.value(.surface,at: 0)
            }
        }
    }
    @Test func exactRowsAndBoundedPages() throws {
        let data = fixture(), url = try file(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let disk = try PagedEdgeDetail(url: url,identity: identity(data))
        let memory = try PagedEdgeDetail(data: data,expectedEdgeCount: 20_000)
        try disk.withQuery { query in
            try memory.withQuery { fixtureQuery in
                for edge in 0..<20_000 {
                    let actual = try query.row(at: edge)
                    #expect(actual == expected(edge))
                    let cached = try query.row(at: edge), reference = try fixtureQuery.row(at: edge)
                    #expect(cached == reference)
                }
            }
            #expect(query.statistics.rowHits == 20_000)
            #expect(query.statistics.decodedRows == 20_000)
            #expect(query.statistics.allocatedRowPayloadBytes <= 16_384)
            #expect(query.statistics.pageBorrows < 100) // bounded windows, not eight borrows per row
        }
        #expect((disk.pageStatistics?.leaseCount ?? Int.max) <= 8)
        #expect((disk.pageStatistics?.peakLivePayloadBytes ?? Int.max) <= 1_179_648)
    }
    @Test func cacheCollisionMissingSectionAndScopeLifetime() throws {
        let reader = try PagedEdgeDetail(data: fixture(edges: 600,crossing: false),expectedEdgeCount: 600)
        var captured: PagedEdgeDetail.Query?
        try reader.withQuery { query in
            captured = query
            for edge in [0,512,0,599] {
                let actual = try query.row(at: edge)
                #expect(actual == expected(edge,crossing: false))
            }
            #expect(throws: PagedEdgeDetail.Failure.invalidEdge) { try query.row(at: -1) }
            #expect(throws: PagedEdgeDetail.Failure.invalidEdge) { try query.row(at: 600) }
            try reader.withQuery { nested in
                let actual = try nested.row(at: 0)
                #expect(actual == expected(0,crossing: false))
            }
        }
        let query = try #require(captured)
        #expect(throws: PagedEdgeDetail.Failure.queryClosed) { try query.row(at: 0) }
        #expect(query.statistics.allocatedRowPayloadBytes == 0)
    }
    @Test func cancellationAlsoStopsCachedRows() throws {
        let reader = try PagedEdgeDetail(data: fixture(edges: 3),expectedEdgeCount: 3)
        var cancelled = false
        #expect(throws: RoutingPageError.cancelled) {
            try reader.withQuery(cancelled: { cancelled }) { query in
                _ = try query.row(at: 0); cancelled = true
                _ = try query.row(at: 0)
            }
        }
    }
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock();private var value = false
        func set() { lock.lock();value = true;lock.unlock() }
        func get() -> Bool { lock.lock();defer { lock.unlock() };return value }
    }
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock();private var value: RoutingPageError?
        func set(_ error: Error) { lock.lock();value = error as? RoutingPageError;lock.unlock() }
        func get() -> RoutingPageError? { lock.lock();defer { lock.unlock() };return value }
    }
    @Test func overlappingReadAndCancelledOldQueryShareOneBound() throws {
        let data = fixture(),url = try file(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try PagedEdgeDetail(url: url,identity: identity(data))
        let entered = DispatchSemaphore(value: 0),release = DispatchSemaphore(value: 0),finished = DispatchSemaphore(value: 0)
        let cancelled = Flag(),outcome = Outcome()
        defer { release.signal();_ = finished.wait(timeout: .now()+2) }
        DispatchQueue.global().async {
            do {
                try reader.withQuery(cancelled: { cancelled.get() }) { query in
                    _ = try query.row(at: 0);entered.signal()
                    guard release.wait(timeout: .now()+2) == .success else { throw RoutingPageError.cancelled }
                    _ = try query.row(at: 0)
                }
            } catch { outcome.set(error) }
            finished.signal()
        }
        try #require(entered.wait(timeout: .now()+2) == .success)
        // The old calculation remains open: this must neither wait for it nor
        // report a queryBusy data error. Both queries use one global row cache.
        try reader.withQuery { query in
            let actual = try query.row(at: 19999)
            #expect(actual == expected(19999))
            #expect(reader.sharedRowPayloadBytes <= 16_384)
        }
        cancelled.set();release.signal()
        try #require(finished.wait(timeout: .now()+2) == .success)
        finished.signal() // balanced with deferred cleanup wait
        #expect(outcome.get() == .cancelled)
        #expect((reader.pageStatistics?.leaseCount ?? Int.max) <= 8)
        #expect((reader.pageStatistics?.peakLivePayloadBytes ?? Int.max) <= 1_179_648)
        // Cancellation of the old query must not poison a subsequent edit.
        try reader.withQuery { query in
            let actual = try query.row(at: 1)
            #expect(actual == expected(1))
        }
    }
    @Test func sourceChangeRejectsBothOverlappingQueries() throws {
        let data = fixture(),url = try file(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try PagedEdgeDetail(url: url,identity: identity(data))
        let entered = DispatchSemaphore(value: 0),release = DispatchSemaphore(value: 0),finished = DispatchSemaphore(value: 0)
        let results = [Outcome(),Outcome()]
        defer { release.signal();release.signal() }
        for result in results {
            DispatchQueue.global().async {
                do {
                    try reader.withQuery { query in
                        _ = try query.row(at: 0);entered.signal()
                        guard release.wait(timeout: .now()+2) == .success else { throw RoutingPageError.cancelled }
                        return try query.row(at: 0)
                    }
                } catch { result.set(error) }
                finished.signal()
            }
        }
        try #require(entered.wait(timeout: .now()+2) == .success)
        try #require(entered.wait(timeout: .now()+2) == .success)
        let handle = try FileHandle(forWritingTo: url);defer { try? handle.close() }
        try handle.truncate(atOffset: 140)
        release.signal();release.signal()
        try #require(finished.wait(timeout: .now()+2) == .success)
        try #require(finished.wait(timeout: .now()+2) == .success)
        #expect(results.allSatisfy { $0.get() == .sourceChanged })
        #expect((reader.pageStatistics?.leaseCount ?? Int.max) <= 8)
    }
    @Test func malformedIdentityAndMutationAreErrors() throws {
        var malformed = fixture(edges: 3)
        malformed[72] = 0; malformed[73] = 0; malformed[74] = 0; malformed[75] = 0
        #expect(throws: PagedEdgeDetail.Failure.invalidLayout) { try PagedEdgeDetail(data: malformed,expectedEdgeCount: 3) }
        #expect(throws: PagedEdgeDetail.Failure.invalidLayout) { try PagedEdgeDetail(data: Data(repeating: 0,count: 139),expectedEdgeCount: 0) }
        var overlap = fixture(edges: 3)
        let firstColumn = Data(overlap[72..<76])
        overlap.replaceSubrange(76..<80,with: firstColumn)
        #expect(throws: PagedEdgeDetail.Failure.invalidLayout) { try PagedEdgeDetail(data: overlap,expectedEdgeCount: 3) }
        let data = fixture(), url = try file(data)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: PagedEdgeDetail.Failure.identityMismatch) {
            try PagedEdgeDetail(url: url,identity: .init(sha256: "wrong",bytes: data.count,edgeCount: 20_000))
        }
        let reader = try PagedEdgeDetail(url: url,identity: identity(data))
        #expect(throws: RoutingPageError.sourceChanged) {
            try reader.withQuery { query in
                _ = try query.row(at: 0)
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 140)
                // Cached bytes can be read internally, but post-query validation
                // must reject publication even if no further cache miss occurs.
                return try query.row(at: 0)
            }
        }
        #expect((reader.pageStatistics?.leaseCount ?? Int.max) <= 8)
    }
}
