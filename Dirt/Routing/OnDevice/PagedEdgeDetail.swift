import Foundation

/// Bounded raw V4 detail access only. This is not a replacement graph decoder.
/// Forward integration must initialize GraphV2Pack from its verified descriptor,
/// skip allocation of the seven leaf arrays and crossingSeconds entirely, and
/// pass a scoped query through throwing consumers. Never decode then discard,
/// expose fallible disk data as a nonthrowing collection, or turn I/O failure
/// into unknown surface/access. CSR, directed access, identities and restrictions
/// remain unchanged in that first integration. No resident saving is claimed
/// until the production initializer and consumers actually use this reader.
nonisolated final class PagedEdgeDetail: @unchecked Sendable {
    struct Identity: Sendable { let sha256: String; let bytes: Int; let edgeCount: Int }
    struct Row: Equatable, Sendable {
        let surface: UInt8, roadClass: UInt8, grade: UInt8, layer: Int8
        let structure: UInt8, accessLeaf: UInt8, flags: UInt8
        /// nil means the section is absent, not an unreadable value.
        let crossingSeconds: UInt32?
    }
    enum Field: Int, CaseIterable, Sendable {
        case surface, roadClass, grade, layer, structure, accessLeaf, flags, crossingSeconds
        var mask: UInt8 { UInt8(1) << rawValue }
    }
    struct Limits: Sendable {
        var maximumRowPayloadBytes = 16_384
        var rowSlots = 512
        var queryPageSlots = 8
        var pages = RoutingFilePages.Limits(pageBytes: 65_536, maximumCachedBytes: 1_048_576,
            maximumReadBytes: 65_536, maximumLivePayloadBytes: 1_179_648, maximumLeases: 8)
    }
    enum Failure: Error, Equatable {
        case invalidLayout, identityMismatch, invalidEdge, invalidLimits, queryClosed
    }
    struct Statistics: Sendable {
        let requests: UInt64, rowHits: UInt64, decodedRows: UInt64, pageBorrows: UInt64
        let allocatedRowPayloadBytes: Int, pageSlotMetadataBytes: Int
    }
    private struct Layout {
        let edges: Int, columns: [Int], crossing: Int?
        init(_ raw: UnsafeRawBufferPointer, fileBytes: Int, expectedEdges: Int) throws {
            guard raw.count >= 140, UInt32.routingDecode(raw,at: 0) == GraphV2Pack.magicV4,
                UInt16.routingDecode(raw,at: 4) == 4 else { throw Failure.invalidLayout }
            let flags = UInt16.routingDecode(raw,at: 6)
            guard flags & GraphV2Pack.flagV4LegalTopology != 0,
                flags & GraphV2Pack.flagV3Leaves != 0,
                UInt32.routingDecode(raw,at: 20) == 140 else { throw Failure.invalidLayout }
            edges = Int(UInt32.routingDecode(raw,at: 12))
            guard edges == expectedEdges else { throw Failure.identityMismatch }
            columns = [72,76,80,84,88,92,96].map { Int(UInt32.routingDecode(raw,at: $0)) }
            crossing = flags & GraphV2Pack.flagV3CrossingSeconds != 0 ? Int(UInt32.routingDecode(raw,at: 100)) : nil
            var ranges: [Range<Int>] = []
            for (offset,width) in columns.map({ ($0,1) }) + (crossing.map { [($0,4)] } ?? []) {
                guard offset >= 140, offset <= fileBytes, edges <= (fileBytes-offset)/width else { throw Failure.invalidLayout }
                let range = offset..<(offset+edges*width)
                guard !ranges.contains(where: { $0.overlaps(range) }) else { throw Failure.invalidLayout }
                ranges.append(range)
            }
        }
    }
    private enum Source { case memory(Data), file(RoutingFilePages) }
    private let source: Source
    private let layout: Layout
    private let limits: Limits
    private struct Slot {
        var edge: Int = -1
        var packed: UInt64 = 0
        var crossing: UInt32 = 0
        var present: UInt8 = 0
        func value(_ field: Field) -> UInt32 {
            field == .crossingSeconds ? crossing : UInt32((packed >> (field.rawValue * 8)) & 255)
        }
        mutating func set(_ field: Field, _ value: UInt32) {
            if field == .crossingSeconds { crossing = value }
            else {
                let shift = field.rawValue * 8
                packed = (packed & ~(UInt64(255) << shift)) | (UInt64(value) << shift)
            }
            present |= field.mask
        }
    }
    // Shared per-reader payload, independent of the number of open queries.
    // The lock is held only while copying one raw row, never through a ride,
    // an overlay loop, source validation, or an arbitrary caller closure.
    private let rowLock = NSLock()
    private var rows: UnsafeMutablePointer<Slot>?
    private var cachedPages: [RoutingPageBorrow?] = []
    private var replacement = 0
    var sharedRowPayloadBytes: Int { limits.rowSlots * MemoryLayout<Slot>.stride }
    var sharedPageSlotMetadataBytes: Int { limits.queryPageSlots * MemoryLayout<RoutingPageBorrow?>.stride }
    let identity: Identity?
    var edgeCount: Int { layout.edges }
    var pageStatistics: RoutingFilePages.Statistics? {
        if case .file(let pages) = source { return pages.statistics }; return nil
    }
    private static func validateLimits(_ limits: Limits) throws {
        guard limits.rowSlots > 0,
            limits.rowSlots <= limits.maximumRowPayloadBytes / MemoryLayout<Slot>.stride,
            limits.queryPageSlots > 0, limits.queryPageSlots <= 8,
            limits.queryPageSlots <= limits.pages.maximumLeases,
            limits.pages.maximumReadBytes >= 65_536 else { throw Failure.invalidLimits }
    }
    init(url: URL, identity: Identity, limits: Limits = Limits(), cancelled: () -> Bool = { false }) throws {
        try Self.validateLimits(limits)
        let pages = try RoutingFilePages(url: url,limits: limits.pages)
        guard pages.fileBytes == identity.bytes,
            try ExactSnapIndex.digest(pages,cancelled: cancelled) == identity.sha256 else { throw Failure.identityMismatch }
        let header = try pages.read(at: 0,count: 140,cancelled: cancelled)
        layout = try header.withUnsafeBytes { try Layout($0,fileBytes: pages.fileBytes,expectedEdges: identity.edgeCount) }
        try pages.validate(cancelled: cancelled)
        source = .file(pages); self.identity = identity; self.limits = limits
        initializeCache()
    }
    /// Fixture bytes already belong to the test; no file-budget claim for them.
    init(data: Data, expectedEdgeCount: Int, limits: Limits = Limits()) throws {
        try Self.validateLimits(limits)
        layout = try data.withUnsafeBytes { try Layout($0,fileBytes: data.count,expectedEdges: expectedEdgeCount) }
        source = .memory(data); identity = nil; self.limits = limits
        initializeCache()
    }
    func row(at edge: Int, using query: Query? = nil) throws -> Row {
        if let query {
            guard query.belongs(to: self) else { throw Failure.identityMismatch }
            return try query.row(at: edge)
        }
        return try withQuery(cancelled: { RoutingWorkContext.stopReason != nil }) { try $0.row(at: edge) }
    }
    func value(_ field: Field, at edge: Int, using query: Query? = nil) throws -> UInt32? {
        if let query {
            guard query.belongs(to: self) else { throw Failure.identityMismatch }
            return try query.value(field, at: edge)
        }
        return try withQuery(cancelled: { RoutingWorkContext.stopReason != nil }) {
            try $0.value(field, at: edge)
        }
    }
    private func initializeCache() {
        let storage = UnsafeMutablePointer<Slot>.allocate(capacity: limits.rowSlots)
        storage.initialize(repeating: Slot(),count: limits.rowSlots); rows = storage
        cachedPages = Array(repeating: nil,count: limits.queryPageSlots)
    }
    deinit { rows?.deinitialize(count: limits.rowSlots); rows?.deallocate() }

    /// Overlapping synchronous queries share one bounded reader cache. No
    /// query holds its lock between row reads. Validation brackets each caller's
    /// complete operation; query objects own no row buffers or page leases.
    /// A captured query is invalid after body exits. Do not publish partial
    /// results from inside body before the closing validation succeeds.
    func withQuery<T>(cancelled: () -> Bool = { false }, _ body: (Query) throws -> T) throws -> T {
        if cancelled() { throw RoutingPageError.cancelled }
        if case .file(let pages) = source { try pages.validate(cancelled: cancelled) }
        return try withoutActuallyEscaping(cancelled) { scopedCancellation in
            let query = Query(owner: self, cancelled: scopedCancellation)
            defer { query.invalidate() }
            let result = try body(query)
            if cancelled() { throw RoutingPageError.cancelled }
            if case .file(let pages) = source { try pages.validate(cancelled: cancelled) }
            return result
        }
    }
    private func readFields(at edge: Int, mask: UInt8, cancelled: () -> Bool) throws -> (Slot,Bool,UInt64) {
        guard !cancelled() else { throw RoutingPageError.cancelled }
        guard edge >= 0,edge < layout.edges else { throw Failure.invalidEdge }
        while !rowLock.try() {
            guard !cancelled() else { throw RoutingPageError.cancelled }
            Thread.sleep(forTimeInterval: 0.0001)
        }
        defer { rowLock.unlock() }
        guard !cancelled(), let rows else { throw RoutingPageError.cancelled }
        let index = edge % limits.rowSlots
        var slot = rows[index].edge == edge ? rows[index] : Slot(edge: edge)
        if slot.present & mask == mask { return (slot,true,0) }
        var borrows: UInt64 = 0
        // Work on a value copy. A failed/cancelled multi-column transaction
        // never publishes an incomplete row or presence bit to other queries.
        var missing = mask & ~slot.present
        while missing != 0 {
            let field = Field(rawValue: missing.trailingZeroBitCount)!
            missing &= ~field.mask
            let value: UInt32
            if field == .crossingSeconds {
                var crossing: UInt32 = 0
                if let at = layout.crossing {
                    for i in 0..<4 {
                        crossing |= UInt32(try byte(at: at+edge*4+i,cancelled: cancelled,borrows: &borrows)) << (i*8)
                    }
                }
                value = crossing
            } else {
                value = UInt32(try byte(at: layout.columns[field.rawValue]+edge,cancelled: cancelled,borrows: &borrows))
            }
            slot.set(field,value)
        }
        guard !cancelled() else { throw RoutingPageError.cancelled }
        rows[index] = slot
        return (slot,false,borrows)
    }
    private func materialize(_ slot: Slot) -> Row {
        Row(surface: UInt8(slot.value(.surface)),roadClass: UInt8(slot.value(.roadClass)),
            grade: UInt8(slot.value(.grade)),layer: Int8(bitPattern: UInt8(slot.value(.layer))),
            structure: UInt8(slot.value(.structure)),accessLeaf: UInt8(slot.value(.accessLeaf)),
            flags: UInt8(slot.value(.flags)),crossingSeconds: layout.crossing == nil ? nil : slot.crossing)
    }
    private func byte(at offset: Int,cancelled: () -> Bool,borrows: inout UInt64) throws -> UInt8 {
        switch source {
        case .memory(let data): return data[data.startIndex+offset]
        case .file(let source):
            for retained in cachedPages {
                if let page = retained,offset >= page.fileOffset,offset-page.fileOffset < page.count {
                    return page.withUnsafeBytes { $0[offset-page.fileOffset] }
                }
            }
            // The single shared cache, not each query, owns at most eight
            // borrows. Release replacement before acquiring another reservation.
            cachedPages[replacement] = nil
            let page = try source.borrowPage(containing: offset,cancelled: cancelled)
            cachedPages[replacement] = page;replacement = (replacement+1)%cachedPages.count;borrows += 1
            return page.withUnsafeBytes { $0[offset-page.fileOffset] }
        }
    }
    final class Query {
        private var owner: PagedEdgeDetail?
        private var scopedCancellation: (() -> Bool)?
        private var requests: UInt64 = 0,hits: UInt64 = 0,decoded: UInt64 = 0,borrows: UInt64 = 0
        fileprivate init(owner: PagedEdgeDetail,cancelled: @escaping () -> Bool) {
            self.owner = owner;scopedCancellation = cancelled
        }
        fileprivate func invalidate() { owner = nil;scopedCancellation = nil }
        fileprivate func belongs(to reader: PagedEdgeDetail) -> Bool { owner === reader }
        /// Payload numbers refer to the ONE shared reader cache and must not be
        /// summed over queries. The query itself allocates no row/page storage.
        var statistics: Statistics {
            Statistics(requests: requests,rowHits: hits,decodedRows: decoded,pageBorrows: borrows,
                allocatedRowPayloadBytes: owner?.sharedRowPayloadBytes ?? 0,
                pageSlotMetadataBytes: owner?.sharedPageSlotMetadataBytes ?? 0)
        }
        func row(at edge: Int,cancelled: () -> Bool = { false }) throws -> Row {
            guard let owner else { throw Failure.queryClosed }
            requests += 1
            let result = try owner.readFields(at: edge,mask: .max,cancelled: { cancelled() || self.scopedCancellation?() == true })
            if result.1 { hits += 1 } else { decoded += 1 };borrows += result.2
            return owner.materialize(result.0)
        }
        func value(_ field: Field, at edge: Int, cancelled: () -> Bool = { false }) throws -> UInt32? {
            guard let owner else { throw Failure.queryClosed }
            requests += 1
            let result = try owner.readFields(at: edge,mask: field.mask,
                cancelled: { cancelled() || self.scopedCancellation?() == true })
            if result.1 { hits += 1 } else { decoded += 1 }; borrows += result.2
            if field == .crossingSeconds, owner.layout.crossing == nil { return nil }
            return result.0.value(field)
        }
    }
}
