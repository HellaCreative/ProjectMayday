import Foundation
import CryptoKit
import Testing
@testable import DirtRoutingEngine

struct BinaryFileStreamingTests {
    @Test(arguments: [0, 17, (1 << 20) - 1, 1 << 20, (1 << 20) + 37])
    func verifiedDigestMatchesAllMappedBytes(_ size: Int) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let input = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 17) })
        try input.write(to: url)
        let file = try BinaryFile(url: url)
        let expected = Data(SHA256.hash(data: input))
        #expect(try file.sha256Digest() == expected)
        #expect(try file.sha256Digest() == expected)
        #expect(file.data == input)
        #expect(try BinaryFile(data: input).sha256Digest() == expected)
        #expect(try file.sha256 == expected.map { String(format: "%02x", $0) }.joined())
    }

    @Test func replacingPathDoesNotChangeMappedOrVerifiedIdentity() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data(repeating: 42, count: (1 << 20) + 19)
        try original.write(to: url)
        let file = try BinaryFile(url: url)
        try Data(repeating: 99, count: original.count).write(to: url, options: .atomic)
        #expect(try file.sha256Digest() == Data(SHA256.hash(data: original)))
        #expect(file.data == original)
        #expect(try file.copiedBytes(at: 1_000, count: 71) == original.subdata(in: 1_000..<1_071))
        #expect(try BinaryFile(url: url).sha256 != file.sha256)
    }

    @Test func truncatedFileFailsVerificationWithoutAccessingInvalidMapping() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 17, count: (1 << 20) + 13).write(to: url)
        let file = try BinaryFile(url: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 31)
        try handle.close()
        #expect(throws: RoutingFailure.self) { try file.sha256Digest() }
        #expect(throws: RoutingFailure.self) { try file.sha256Digest() }
        #expect(throws: RoutingFailure.self) { try file.copiedBytes(at: 0, count: 100) }
    }

    @Test func retainedColumnKeepsMappingAlive() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([7, 0, 0, 0, 9, 0, 0, 0]).write(to: url)
        let column = try MappedColumn<UInt32>(file: BinaryFile(url: url), offset: 0, count: 2)
        try FileManager.default.removeItem(at: url)
        #expect(column[0] == 7)
        #expect(column[1] == 9)
        #expect(try column.file.sha256Digest() == Data(SHA256.hash(data: Data([7,0,0,0,9,0,0,0]))))
    }

    @Test func concreteIntegerLoadsPreserveSignednessEndianAndUnalignedBoundaries() throws {
        func check<T: PackedInteger>(_ values: [T]) throws {
            var bytes = Data([0xA5]) // Deliberately unaligned for every wider type.
            for value in values {
                var littleEndian = value.littleEndian
                withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            try bytes.write(to: url)
            let mapped = try BinaryFile(url: url)
            try Data(repeating: 0, count: bytes.count).write(to: url, options: .atomic)
            for file in [mapped, BinaryFile(data: bytes)] {
                let column = try MappedColumn<T>(file: file, offset: 1, count: values.count)
                for (index, expected) in values.enumerated() {
                    #expect(column[index] == expected)
                    #expect(try file.read(1 + index * MemoryLayout<T>.size, as: T.self) == expected)
                }
                #expect(throws: RoutingFailure.self) { try file.read(-1, as: T.self) }
                #expect(throws: RoutingFailure.self) { try file.read(bytes.count, as: T.self) }
                #expect(throws: RoutingFailure.self) { try MappedColumn<T>(file: file, offset: 1, count: values.count + 1) }
            }
        }
        try check([UInt8.min, 1, 0xAB, UInt8.max])
        try check([Int8.min, -1, 0, 1, Int8.max])
        try check([UInt16.min, 1, 0xABCD, UInt16.max])
        try check([Int16.min, -1, 0, 1, Int16.max])
        try check([UInt32.min, 1, 0xABCDEF01, UInt32.max])
        try check([Int32.min, -1, 0, 1, Int32.max])
        try check([UInt64.min, 1, 0xABCDEF0123456789, UInt64.max])
        try check([Int64.min, -1, 0, 1, Int64.max])
    }

    @Test(arguments: [8, 65_536])
    func exportedBytesRetainTheirMappingAfterTheFileOwnerIsReleased(_ size: Int) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try expected.write(to: url)
        func exported() throws -> Data { try BinaryFile(url: url).data }
        let bytes = try exported()
        try FileManager.default.removeItem(at: url)
        #expect(bytes == expected)
        #expect(Data(SHA256.hash(data: bytes)) == Data(SHA256.hash(data: expected)))
    }
}
