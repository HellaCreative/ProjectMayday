import Foundation
import CryptoKit
import Darwin

/// Keep the actual load concrete even in Xcode's per-file compilation mode.
/// A generic loadUnaligned otherwise performs runtime type-metadata work for
/// every column access. All graph integers use the same little-endian contract.
@usableFromInline protocol PackedInteger: FixedWidthInteger {
    static func loadLittleEndian(_ pointer: UnsafeRawPointer) -> Self
}
extension UInt8: PackedInteger {
    @usableFromInline static func loadLittleEndian(_ p: UnsafeRawPointer) -> UInt8 { p.loadUnaligned(as: UInt8.self) }
}
extension Int8: PackedInteger {
    @usableFromInline static func loadLittleEndian(_ p: UnsafeRawPointer) -> Int8 { p.loadUnaligned(as: Int8.self) }
}
extension UInt16: PackedInteger {
    @usableFromInline static func loadLittleEndian(_ p: UnsafeRawPointer) -> UInt16 { UInt16(littleEndian: p.loadUnaligned(as: UInt16.self)) }
}
extension Int16: PackedInteger {
    @usableFromInline static func loadLittleEndian(_ p: UnsafeRawPointer) -> Int16 { Int16(littleEndian: p.loadUnaligned(as: Int16.self)) }
}
extension UInt32: PackedInteger {
    @usableFromInline static func loadLittleEndian(_ p: UnsafeRawPointer) -> UInt32 { UInt32(littleEndian: p.loadUnaligned(as: UInt32.self)) }
}
extension Int32: PackedInteger {
    @usableFromInline static func loadLittleEndian(_ p: UnsafeRawPointer) -> Int32 { Int32(littleEndian: p.loadUnaligned(as: Int32.self)) }
}
extension UInt64: PackedInteger {
    @usableFromInline static func loadLittleEndian(_ p: UnsafeRawPointer) -> UInt64 { UInt64(littleEndian: p.loadUnaligned(as: UInt64.self)) }
}
extension Int64: PackedInteger {
    @usableFromInline static func loadLittleEndian(_ p: UnsafeRawPointer) -> Int64 { Int64(littleEndian: p.loadUnaligned(as: Int64.self)) }
}

/// Retains mapped bytes, not a decoded copy of each regional graph array.
@usableFromInline final class BinaryFile: @unchecked Sendable {
    @usableFromInline let data: Data
    /// Original mmap address; `data` owns its lifetime. Never escape a temporary
    /// Data.withUnsafeBytes pointer for the in-memory fixture initializer.
    @usableFromInline let mappedBaseAddress: UnsafeRawPointer?
    private final class Mapping {
        let address: UnsafeMutableRawPointer
        let count: Int
        init(address: UnsafeMutableRawPointer, count: Int) { self.address = address; self.count = count }
        deinit { _ = munmap(address, count) }
    }
    private let mapping: Mapping?
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
            mappedBaseAddress = nil
            mapping = nil
        } else {
            let address = mmap(nil, size, PROT_READ, MAP_PRIVATE, handle.fileDescriptor, 0)
            guard let address, address != MAP_FAILED else {
                throw RoutingFailure.invalidPack("cannot map local file")
            }
            let owner = Mapping(address: address, count: size)
            mapping = owner
            // Data may copy short inputs into inline storage and immediately
            // invoke its deallocator. Retain the mapping independently for
            // direct reads; exported large Data also retains it via this closure.
            data = Data(bytesNoCopy: address, count: size,
                        deallocator: .custom { [owner] _, _ in withExtendedLifetime(owner) {} })
            mappedBaseAddress = UnsafeRawPointer(address)
        }
        source = handle
    }
    init(data: Data) { self.data = data; source = nil; mappedBaseAddress = nil; mapping = nil }
    /// Serial, bounded reads for exhaustive validation. Unlike mapped column
    /// reads, these do not make every visited geometry page process-resident.
    /// Keep one reader per file for the duration of a join, never a global cache.
    final class BufferedReader {
        private let file: BinaryFile
        private let blockSize: Int
        private var start = -1
        private var bytes = Data()
        var bufferedByteCount: Int { bytes.count }

        init(_ file: BinaryFile, blockSize: Int = 65_536) {
            precondition(blockSize >= 8)
            self.file = file; self.blockSize = blockSize
        }

        func read<T: PackedInteger>(_ offset: Int, as: T.Type) throws -> T {
            let width = MemoryLayout<T>.size
            try file.range(offset, width)
            if start < 0 || offset < start || offset - start > bytes.count - width {
                let nextStart = (offset / blockSize) * blockSize
                // An unaligned scalar may straddle the nominal block boundary.
                bytes = try file.copiedBytes(at: nextStart, count: min(blockSize + 7, file.data.count - nextStart))
                start = nextStart
            }
            return bytes.withUnsafeBytes { T.loadLittleEndian($0.baseAddress!.advanced(by: offset - start)) }
        }
    }
    /// Read a bounded slice from the descriptor that was verified, without
    /// faulting the whole mapped JSON artifact into resident memory.
    func copiedBytes(at offset: Int, count: Int) throws -> Data {
        try range(offset, count)
        guard let source else { return data.subdata(in: offset..<(offset + count)) }
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { bytes in
            var copied = 0
            while copied < count {
                let n = pread(source.fileDescriptor, bytes.baseAddress!.advanced(by: copied),
                              count - copied, off_t(offset + copied))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw RoutingFailure.invalidPack("incomplete streamed artifact") }
                copied += n
            }
        }
        return result
    }
    func range(_ offset: Int, _ count: Int, stride: Int = 1) throws {
        guard offset >= 0, count >= 0, stride > 0, offset <= data.count,
              count <= (data.count - offset) / stride else {
            throw RoutingFailure.invalidPack("section outside file")
        }
    }
    func read<T: PackedInteger>(_ offset: Int, as: T.Type = T.self) throws -> T {
        try range(offset, 1, stride: MemoryLayout<T>.size)
        return unchecked(offset, as: T.self)
    }
    @inlinable func unchecked<T: PackedInteger>(_ offset: Int, as: T.Type = T.self) -> T {
        if let mappedBaseAddress { return T.loadLittleEndian(mappedBaseAddress.advanced(by: offset)) }
        return data.withUnsafeBytes { T.loadLittleEndian($0.baseAddress!.advanced(by: offset)) }
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

struct MappedColumn<T: PackedInteger>: Sendable {
    @usableFromInline let file: BinaryFile
    @usableFromInline let offset: Int
    @usableFromInline let count: Int
    init(file: BinaryFile, offset: Int, count: Int) throws {
        try file.range(offset, count, stride: MemoryLayout<T>.size)
        self.file = file; self.offset = offset; self.count = count
    }
    @inlinable subscript(_ i: Int) -> T {
        precondition(i >= 0 && i < count)
        return file.unchecked(offset + i * MemoryLayout<T>.size)
    }
}
