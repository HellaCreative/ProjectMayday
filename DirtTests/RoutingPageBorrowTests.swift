import Foundation
import Testing
@testable import Dirt

@Suite("Reservation-backed routing page borrows")
struct RoutingPageBorrowTests {
    private func withFile(_ body: (URL) throws -> Void) throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data((0..<64).map(UInt8.init)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }
    private var limits: RoutingFilePages.Limits {
        .init(pageBytes: 8,maximumCachedBytes: 16,maximumReadBytes: 16,
            maximumLivePayloadBytes: 48,maximumLeases: 4)
    }
    @Test("Eviction and close retain accounting until the last borrow is released")
    func retainedLifetime() throws {
        try withFile { url in
            let source=try RoutingFilePages(url: url,limits: limits)
            var borrows: [RoutingPageBorrow?]=[]
            for i in 0..<4 { borrows.append(try source.borrowPage(containing: i*8)) }
            #expect(source.statistics.cachedPages == 2)
            #expect(source.statistics.cachedPayloadBytes == 32)
            #expect(source.statistics.borrowedPageReferenceBytes == 32)
            #expect(source.statistics.borrowedPageCount == 4)
            #expect(source.statistics.leaseCount == 4)
            #expect(throws: RoutingPageError.leaseLimit) { _=try source.borrowPage(containing: 32) }
            source.close()
            #expect(source.statistics.cachedPages == 0)
            #expect(source.statistics.cachedPayloadBytes == 32)
            for i in 0..<4 {
                #expect(borrows[i]?.fileOffset == i*8)
                #expect(borrows[i]?.withUnsafeBytes { Array($0) } == (i*8..<(i+1)*8).map(UInt8.init))
            }
            borrows.removeAll()
            #expect(source.statistics.cachedPayloadBytes == 0)
            #expect(source.statistics.borrowedPageReferenceBytes == 0)
            #expect(source.statistics.leaseCount == 0)
            #expect(source.statistics.peakLivePayloadBytes <= 48)
        }
    }
    @Test("Repeated borrowers share payload but each consumes a borrow slot")
    func sharedPayload() throws {
        try withFile { url in
            let source=try RoutingFilePages(url: url,limits: limits)
            var first: RoutingPageBorrow?=try source.borrowPage(containing: 1)
            var second: RoutingPageBorrow?=try source.borrowPage(containing: 7)
            #expect(first?.fileOffset == second?.fileOffset)
            #expect(source.statistics.bytesRead == 8)
            #expect(source.statistics.cachedPayloadBytes == 8)
            #expect(source.statistics.borrowedPageReferenceBytes == 16)
            #expect(source.statistics.leasedPayloadBytes == 0)
            source.close();first=nil
            #expect(source.statistics.cachedPayloadBytes == 8)
            second=nil
            #expect(source.statistics.cachedPayloadBytes == 0)
        }
    }
    @Test("Cancellation, mutation and invalid ranges do not return a borrowed page")
    func failures() throws {
        try withFile { url in
            let source=try RoutingFilePages(url: url,limits: limits)
            #expect(throws: RoutingPageError.cancelled) { _=try source.borrowPage(containing: 0,cancelled: { true }) }
            #expect(throws: RoutingPageError.invalidRange) { _=try source.borrowPage(containing: 64) }
            #expect(source.statistics.borrowedPageCount == 0)
            let handle=try FileHandle(forWritingTo: url);try handle.truncate(atOffset: 1);try handle.close()
            #expect(throws: RoutingPageError.sourceChanged) { _=try source.borrowPage(containing: 0) }
            #expect(source.statistics.borrowedPageCount == 0)
        }
    }
    @Test("Pinned pages hit the payload cap even after cache entries are evicted")
    func pinnedMemoryLimit() throws {
        try withFile { url in
            let source=try RoutingFilePages(url: url,limits: .init(pageBytes: 8,
                maximumCachedBytes: 16,maximumReadBytes: 16,
                maximumLivePayloadBytes: 48,maximumLeases: 10))
            var borrows: [RoutingPageBorrow]=[]
            for i in 0..<6 { borrows.append(try source.borrowPage(containing: i*8)) }
            #expect(throws: RoutingPageError.memoryLimit) { _=try source.borrowPage(containing: 48) }
            #expect(source.statistics.borrowedPageCount == 6)
            #expect(source.statistics.cachedPayloadBytes == 48)
            source.close();borrows.removeAll()
            #expect(source.statistics.cachedPayloadBytes == 0)
            #expect(source.statistics.borrowedPageCount == 0)
        }
    }

}
