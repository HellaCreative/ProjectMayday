import Foundation
import Darwin
import CryptoKit

/// Bounded external preparation. All files created here are private scratch or
/// derived indexes; source packs are opened read-only and never rewritten.
nonisolated enum ExactSnapIndexBuilder {
    struct Limits {
        var maximumPairsInMemory = 65_536
        // Cumulative writes, including merge passes: stricter than a disk peak
        // cap. This intentionally rejects excessive preparation with a limit.
        var maximumWrittenBytes = 8 * 1024 * 1024 * 1024
    }
    struct Edge {
        let aLon: Double, aLat: Double, bLon: Double, bLat: Double
        let minLon: Double, maxLon: Double, minLat: Double, maxLat: Double
    }
    private struct Pair: Comparable {
        let key: UInt64
        let edge: UInt32
        static func < (a: Self, b: Self) -> Bool { a.key == b.key ? a.edge < b.edge : a.key < b.key }
    }
    private final class Writer {
        let limit: Int
        var written = 0
        init(_ limit: Int) { self.limit = limit }
        func write(_ bytes: Data, to handle: FileHandle) throws {
            guard bytes.count <= limit-written else { throw ExactSnapIndex.Failure.preparationLimit }
            try handle.write(contentsOf: bytes); written += bytes.count
        }
    }
    private final class Cursor {
        let handle: FileHandle
        var bytes = Data()
        var at = 0
        var current: Pair?
        init(_ url: URL) throws { handle = try FileHandle(forReadingFrom: url); try advance() }
        deinit { try? handle.close() }
        func advance() throws {
            if at == bytes.count {
                bytes = Data(); at = 0
                while bytes.count < 65_532 {
                    let next = try handle.read(upToCount: 65_532-bytes.count) ?? Data()
                    if next.isEmpty { break }; bytes.append(next)
                }
                guard bytes.count % 12 == 0 else { throw ExactSnapIndex.Failure.corrupt }
                if bytes.isEmpty { current = nil; return }
            }
            current = bytes.withUnsafeBytes { raw in Pair(key: raw.loadUnaligned(fromByteOffset: at, as: UInt64.self).littleEndian,
                edge: UInt32.routingDecode(raw, at: at+8)) }
            at += 12
        }
    }
    private static func output(_ url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ExactSnapIndex.Failure.preparationLimit }
        return try FileHandle(forWritingTo: url)
    }
    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var le = value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    private static func pairBytes(_ pair: Pair, into data: inout Data) { append(pair.key, to: &data); append(pair.edge, to: &data) }

    /// Edge provider is invoked exactly once in edge-ID order. nil reproduces
    /// the prior invalid-endpoint skip, including its absent bounds record.
    static func build(to destination: URL, identity: ExactSnapIndex.Identity, edgeCount: Int,
        limits: Limits = Limits(), cancelled: () -> Bool = { false },
        beforePublish: () throws -> Void = {},
        edge: (Int) throws -> Edge?) throws {
        guard edgeCount >= 0, edgeCount <= Int(UInt32.max), limits.maximumPairsInMemory > 0,
              limits.maximumPairsInMemory <= 1_048_576, limits.maximumWrittenBytes > 0 else { throw ExactSnapIndex.Failure.preparationLimit }
        let fm = FileManager.default
        let scratch = destination.deletingLastPathComponent().appendingPathComponent(".snap-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let writer = Writer(limits.maximumWrittenBytes)
        let boundsURL = scratch.appendingPathComponent("bounds"), directoryURL = scratch.appendingPathComponent("directory")
        let membershipsURL = scratch.appendingPathComponent("memberships")
        let bounds = try output(boundsURL); defer { try? bounds.close() }
        var pairs: [Pair] = []; pairs.reserveCapacity(limits.maximumPairsInMemory)
        var runCount = 0
        func runURL(_ pass: Int, _ run: Int) -> URL { scratch.appendingPathComponent("run-\(pass)-\(run)") }
        func flush() throws {
            if pairs.isEmpty { return }
            guard !cancelled() else { throw ExactSnapIndex.Failure.cancelled }
            pairs.sort()
            let handle = try output(runURL(0, runCount)); defer { try? handle.close() }
            var block = Data(); block.reserveCapacity(65_532)
            for pair in pairs {
                pairBytes(pair, into: &block)
                if block.count >= 65_532 { try writer.write(block, to: handle); block.removeAll(keepingCapacity: true) }
            }
            try writer.write(block, to: handle); pairs.removeAll(keepingCapacity: true); runCount += 1
        }
        let measurement = RoutingWorkContext.measurement
        var preparationPhase = measurement?.begin(.indexSourceScan)
        defer { measurement?.end(preparationPhase) }
        var boundsBlock = Data(); boundsBlock.reserveCapacity(65_520)
        var scanChecks = 0,scanMemberships = 0
        defer { measurement?.increment(.indexScanCancellationChecks,by: UInt64(scanChecks)) }
        for id in 0..<edgeCount {
            if id&255 == 0 {
                scanChecks += 1
                guard !cancelled() else { throw ExactSnapIndex.Failure.cancelled }
            }
            if let row = try edge(id) {
                guard row.aLon.isFinite,row.aLat.isFinite,row.bLon.isFinite,row.bLat.isFinite,
                      row.minLon.isFinite,row.maxLon.isFinite,row.minLat.isFinite,row.maxLat.isFinite,
                      row.minLon <= row.maxLon,row.minLat <= row.maxLat else { throw ExactSnapIndex.Failure.invalidFormat }
                append(UInt64(1), to: &boundsBlock)
                append(row.minLon.bitPattern,to: &boundsBlock);append(row.maxLon.bitPattern,to: &boundsBlock)
                append(row.minLat.bitPattern,to: &boundsBlock);append(row.maxLat.bitPattern,to: &boundsBlock)
                let x0 = try ExactSnapIndex.cell(min(row.aLon,row.bLon)), x1 = try ExactSnapIndex.cell(max(row.aLon,row.bLon))
                let y0 = try ExactSnapIndex.cell(min(row.aLat,row.bLat)), y1 = try ExactSnapIndex.cell(max(row.aLat,row.bLat))
                // A pathological edge must hit the explicit work/disk budget,
                // not overflow a count or allocate its entire cell rectangle.
                for x in x0...x1 { for y in y0...y1 {
                    if scanMemberships&255 == 0 {
                        scanChecks += 1
                        if cancelled() { throw ExactSnapIndex.Failure.cancelled }
                    }
                    scanMemberships += 1
                    pairs.append(Pair(key: ExactSnapIndex.key(x,y), edge: UInt32(id)))
                    if pairs.count == limits.maximumPairsInMemory { try flush() }
                } }
            } else { boundsBlock.append(Data(count: 40)) }
            if boundsBlock.count >= 65_520 { try writer.write(boundsBlock, to: bounds); boundsBlock.removeAll(keepingCapacity: true) }
        }
        try writer.write(boundsBlock, to: bounds); try bounds.close(); try flush()
        measurement?.end(preparationPhase)
        preparationPhase = measurement?.begin(.indexMerge)
        // Binary merge passes keep just two input blocks and one output block;
        // filenames are derived from counters, not retained in a region list.
        var pass = 0
        while runCount > 1 {
            var nextCount = 0
            for first in stride(from: 0, to: runCount, by: 2) {
                guard !cancelled() else { throw ExactSnapIndex.Failure.cancelled }
                let aURL = runURL(pass,first), target = runURL(pass+1,nextCount)
                if first+1 == runCount { try fm.moveItem(at: aURL, to: target) }
                else {
                    let bURL = runURL(pass,first+1)
                    do {
                        let a = try Cursor(aURL), b = try Cursor(bURL), handle = try output(target)
                        defer { try? handle.close() }
                        var block = Data(); block.reserveCapacity(65_532)
                        while a.current != nil || b.current != nil {
                            guard !cancelled() else { throw ExactSnapIndex.Failure.cancelled }
                            if let row = a.current, b.current == nil || row < b.current! { pairBytes(row, into: &block); try a.advance() }
                            else if let row = b.current { pairBytes(row, into: &block); try b.advance() }
                            if block.count >= 65_532 { try writer.write(block, to: handle); block.removeAll(keepingCapacity: true) }
                        }
                        try writer.write(block, to: handle)
                    }
                    try fm.removeItem(at: aURL); try fm.removeItem(at: bURL)
                }
                nextCount += 1
            }
            pass += 1; runCount = nextCount
        }
        let directory = try output(directoryURL), memberships = try output(membershipsURL)
        defer { try? directory.close(); try? memberships.close() }
        var cellCount = 0, membershipCount = 0, currentKey: UInt64?, start = 0
        var edgeBlock = Data(); edgeBlock.reserveCapacity(65_536)
        func finishCell() throws {
            guard let key = currentKey else { return }
            var row = Data(); append(key, to: &row); append(UInt64(start), to: &row); append(UInt64(membershipCount-start), to: &row)
            try writer.write(row, to: directory); cellCount += 1
        }
        if runCount == 1 {
            let cursor = try Cursor(runURL(pass,0))
            while let pair = cursor.current {
                guard !cancelled() else { throw ExactSnapIndex.Failure.cancelled }
                if pair.key != currentKey { try finishCell(); currentKey = pair.key; start = membershipCount }
                append(pair.edge, to: &edgeBlock); membershipCount += 1
                if edgeBlock.count >= 65_536 { try writer.write(edgeBlock, to: memberships); edgeBlock.removeAll(keepingCapacity: true) }
                try cursor.advance()
            }
        }
        try finishCell(); try writer.write(edgeBlock, to: memberships); try directory.close(); try memberships.close()
        measurement?.end(preparationPhase)
        preparationPhase = measurement?.begin(.indexPublication)
        let candidate = scratch.appendingPathComponent("complete")
        let final = try output(candidate); defer { try? final.close() }
        try writer.write(Data(count: ExactSnapIndex.headerBytes), to: final)
        for url in [boundsURL,directoryURL,membershipsURL] {
            let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
            while true {
                guard !cancelled() else { throw ExactSnapIndex.Failure.cancelled }
                let block = try input.read(upToCount: 65_536) ?? Data()
                if block.isEmpty { break }; try writer.write(block, to: final)
            }
        }
        try final.synchronize(); try final.close()
        let pages = try RoutingFilePages(url: candidate, limits: ExactSnapIndex.pageLimits)
        let hash = try ExactSnapIndex.digest(pages, offset: ExactSnapIndex.headerBytes, cancelled: cancelled); pages.close()
        let header = ExactSnapIndex.Header(identity: identity, semantics: ExactSnapIndex.semantics,
            edgeCount: edgeCount, cellCount: cellCount, membershipCount: membershipCount, bodySHA256: hash)
        let json = try JSONEncoder().encode(header)
        guard json.count <= ExactSnapIndex.headerBytes-72 else { throw ExactSnapIndex.Failure.invalidFormat }
        var prefix = Data([68,83,73,49]); append(UInt32(json.count), to: &prefix)
        RoutingWorkContext.measurement?.increment(.fileBytesHashed,by: UInt64(json.count))
        prefix.append(Data(SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined().utf8)); prefix.append(json)
        prefix.append(Data(count: ExactSnapIndex.headerBytes-prefix.count))
        let update = try FileHandle(forWritingTo: candidate); defer { try? update.close() }
        try writer.write(prefix, to: update); try update.synchronize(); try update.close()
        guard !cancelled() else { throw ExactSnapIndex.Failure.cancelled }
        try beforePublish()
        guard !cancelled() else { throw ExactSnapIndex.Failure.cancelled }
        // rename(2) atomically publishes a complete derived file on this volume.
        let result = candidate.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst in rename(src!,dst!) }
        }
        guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
