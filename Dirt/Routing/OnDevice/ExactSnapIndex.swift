import Foundation
import CryptoKit

/// Private derivative of unchanged graph/geometry bytes. This index only
/// selects snap candidates; it grants no access and creates no connections.
nonisolated final class ExactSnapIndex: @unchecked Sendable {
    enum Failure: Error, Equatable { case invalidFormat, identityMismatch, corrupt, preparationLimit, cancelled }
    struct Identity: Codable, Equatable, Sendable {
        let graphSHA256: String
        let graphBytes: Int
        let geometrySHA256: String
        let geometryBytes: Int
    }
    struct Header: Codable {
        let identity: Identity
        let semantics: String
        let edgeCount: Int
        let cellCount: Int
        let membershipCount: Int
        let bodySHA256: String
    }
    // Membership intentionally uses endpoint boxes, exactly like the current
    // native grid. Bounds use endpoints plus every original geometry point.
    static let semantics = "endpoint-grid-0.05-f64-bounds-ring-order.v1"
    static let headerBytes = 4096
    static let cellDegrees = 0.05
    static let pageLimits = RoutingFilePages.Limits(pageBytes: 65_536,
        maximumCachedBytes: 1_048_576, maximumReadBytes: 65_536,
        maximumLivePayloadBytes: 1_179_648, maximumLeases: 8)
    private let source: RoutingFilePages
    private let header: Header
    private let geometryEnvelope: GeometryEnvelope?
    private let directoryAt: Int
    private let edgesAt: Int
    var statistics: RoutingFilePages.Statistics { source.statistics }

    /// Cheap file identity validation before reusing an already verified reader.
    /// Cancellation belongs to each query and does not invalidate shared data.
    var isReusable: Bool {
        do { try source.validate(); return true }
        catch { return false }
    }

    init(url: URL, identity: Identity, cancelled: () -> Bool = { false }) throws {
        let source = try RoutingFilePages(url: url, limits: Self.pageLimits)
        guard source.fileBytes >= Self.headerBytes else { throw Failure.invalidFormat }
        let block = try source.read(at: 0, count: Self.headerBytes, cancelled: cancelled)
        let decoded: Header = try block.withUnsafeBytes { raw in
            guard raw[0] == 68, raw[1] == 83, raw[2] == 73, raw[3] == 49 else { throw Failure.invalidFormat }
            let count = Int(UInt32.routingDecode(raw, at: 4))
            guard count > 0, count <= Self.headerBytes - 72 else { throw Failure.invalidFormat }
            let json = Data(raw[72..<(72 + count)])
            let expected = String(decoding: raw[8..<72], as: UTF8.self)
            RoutingWorkContext.measurement?.increment(.fileBytesHashed,by: UInt64(json.count))
            let actual = SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
            guard expected == actual else { throw Failure.corrupt }
            do { return try JSONDecoder().decode(Header.self, from: json) }
            catch { throw Failure.invalidFormat }
        }
        guard decoded.identity == identity, decoded.semantics == Self.semantics else { throw Failure.identityMismatch }
        guard decoded.edgeCount >= 0, decoded.cellCount >= 0, decoded.membershipCount >= 0,
              decoded.edgeCount <= (source.fileBytes - Self.headerBytes) / 40 else { throw Failure.corrupt }
        directoryAt = Self.headerBytes + decoded.edgeCount * 40
        guard decoded.cellCount <= (source.fileBytes - directoryAt) / 24 else { throw Failure.corrupt }
        edgesAt = directoryAt + decoded.cellCount * 24
        guard decoded.membershipCount <= (source.fileBytes - edgesAt) / 4,
              edgesAt + decoded.membershipCount * 4 == source.fileBytes else { throw Failure.corrupt }
        let verified = try Self.validateBodyAndEnvelope(source, edgeCount: decoded.edgeCount, cancelled: cancelled)
        guard verified.digest == decoded.bodySHA256 else { throw Failure.corrupt }
        self.source = source; header = decoded; geometryEnvelope = verified.envelope
    }

    /// Private derivative membership includes every known graph endpoint cell.
    /// Unknown rows disable consumers that need complete incident coverage.
    func hasCompleteEndpointCoverage(query: BoundsQuery) throws -> Bool {
        try query.validateOwner(self)
        return header.edgeCount == 0 || geometryEnvelope != nil
    }

    /// Visits in the exact prior x/y/ring/bucket ordering. No complete bucket
    /// array is allocated, even for a dense cell. Callback errors propagate.
    func forEachEdge(nearLat lat: Double, lon: Double, radiusCells: Int,
        query: BoundsQuery? = nil, cancelled: () -> Bool = { false }, _ visit: (Int) throws -> Void) throws {
        try query?.validateOwner(self)
        let cx = try Self.cell(lon), cy = try Self.cell(lat), r = max(0, radiusCells)
        guard r < Int(Int32.max), cx >= Int(Int32.min) + r, cx <= Int(Int32.max) - r,
              cy >= Int(Int32.min) + r, cy <= Int(Int32.max) - r else { throw Failure.invalidFormat }
        for x in (cx-r)...(cx+r) {
            for y in (cy-r)...(cy+r) {
                if r > 0, x > cx-r, x < cx+r, y > cy-r, y < cy+r { continue }
                guard !cancelled() else { throw Failure.cancelled }
                guard let entry = try directory(key: Self.key(x, y), query: query, cancelled: cancelled) else { continue }
                var offset = entry.start
                while offset < entry.start + entry.count {
                    let count = min(16_384, entry.start + entry.count - offset)
                    let lease = try source.read(at: edgesAt + offset * 4, count: count * 4, cancelled: cancelled)
                    try lease.withUnsafeBytes { raw in
                        for i in 0..<count {
                            if i & 255 == 0, cancelled() { throw Failure.cancelled }
                            let edge = Int(UInt32.routingDecode(raw, at: i * 4))
                            guard edge < header.edgeCount else { throw Failure.corrupt }
                            try visit(edge)
                        }
                    }
                    offset += count
                }
            }
        }
    }

    func mayIntersect(edge: Int, latitude: Double, longitude: Double, meters: Double,
        query: BoundsQuery? = nil, cancelled: () -> Bool = { false }) throws -> Bool {
        if let query {
            try query.validateOwner(self)
            guard !cancelled() else { throw Failure.cancelled }
            return try query.mayIntersect(edge: edge, latitude: latitude, longitude: longitude, meters: meters)
        }
        guard edge >= 0, edge < header.edgeCount else { return true }
        let lease = try source.read(at: Self.headerBytes + edge * 40, count: 40, cancelled: cancelled)
        return try lease.withUnsafeBytes { raw in
            try Self.intersects(raw, offset: 0, latitude: latitude, longitude: longitude, meters: meters)
        }
    }

    private struct GeometryEnvelope {
        var minLon: Double, maxLon: Double, minLat: Double, maxLat: Double
        func mayIntersect(latitude: Double, longitude: Double, meters: Double) -> Bool {
            let latPad = max(0, meters) / 110_000
            if maxLat < latitude - latPad || minLat > latitude + latPad { return false }
            let polarLatitude = min(90, abs(latitude) + latPad)
            let lonPad = latPad / max(0.000001, cos(polarLatitude * .pi / 180))
            if lonPad >= 180 || abs(longitude) + lonPad >= 180 || maxLon-minLon >= 180 { return true }
            return maxLon >= longitude-lonPad && minLon <= longitude+lonPad
        }
    }
    private static func envelope(_ raw: UnsafeRawBufferPointer, offset: Int) throws -> GeometryEnvelope? {
        guard raw[offset] <= 1 else { throw Failure.corrupt }
        guard raw[offset] != 0 else { return nil }
        let result = GeometryEnvelope(minLon: Double.routingDecode(raw, at: offset + 8),
            maxLon: Double.routingDecode(raw, at: offset + 16),
            minLat: Double.routingDecode(raw, at: offset + 24),
            maxLat: Double.routingDecode(raw, at: offset + 32))
        guard result.minLon.isFinite, result.maxLon.isFinite, result.minLat.isFinite, result.maxLat.isFinite,
              result.minLon <= result.maxLon, result.minLat <= result.maxLat else { throw Failure.corrupt }
        return result
    }
    private static func intersects(_ raw: UnsafeRawBufferPointer, offset: Int,
        latitude: Double, longitude: Double, meters: Double) throws -> Bool {
        try envelope(raw, offset: offset)?.mayIntersect(latitude: latitude, longitude: longitude, meters: meters) ?? true
    }

    /// Piggyback the already-required body hash: 65,520 is both <=64KiB and
    /// divisible by the40-byte bounds stride. No extra pass or per-row I/O.
    private static func validateBodyAndEnvelope(_ source: RoutingFilePages, edgeCount: Int,
        cancelled: () -> Bool) throws -> (digest: String, envelope: GeometryEnvelope?) {
        let phase = RoutingWorkContext.measurement?.begin(.indexEnvelopeValidation)
        defer { RoutingWorkContext.measurement?.end(phase) }
        var sha = SHA256(), at = headerBytes, decodedRows = 0
        var union: GeometryEnvelope?, complete = true
        while at < source.fileBytes {
            let block = try source.read(at: at, count: min(65_520, source.fileBytes-at), cancelled: cancelled)
            try block.withUnsafeBytes { raw in
                sha.update(bufferPointer: raw)
                let rows = min(edgeCount-decodedRows, raw.count/40)
                for row in 0..<rows {
                    if row & 255 == 0, cancelled() { throw Failure.cancelled }
                    guard let edge = try envelope(raw, offset: row*40) else { complete = false; continue }
                    if var prior = union {
                        prior.minLon = min(prior.minLon, edge.minLon); prior.maxLon = max(prior.maxLon, edge.maxLon)
                        prior.minLat = min(prior.minLat, edge.minLat); prior.maxLat = max(prior.maxLat, edge.maxLat)
                        union = prior
                    } else { union = edge }
                }
                decodedRows += rows
            }
            RoutingWorkContext.measurement?.increment(.fileBytesHashed, by: UInt64(block.count))
            at += block.count
        }
        guard decodedRows == edgeCount else { throw Failure.corrupt }
        return (sha.finalize().map { String(format: "%02x", $0) }.joined(), complete ? union : nil)
    }

    /// A query is valid only after the closing source check succeeds. Never
    /// commit route state inside this closure; return it after this method does.
    /// Retained query objects are invalidated on both success and failure.
    func withBoundsQuery<Value>(reusing existing: BoundsQuery? = nil,
        cancelled: @escaping () -> Bool = { false },
        _ body: (BoundsQuery) throws -> Value) throws -> Value {
        if let existing {
            // Nested work remains provisional until its owning outer query closes.
            // Sharing its reservations avoids overlapping independent page budgets.
            try existing.validateOwner(self)
            guard !cancelled() else { throw Failure.cancelled }
            let value = try body(existing)
            guard !cancelled() else { throw Failure.cancelled }
            return value
        }
        try source.validate(cancelled: cancelled)
        let query = BoundsQuery(index: self, cancelled: cancelled)
        defer { query.invalidate() }
        let value = try body(query)
        try source.validate(cancelled: cancelled)
        return value
    }

    /// Four borrowed bounds pages plus two borrowed directory pages. One
    /// membership range and a straddling-row range fit the eight-lease cap. These
    /// remain charged to the shared source budget, so cache eviction cannot
    /// hide pinned memory. This synchronous mutable query is deliberately not
    /// Sendable. A row hit allocates nothing and performs no fstat.
    final class BoundsQuery {
        private let index: ExactSnapIndex
        private let cancelled: () -> Bool
        private var valid = true
        private var slots: [RoutingPageBorrow?] = [nil,nil,nil,nil]
        private var directorySlots: [RoutingPageBorrow?] = [nil,nil]
        private var recentDirectorySlot = 1
        private(set) var directoryBlockLoads = 0
        fileprivate init(index: ExactSnapIndex, cancelled: @escaping () -> Bool) {
            self.index = index; self.cancelled = cancelled
        }
        /// Negative only when every exact edge envelope misses the same padded
        /// rectangle used by per-edge matching. Unknown bounds retain all work.
        func mayContainMatch(latitude: Double, longitude: Double, meters: Double) throws -> Bool {
            guard valid else { throw RoutingPageError.closed }
            guard !cancelled() else { throw Failure.cancelled }
            guard latitude.isFinite, longitude.isFinite, meters.isFinite else { return true }
            return index.geometryEnvelope?.mayIntersect(latitude: latitude, longitude: longitude, meters: meters) ?? true
        }
        fileprivate func invalidate() {
            valid = false
            for i in slots.indices { slots[i] = nil }
            for i in directorySlots.indices { directorySlots[i] = nil }
        }
        fileprivate func validateOwner(_ expected: ExactSnapIndex) throws {
            guard valid else { throw RoutingPageError.closed }
            guard index === expected else { throw ExactSnapIndex.Failure.identityMismatch }
            guard !cancelled() else { throw RoutingPageError.cancelled }
        }
        private func withRow<T>(position: Int,count: Int,directory: Bool,
            _ body: (UnsafeRawBufferPointer,Int) throws -> T) throws -> T {
            let pageSize=ExactSnapIndex.pageLimits.pageBytes,key=position/pageSize
            let borrowed: RoutingPageBorrow
            if directory {
                let slot: Int
                if directorySlots[0]?.fileOffset == key*pageSize { slot=0 }
                else if directorySlots[1]?.fileOffset == key*pageSize { slot=1 }
                else {
                    slot=directorySlots[0] == nil ? 0 : (directorySlots[1] == nil ? 1 : 1-recentDirectorySlot)
                    directorySlots[slot]=nil
                    directorySlots[slot]=try index.source.borrowPage(containing: position,cancelled: cancelled)
                    directoryBlockLoads += 1
                }
                recentDirectorySlot=slot;borrowed=directorySlots[slot]!
            } else {
                let slot=key&3
                if slots[slot]?.fileOffset != key*pageSize {
                    slots[slot]=nil
                    slots[slot]=try index.source.borrowPage(containing: position,cancelled: cancelled)
                }
                borrowed=slots[slot]!
            }
            let within=position-borrowed.fileOffset
            if borrowed.count-within < count {
                let row=try index.source.read(at: position,count: count,cancelled: cancelled)
                return try row.withUnsafeBytes { try body($0,0) }
            }
            return try borrowed.withUnsafeBytes { try body($0,within) }
        }
        fileprivate func directoryRow(_ row: Int) throws -> (UInt64, UInt64, UInt64) {
            try validateOwner(index)
            guard row >= 0,row < index.header.cellCount else { throw ExactSnapIndex.Failure.corrupt }
            return try withRow(position: index.directoryAt+row*24,count: 24,directory: true) { raw,at in
                (UInt64.routingDecode(raw,at: at),UInt64.routingDecode(raw,at: at+8),UInt64.routingDecode(raw,at: at+16))
            }
        }
        func mayIntersect(edge: Int, latitude: Double, longitude: Double, meters: Double) throws -> Bool {
            try validateOwner(index)
            guard edge >= 0,edge < index.header.edgeCount else { return true }
            return try withRow(position: ExactSnapIndex.headerBytes+edge*40,count: 40,directory: false) { raw,at in
                try ExactSnapIndex.intersects(raw,offset: at,latitude: latitude,longitude: longitude,meters: meters)
            }
        }
    }

    private func directory(key: UInt64, query: BoundsQuery?, cancelled: () -> Bool) throws -> (start: Int, count: Int)? {
        var low = 0, high = header.cellCount
        while low < high {
            let mid = low + (high-low)/2
            let row: (UInt64,UInt64,UInt64)
            if let query { row = try query.directoryRow(mid) }
            else {
                let lease = try source.read(at: directoryAt + mid * 24,count: 24,cancelled: cancelled)
                row = lease.withUnsafeBytes { raw in
                    (UInt64.routingDecode(raw,at: 0),UInt64.routingDecode(raw,at: 8),UInt64.routingDecode(raw,at: 16))
                }
            }
            if row.0 < key { low = mid + 1 }
            else if row.0 > key { high = mid }
            else {
                guard row.1 <= UInt64(header.membershipCount), row.2 <= UInt64(header.membershipCount)-row.1 else { throw Failure.corrupt }
                return (Int(row.1), Int(row.2))
            }
        }
        return nil
    }

    static func cell(_ coordinate: Double) throws -> Int {
        let value = floor(coordinate / cellDegrees)
        guard value.isFinite, value >= Double(Int32.min), value <= Double(Int32.max) else { throw Failure.invalidFormat }
        return Int(value)
    }
    static func key(_ x: Int, _ y: Int) -> UInt64 {
        UInt64(UInt32(truncatingIfNeeded: x)) << 32 | UInt64(UInt32(truncatingIfNeeded: y))
    }
    static func digest(_ source: RoutingFilePages, offset: Int = 0,
        cancelled: () -> Bool) throws -> String {
        var sha = SHA256(), at = offset
        while at < source.fileBytes {
            let block = try source.read(at: at, count: min(65_536, source.fileBytes-at), cancelled: cancelled)
            block.withUnsafeBytes { sha.update(bufferPointer: $0) }
            RoutingWorkContext.measurement?.increment(.fileBytesHashed,by: UInt64(block.count))
            at += block.count
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
