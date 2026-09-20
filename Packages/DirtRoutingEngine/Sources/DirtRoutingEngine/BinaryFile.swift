import Foundation
import CryptoKit
import Darwin

/// Retains mapped bytes, not a decoded copy of each regional graph array.
final class BinaryFile: @unchecked Sendable {
    let data: Data
    private let source: FileHandle?
    private let digestLock = NSLock()
    private var cachedDigest: Data?
    init(url: URL) throws {
        guard url.isFileURL else { throw RoutingFailure.invalidPack("local file required") }
        // Mapping and verification share one descriptor, even if a download later
        // atomically replaces the pathname. Hashing must not fault every shape
        // page into this process before those roads are needed.
        let handle = try FileHandle(forReadingFrom: url)
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, UInt64(info.st_size) <= UInt64(Int.max) else {
            throw RoutingFailure.invalidPack("cannot inspect mapped file")
        }
        let size = Int(info.st_size)
        if size == 0 {
            data = Data()
        } else {
            let address = mmap(nil, size, PROT_READ, MAP_PRIVATE, handle.fileDescriptor, 0)
            guard let address, address != MAP_FAILED else {
                throw RoutingFailure.invalidPack("cannot map local file")
            }
            data = Data(bytesNoCopy: address, count: size,
                        deallocator: .custom { pointer, count in _ = munmap(pointer, count) })
        }
        source = handle
    }
    init(data: Data) { self.data = data; source = nil }
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
    /// Verify all bytes without making unused mapped geometry resident. Keep
    /// the successful receipt only; an interrupted/truncated read is an error.
    func sha256Digest() throws -> Data {
        digestLock.lock()
        defer { digestLock.unlock() }
        if let cachedDigest { return cachedDigest }
        var hasher = SHA256()
        if let source {
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            var offset = 0
            while offset < data.count {
                let count = min(buffer.count, data.count - offset)
                let readCount = buffer.withUnsafeMutableBytes {
                    pread(source.fileDescriptor, $0.baseAddress, count, off_t(offset))
                }
                if readCount < 0 && errno == EINTR { continue }
                guard readCount > 0 else {
                    throw RoutingFailure.invalidPack("cannot read complete mapped file for verification")
                }
                buffer.withUnsafeBytes {
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<readCount]))
                }
                offset += readCount
            }
            var info = stat()
            guard fstat(source.fileDescriptor, &info) == 0, info.st_size == data.count else {
                throw RoutingFailure.invalidPack("mapped file size changed during verification")
            }
        } else {
            hasher.update(data: data)
        }
        let digest = Data(hasher.finalize())
        cachedDigest = digest
        return digest
    }
    var sha256: String {
        get throws {
            // Digest owns synchronization. Deriving the tiny hex representation
            // avoids reading a mutable cache outside its lock.
            try sha256Digest().map { String(format: "%02x", $0) }.joined()
        }
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
