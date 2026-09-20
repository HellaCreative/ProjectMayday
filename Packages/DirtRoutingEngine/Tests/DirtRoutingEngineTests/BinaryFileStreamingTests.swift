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
}
