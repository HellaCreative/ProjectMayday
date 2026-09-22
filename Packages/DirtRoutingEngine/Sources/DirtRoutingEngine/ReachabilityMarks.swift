/// Exact one-bit membership for regional connectivity proofs. Marks are cached
/// across seam candidates, so byte-per-Bool arrays otherwise retain millions of
/// redundant bytes while the turn-aware search allocates its label history.
struct ReachabilityMarks {
    private var words: [UInt64]
    let count: Int
    init(count: Int) {
        precondition(count >= 0)
        self.count = count
        words = Array(repeating: 0, count: count / 64 + (count % 64 == 0 ? 0 : 1))
    }
    var storageBytes: Int { words.count * MemoryLayout<UInt64>.stride }
    subscript(index: Int) -> Bool {
        get {
            precondition(index >= 0 && index < count)
            return words[index >> 6] & (UInt64(1) << (index & 63)) != 0
        }
        set {
            precondition(index >= 0 && index < count)
            let bit = UInt64(1) << (index & 63)
            if newValue { words[index >> 6] |= bit }
            else { words[index >> 6] &= ~bit }
        }
    }
}
