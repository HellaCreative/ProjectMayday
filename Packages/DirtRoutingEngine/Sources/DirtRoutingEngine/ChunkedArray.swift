/// Append-only search storage. Growing one small chunk never copies the whole
/// search history or temporarily holds two province-sized label allocations.
/// Integer indices remain stable for heap entries and parent reconstruction.
struct ChunkedArray<Element> {
    private static var shift: Int { 12 }
    private static var size: Int { 1 << shift }
    private var chunks: [[Element]] = []
    private(set) var count = 0

    init() {}

    static func payloadBytes(forCount count: Int) -> Int {
        guard count > 0 else { return 0 }
        let capacity = ((count - 1) / Self.size + 1) * Self.size
        return capacity * MemoryLayout<Element>.stride
    }

    mutating func append(_ element: Element) {
        if count & (Self.size - 1) == 0 {
            var chunk: [Element] = []
            chunk.reserveCapacity(Self.size)
            chunks.append(chunk)
        }
        chunks[count >> Self.shift].append(element)
        count += 1
    }

    subscript(_ index: Int) -> Element {
        precondition(index >= 0 && index < count)
        return chunks[index >> Self.shift][index & (Self.size - 1)]
    }
}
