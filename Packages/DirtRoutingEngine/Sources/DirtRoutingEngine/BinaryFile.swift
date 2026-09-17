import Foundation
import CryptoKit

/// Retains mapped bytes, not a decoded copy of each regional graph array.
final class BinaryFile: @unchecked Sendable {
    let data: Data
    private var cachedSHA256: String?
    private var cachedDigest: Data?
    init(url: URL) throws {
        guard url.isFileURL else { throw RoutingFailure.invalidPack("local file required") }
        data = try Data(contentsOf: url, options: .alwaysMapped)
    }
    init(data: Data) { self.data = data }
    func range(_ offset: Int, _ count: Int, stride: Int = 1) throws {
        guard offset >= 0, count >= 0, stride > 0, offset <= data.count,
              count <= (data.count - offset) / stride else {
            throw RoutingFailure.invalidPack("section outside file")
        }
    }
    func read<T: FixedWidthInteger>(_ offset: Int, as: T.Type = T.self) throws -> T {
        try range(offset, 1, stride: MemoryLayout<T>.size)
        return unchecked(offset, as: T.self)
    }
    func unchecked<T: FixedWidthInteger>(_ offset: Int, as: T.Type = T.self) -> T {
        data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
    func json<T: Decodable>(_ start: Int, _ end: Int, as type: T.Type) throws -> T {
        try range(start, end - start)
        do { return try JSONDecoder().decode(type, from: data.subdata(in: start..<end)) }
        catch { throw RoutingFailure.invalidPack("invalid JSON section: \(error)") }
    }
    /// Raw digest; hex form is derived from the same cached bytes.
    func sha256Digest() -> Data {
        if let cachedDigest { return cachedDigest }
        let digest = Data(SHA256.hash(data: data))
        cachedDigest = digest
        cachedSHA256 = digest.map { String(format: "%02x", $0) }.joined()
        return digest
    }
    /// Hash once per mapped file; open used to recompute SHA256 several times.
    var sha256: String {
        if let cachedSHA256 { return cachedSHA256 }
        _ = sha256Digest()
        return cachedSHA256!
    }
}

struct MappedColumn<T: FixedWidthInteger>: Sendable {
    let file: BinaryFile
    let offset: Int
    let count: Int
    init(file: BinaryFile, offset: Int, count: Int) throws {
        try file.range(offset, count, stride: MemoryLayout<T>.size)
        self.file = file; self.offset = offset; self.count = count
    }
    subscript(_ i: Int) -> T {
        precondition(i >= 0 && i < count)
        return file.unchecked(offset + i * MemoryLayout<T>.size)
    }
}
