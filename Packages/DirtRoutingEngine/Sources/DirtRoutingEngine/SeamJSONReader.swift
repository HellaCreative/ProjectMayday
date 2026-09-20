import Foundation

/// The national sidecars can contain hundreds of thousands of proofs. Decode
/// each record separately so Foundation never constructs a whole-file JSON map.
/// The input descriptor is the same one used for artifact hash verification.
enum SeamJSONReader {
    struct Metadata: Sendable {
        let neighborIDs: Set<String>
        let roadNeighbors: Set<String>?
    }
    struct Result: Sendable {
        let document: SeamDocument
        let metadata: Metadata
    }

    static func read(_ file: BinaryFile, budget: ComputationBudget,
                     retaining neighbors: Set<String>? = nil,
                     metadataOnly: Bool = false, chunkBytes: Int = 65_536) throws -> Result {
        let cursor = Cursor(file: file, budget: budget, chunkBytes: chunkBytes)
        let decoder = JSONDecoder()
        var strings: [String: String] = [:]
        var roads: Set<String>?
        var found: [String: SeamDocument.Anchors] = [:]
        var fields: Set<String> = []
        try cursor.object { key in
            guard fields.insert(key).inserted else { throw invalid("duplicate field") }
            switch key {
            case "schemaVersion", "fabricReleaseId", "sourceEpoch", "regionId":
                strings[key] = try decoder.decode(String.self, from: cursor.value())
            case "roadNeighbors":
                roads = try decoder.decode([String]?.self, from: cursor.value()).map(Set.init)
            case "neighbors":
                try cursor.object { region in
                    guard found[region] == nil else { throw invalid("duplicate neighbor") }
                    let retain = !metadataOnly && (neighbors?.contains(region) ?? true)
                    var anchors = SeamDocument.Anchors()
                    try cursor.array {
                        try autoreleasepool {
                            let value = try cursor.value()
                            if retain {
                                anchors.append(try decoder.decode(SeamDocument.Anchor.self, from: value))
                            } else {
                                // Skipped records still require syntactically valid
                                // JSON. Temporary allocations are bounded to one row.
                                _ = try JSONSerialization.jsonObject(with: value, options: [.fragmentsAllowed])
                            }
                        }
                    }
                    found[region] = anchors
                }
            default:
                _ = try JSONSerialization.jsonObject(with: cursor.value(), options: [.fragmentsAllowed])
            }
        }
        guard try cursor.peekNonWhitespace() == nil else { throw invalid("trailing bytes") }
        guard let schema = strings["schemaVersion"], let release = strings["fabricReleaseId"],
              let epoch = strings["sourceEpoch"], let region = strings["regionId"],
              fields.contains("neighbors") else { throw invalid("missing metadata") }
        let ids = Set(found.keys)
        if let neighbors, !metadataOnly { found = found.filter { neighbors.contains($0.key) } }
        return .init(document: .init(schemaVersion: schema, fabricReleaseId: release,
            sourceEpoch: epoch, regionId: region, chunkedNeighbors: found),
            metadata: .init(neighborIDs: ids, roadNeighbors: roads))
    }

    private static func invalid(_ message: String) -> RoutingFailure {
        .invalidPack("seam JSON: \(message)")
    }

    private final class Cursor {
        let file: BinaryFile
        let budget: ComputationBudget
        let chunkBytes: Int
        var buffer: [UInt8] = []
        var position = 0
        var offset = 0
        init(file: BinaryFile, budget: ComputationBudget, chunkBytes: Int) {
            self.file = file; self.budget = budget
            self.chunkBytes = max(1, min(1_048_576, chunkBytes))
        }
        func peek() throws -> UInt8? {
            if position == buffer.count {
                try budget.check()
                offset += buffer.count
                buffer.removeAll(keepingCapacity: true)
                position = 0
                guard offset < file.data.count else { return nil }
                buffer = Array(try file.copiedBytes(at: offset, count: min(chunkBytes, file.data.count - offset)))
            }
            return buffer[position]
        }
        func take() throws -> UInt8 {
            guard let byte = try peek() else { throw invalid("unexpected end") }
            position += 1
            return byte
        }
        func peekNonWhitespace() throws -> UInt8? {
            while let byte = try peek() {
                if byte != 32 && byte != 9 && byte != 10 && byte != 13 { return byte }
                position += 1
            }
            return nil
        }
        func expect(_ byte: UInt8) throws {
            guard try peekNonWhitespace() == byte else { throw invalid("unexpected token") }
            position += 1
        }
        func object(_ field: (String) throws -> Void) throws {
            try expect(123)
            if try peekNonWhitespace() == 125 { position += 1; return }
            while true {
                guard try peekNonWhitespace() == 34 else { throw invalid("object key") }
                let key = try JSONDecoder().decode(String.self, from: value())
                try expect(58)
                try field(key)
                if try peekNonWhitespace() == 125 { position += 1; return }
                try expect(44)
                guard try peekNonWhitespace() != 125 else { throw invalid("trailing object comma") }
            }
        }
        func array(_ element: () throws -> Void) throws {
            try expect(91)
            if try peekNonWhitespace() == 93 { position += 1; return }
            while true {
                try element()
                if try peekNonWhitespace() == 93 { position += 1; return }
                try expect(44)
                guard try peekNonWhitespace() != 93 else { throw invalid("trailing array comma") }
            }
        }
        /// Isolate one value across arbitrary I/O boundaries. Its decoder then
        /// validates JSON grammar, escaping, Unicode and the expected field types.
        func value() throws -> Data {
            guard let first = try peekNonWhitespace() else { throw invalid("missing value") }
            var bytes: [UInt8] = []
            var closers: [UInt8] = []
            var quoted = false, escaped = false
            var lastSignificant: UInt8?
            let compound = first == 123 || first == 91
            let string = first == 34
            while let byte = try peek() {
                if !compound && !string && (byte == 44 || byte == 93 || byte == 125 || byte == 32 || byte == 9 || byte == 10 || byte == 13) { break }
                bytes.append(try take())
                guard bytes.count <= 16 * 1_048_576 else { throw invalid("record exceeds bounded reader") }
                if quoted {
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 {
                        quoted = false
                        lastSignificant = byte
                        if string && !compound { return Data(bytes) }
                    }
                    continue
                }
                if byte == 34 { quoted = true }
                else if byte == 123 || byte == 91 {
                    closers.append(byte == 123 ? 125 : 93)
                    guard closers.count <= 128 else { throw invalid("nesting exceeds bounded reader") }
                } else if byte == 125 || byte == 93 {
                    guard lastSignificant != 44 else { throw invalid("trailing nested comma") }
                    guard closers.popLast() == byte else { throw invalid("mismatched brackets") }
                    if closers.isEmpty { return Data(bytes) }
                }
                if byte != 32 && byte != 9 && byte != 10 && byte != 13 { lastSignificant = byte }
            }
            guard !bytes.isEmpty, !compound, !string, !quoted, closers.isEmpty else {
                throw invalid("unfinished value")
            }
            return Data(bytes)
        }
    }
}
