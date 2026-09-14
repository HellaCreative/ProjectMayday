import Foundation

nonisolated protocol RoutingLittleEndianScalar: Sendable {
    nonisolated static var routingByteWidth: Int { get }
    nonisolated static func routingDecode(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> Self
}

extension UInt8: RoutingLittleEndianScalar {
    nonisolated static var routingByteWidth: Int { 1 }
    nonisolated static func routingDecode(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt8 { bytes[offset] }
}
extension Int8: RoutingLittleEndianScalar {
    nonisolated static var routingByteWidth: Int { 1 }
    nonisolated static func routingDecode(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> Int8 { Int8(bitPattern: bytes[offset]) }
}
extension UInt16: RoutingLittleEndianScalar {
    nonisolated static var routingByteWidth: Int { 2 }
    nonisolated static func routingDecode(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt16 {
        bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
    }
}
extension Int32: RoutingLittleEndianScalar {
    nonisolated static var routingByteWidth: Int { 4 }
    nonisolated static func routingDecode(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> Int32 {
        bytes.loadUnaligned(fromByteOffset: offset, as: Int32.self).littleEndian
    }
}
extension UInt32: RoutingLittleEndianScalar {
    nonisolated static var routingByteWidth: Int { 4 }
    nonisolated static func routingDecode(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
        bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
    }
}
extension UInt64: RoutingLittleEndianScalar {
    nonisolated static var routingByteWidth: Int { 8 }
    nonisolated static func routingDecode(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt64 {
        bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
    }
}
extension Int64: RoutingLittleEndianScalar {
    nonisolated static var routingByteWidth: Int { 8 }
    nonisolated static func routingDecode(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> Int64 {
        bytes.loadUnaligned(fromByteOffset: offset, as: Int64.self).littleEndian
    }
}
extension Float: RoutingLittleEndianScalar {
    nonisolated static var routingByteWidth: Int { 4 }
    nonisolated static func routingDecode(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> Float {
        Float(bitPattern: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian)
    }
}
extension Double: RoutingLittleEndianScalar {
    nonisolated static var routingByteWidth: Int { 8 }
    nonisolated static func routingDecode(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> Double {
        Double(bitPattern: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian)
    }
}

/// Fully resident, validated owned range: collection reads cannot fail due to
/// I/O or cancellation. File-backed callers obtain a bounded lease first.
nonisolated struct RoutingByteColumn<Element: RoutingLittleEndianScalar>: RandomAccessCollection, Sendable {
    typealias Index = Int
    private let owner: RoutingByteLease
    private let byteOffset: Int
    let startIndex: Int
    let endIndex: Int

    init(owner: RoutingByteLease, byteOffset: Int = 0, count: Int, startIndex: Int = 0) throws {
        guard Element.routingByteWidth > 0, byteOffset >= 0, count >= 0, startIndex >= 0,
              byteOffset <= owner.count,
              count <= (owner.count - byteOffset) / Element.routingByteWidth,
              count <= Int.max - startIndex else { throw RoutingPageError.invalidRange }
        self.owner = owner; self.byteOffset = byteOffset
        self.startIndex = startIndex; endIndex = startIndex + count
    }

    init(data: Data, byteOffset: Int = 0, count: Int) throws {
        try self.init(owner: RoutingByteLease(data: data), byteOffset: byteOffset, count: count)
    }

    subscript(index: Int) -> Element {
        precondition(index >= startIndex && index < endIndex, "Invalid routing column index")
        return owner.withUnsafeBytes { raw in
            Element.routingDecode(raw, at: byteOffset + (index - startIndex) * Element.routingByteWidth)
        }
    }
}

/// Typed disk column. Fallible access is explicit; no nonthrowing collection
/// subscript is allowed to substitute zero after an I/O failure.
nonisolated struct RoutingPagedColumn<Element: RoutingLittleEndianScalar>: Sendable {
    private let source: RoutingFilePages
    private let byteOffset: Int
    let count: Int

    init(source: RoutingFilePages, byteOffset: Int, count: Int) throws {
        guard Element.routingByteWidth > 0, byteOffset >= 0, count >= 0, byteOffset <= source.fileBytes,
              count <= (source.fileBytes - byteOffset) / Element.routingByteWidth else {
            throw RoutingPageError.invalidRange
        }
        self.source = source; self.byteOffset = byteOffset; self.count = count
    }

    func value(at index: Int, cancelled: () -> Bool = { false }) throws -> Element {
        guard index >= 0, index < count else { throw RoutingPageError.invalidRange }
        return try lease(index..<(index + 1), cancelled: cancelled)[index]
    }

    /// Returned indices retain their original column positions.
    func lease(_ range: Range<Int>, cancelled: () -> Bool = { false }) throws -> RoutingByteColumn<Element> {
        guard range.lowerBound >= 0, range.upperBound <= count else { throw RoutingPageError.invalidRange }
        let owner = try source.read(at: byteOffset + range.lowerBound * Element.routingByteWidth,
            count: range.count * Element.routingByteWidth, cancelled: cancelled)
        return try RoutingByteColumn(owner: owner, count: range.count, startIndex: range.lowerBound)
    }
}
