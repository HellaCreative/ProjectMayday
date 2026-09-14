import Foundation
import Testing
@testable import Dirt

@Suite("Bounded immutable routing file pages")
struct RoutingFilePagesTests {
    private func withFile<T>(_ bytes: Data, _ body: (URL) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("immutable.bin")
        try bytes.write(to: file)
        return try body(file)
    }

    private var limits: RoutingFilePages.Limits {
        .init(pageBytes: 8, maximumCachedBytes: 16, maximumReadBytes: 16,
            maximumLivePayloadBytes: 48, maximumLeases: 4)
    }

    @Test("Unaligned little-endian columns decode every existing graph scalar and both geometry widths")
    func scalarDecoding() throws {
        func check<T: RoutingLittleEndianScalar & Equatable>(_ bytes: [UInt8], _ expected: T) throws {
            let column = try RoutingByteColumn<T>(data: Data([127] + bytes), byteOffset: 1, count: 1)
            #expect(column[0] == expected)
            #expect(Array(column) == [expected])
        }
        try check([254], UInt8(254))
        try check([254], Int8(-2))
        try check([0x34, 0x12], UInt16(0x1234))
        try check([254, 255, 255, 255], Int32(-2))
        try check([0x78, 0x56, 0x34, 0x12], UInt32(0x12345678))
        try check([254, 255, 255, 255, 255, 255, 255, 255], Int64(-2))
        try check([0, 0, 192, 63], Float(1.5))
        try check([0, 0, 0, 0, 0, 0, 248, 63], Double(1.5))
        #expect(throws: RoutingPageError.invalidRange) {
            try RoutingByteColumn<Int64>(data: Data([1, 2, 3]), count: 1)
        }
        #expect(throws: RoutingPageError.invalidRange) {
            try RoutingByteColumn<Int64>(data: Data([1]), count: Int.max)
        }
    }

    @Test("Range leases cross pages exactly and reuse immutable cached bytes")
    func crossPageAndReuse() throws {
        try withFile(Data((0..<40).map(UInt8.init))) { file in
            let source = try RoutingFilePages(url: file, limits: limits)
            defer { source.close() }
            let column = try RoutingPagedColumn<UInt32>(source: source, byteOffset: 1, count: 8)
            let first = try column.lease(1..<3)
            #expect(first.startIndex == 1)
            #expect(first.endIndex == 3)
            #expect(first[1] == 0x08070605)
            #expect(first[2] == 0x0c0b0a09)
            let before = source.statistics.readCalls
            #expect(try column.value(at: 1) == first[1])
            #expect(source.statistics.readCalls == before)
            #expect(source.statistics.cacheHits > 0)
            #expect(source.statistics.peakLivePayloadBytes <= limits.maximumLivePayloadBytes)
        }
    }

    @Test("Pinned leases consume the live payload budget even after cache eviction")
    func retainedLeaseBudget() throws {
        try withFile(Data(repeating: 23, count: 24)) { file in
            let small = RoutingFilePages.Limits(pageBytes: 8, maximumCachedBytes: 8,
                maximumReadBytes: 8, maximumLivePayloadBytes: 16, maximumLeases: 4)
            let source = try RoutingFilePages(url: file, limits: small)
            var retained: RoutingByteLease? = try source.read(at: 0, count: 8)
            withExtendedLifetime(retained) {
                #expect(throws: RoutingPageError.memoryLimit) { try source.read(at: 8, count: 8) }
                #expect(source.statistics.leasedPayloadBytes == 8)
                #expect(source.statistics.peakLivePayloadBytes <= 16)
            }
            retained = nil
            let next = try source.read(at: 8, count: 8)
            #expect(next.withUnsafeBytes { $0[0] } == 23)
            source.close()
            // Closing a descriptor does not invalidate or unaccount its leases.
            withExtendedLifetime(next) {
                #expect(source.statistics.cachedPayloadBytes == 0)
                #expect(source.statistics.leasedPayloadBytes == 8)
                #expect(next.withUnsafeBytes { $0[7] } == 23)
            }
        }
    }

    @Test("Typed views retain their lease after closing the file source")
    func columnOwnsLease() throws {
        try withFile(Data([1, 0, 0, 0, 2, 0, 0, 0])) { file in
            let source = try RoutingFilePages(url: file, limits: limits)
            let column = try RoutingPagedColumn<Int32>(source: source, byteOffset: 0, count: 2)
            let view = try column.lease(0..<2)
            source.close()
            #expect(Array(view) == [1, 2])
            #expect(source.statistics.leasedPayloadBytes == 8)
            #expect(throws: RoutingPageError.closed) { try column.value(at: 0) }
        }
    }

    @Test("Cancellation, oversized ranges and closed reads never return fabricated bytes")
    func cancellationAndReadErrors() throws {
        try withFile(Data(repeating: 7, count: 40)) { file in
            let source = try RoutingFilePages(url: file, limits: limits)
            #expect(throws: RoutingPageError.cancelled) {
                try source.read(at: 0, count: 8, cancelled: { true })
            }
            var callbacks = 0
            #expect(throws: RoutingPageError.cancelled) {
                try source.read(at: 0, count: 8, cancelled: { callbacks += 1; return callbacks > 1 })
            }
            #expect(source.statistics.leasedPayloadBytes == 0)
            #expect(throws: RoutingPageError.readTooLarge) { try source.read(at: 0, count: 17) }
            #expect(throws: RoutingPageError.invalidRange) { try source.read(at: Int.max, count: 1) }
            source.close()
            #expect(throws: RoutingPageError.closed) { try source.read(at: 0, count: 1) }
        }
    }

    @Test("Truncating an opened source rejects both cached and uncached reads")
    func sourceMutation() throws {
        try withFile(Data(repeating: 11, count: 40)) { file in
            let source = try RoutingFilePages(url: file, limits: limits)
            _ = try source.read(at: 0, count: 4)
            let writer = try FileHandle(forWritingTo: file)
            try writer.truncate(atOffset: 1)
            try writer.close()
            #expect(throws: RoutingPageError.sourceChanged) { try source.read(at: 0, count: 4) }
            #expect(throws: RoutingPageError.sourceChanged) { try source.read(at: 24, count: 4) }
            #expect(source.statistics.leasedPayloadBytes == 0)
        }
    }

    @Test("Zero-length leases are count-bounded and opening missing files fails")
    func leaseCountAndOpenFailure() throws {
        try withFile(Data([1])) { file in
            let one = RoutingFilePages.Limits(pageBytes: 8, maximumCachedBytes: 8,
                maximumReadBytes: 8, maximumLivePayloadBytes: 16, maximumLeases: 1)
            let source = try RoutingFilePages(url: file, limits: one)
            let empty = try source.read(at: 0, count: 0)
            withExtendedLifetime(empty) {
                #expect(throws: RoutingPageError.leaseLimit) { try source.read(at: 0, count: 0) }
            }
            #expect(throws: (any Error).self) {
                try RoutingFilePages(url: file.deletingLastPathComponent().appendingPathComponent("missing"), limits: one)
            }
        }
    }
}
