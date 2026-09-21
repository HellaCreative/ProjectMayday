/// Exact adjacency indices using three bytes when possible. The all-ones value
/// represents the existing -1 sentinel. Larger or other signed values promote
/// the column to Int32 storage; no index is truncated or made unreachable.
struct CompactArcColumn: Sendable, Equatable {
    static let maximumCompactValue: Int32 = 0xFFFFFE
    private var low: [UInt16] = []
    private var high: [UInt8] = []
    private var wide: [Int32] = []
    private var usesWide = false

    init() {}

    init(repeating value: Int32, count: Int, maximumValue: Int32) {
        usesWide = maximumValue > Self.maximumCompactValue || !Self.fits(value)
        if usesWide {
            wide = .init(repeating: value, count: count)
        } else {
            let bits = UInt32(bitPattern: value)
            low = .init(repeating: UInt16(truncatingIfNeeded: bits), count: count)
            high = .init(repeating: UInt8(truncatingIfNeeded: bits >> 16), count: count)
        }
    }

    var count: Int { usesWide ? wide.count : low.count }
    var indices: Range<Int> { 0..<count }
    var ownedBytes: Int { usesWide ? wide.count * 4 : low.count * 3 }

    @inline(__always) private static func fits(_ value: Int32) -> Bool {
        value >= -1 && value <= maximumCompactValue
    }

    @inline(__always) subscript(_ index: Int) -> Int32 {
        get {
            if usesWide { return wide[index] }
            let bits = UInt32(low[index]) | UInt32(high[index]) << 16
            return bits == 0xFFFFFF ? -1 : Int32(bits)
        }
        set {
            if !usesWide && !Self.fits(newValue) { promote() }
            if usesWide { wide[index] = newValue }
            else {
                let bits = UInt32(bitPattern: newValue)
                low[index] = UInt16(truncatingIfNeeded: bits)
                high[index] = UInt8(truncatingIfNeeded: bits >> 16)
            }
        }
    }

    mutating func reserveCapacity(_ count: Int) {
        if usesWide { wide.reserveCapacity(count) }
        else { low.reserveCapacity(count); high.reserveCapacity(count) }
    }

    mutating func append(_ value: Int32) {
        if !usesWide && !Self.fits(value) { promote() }
        if usesWide { wide.append(value) }
        else {
            let bits = UInt32(bitPattern: value)
            low.append(UInt16(truncatingIfNeeded: bits))
            high.append(UInt8(truncatingIfNeeded: bits >> 16))
        }
    }

    private mutating func promote() {
        wide.reserveCapacity(low.capacity)
        for i in low.indices { wide.append(self[i]) }
        low = []; high = []; usesWide = true
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.count == rhs.count && lhs.indices.allSatisfy { lhs[$0] == rhs[$0] }
    }
}
