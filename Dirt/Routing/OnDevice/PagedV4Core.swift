import Foundation

/// Unactivated descriptor-backed core. No GraphV2Pack construction, mmap or
/// region-sized arrays. This slice requires V4 leaf sections; leafless V4 is
/// explicitly unsupported. Legal restrictions/leaf policy remain unavailable here;
/// this reader cannot by itself qualify a route. Proof preparation is a separate
/// bounded-memory full topology scan and is counted independently of queries.
nonisolated final class PagedV4Core: @unchecked Sendable {
    struct Identity: Equatable, Sendable { let sha256: String; let bytes: Int }
    struct TopologyProof: Sendable {
        let identity: Identity
        let formatVersion: Int
        fileprivate init(identity: Identity) { self.identity = identity; formatVersion = 1 }
    }
    struct Node: Equatable, Sendable { let longitude: Float, latitude: Float; let osmID: Int64 }
    struct Edge: Equatable, Sendable {
        let from: Int, to: Int, meters: UInt32, attributes: UInt16, osmWayID: Int64
        let forwardAccess: UInt8, reverseAccess: UInt8
    }
    struct Arc: Equatable, Sendable { let index: Int, source: Int, target: Int, edge: Int }
    struct Preparation: Sendable {
        let hashedBytes: Int
        let validationNodes: Int, validationEdges: Int, validationArcs: Int
        let elapsedSeconds: Double
        let reusedTopologyProof: Bool
    }
    struct QueryStatistics: Sendable {
        let nodes: UInt64, edges: UInt64, arcs: UInt64, scalars: UInt64, borrowedPages: UInt64
    }
    struct Limits: Sendable {
        var pageSlots = 4
        var pages = RoutingFilePages.Limits(pageBytes: 16_384, maximumCachedBytes: 262_144,
            maximumReadBytes: 65_536, maximumLivePayloadBytes: 393_216, maximumLeases: 8)
    }
    enum Failure: Error, Equatable {
        case invalidLayout, identityMismatch, invalidTopology, invalidRow, invalidLimits, queryClosed
        case legalMetadataUnavailable, metadataLimit, invalidLegalMetadata, unsupportedLeaflessV4
    }
    private struct Layout {
        let nodes: Int, edges: Int, arcs: Int
        let legal: LegalLayout
        let offsets: Int, targets: Int, arcEdges: Int, attrs: Int, meters: Int
        let coords: Int, from: Int, to: Int, osmNodes: Int, osmWays: Int, access: Int
        init(_ raw: UnsafeRawBufferPointer, fileBytes: Int) throws {
            guard raw.count >= 140, UInt32.routingDecode(raw,at: 0) == 0x34545244,
                  UInt16.routingDecode(raw,at: 4) == 4,
                  UInt32.routingDecode(raw,at: 20) == 140,
                  UInt16.routingDecode(raw,at: 6) & 9 == 9 else { throw Failure.invalidLayout }
            guard UInt16.routingDecode(raw,at: 6) & 2 != 0 else { throw Failure.unsupportedLeaflessV4 }
            nodes = Int(UInt32.routingDecode(raw,at: 8)); edges = Int(UInt32.routingDecode(raw,at: 12))
            arcs = Int(UInt32.routingDecode(raw,at: 16))
            offsets = Int(UInt32.routingDecode(raw,at: 24)); targets = Int(UInt32.routingDecode(raw,at: 28))
            arcEdges = Int(UInt32.routingDecode(raw,at: 32)); attrs = Int(UInt32.routingDecode(raw,at: 36))
            meters = Int(UInt32.routingDecode(raw,at: 40)); coords = Int(UInt32.routingDecode(raw,at: 44))
            from = Int(UInt32.routingDecode(raw,at: 64)); to = Int(UInt32.routingDecode(raw,at: 68))
            osmNodes = Int(UInt32.routingDecode(raw,at: 104)); osmWays = Int(UInt32.routingDecode(raw,at: 108))
            access = Int(UInt32.routingDecode(raw,at: 112))
            var ranges: [Range<Int>] = [] // Exactly eleven descriptors, never per-road.
            for (at,count,width) in [(offsets,nodes+1,4),(targets,arcs,4),(arcEdges,arcs,4),
                (attrs,edges,2),(meters,edges,4),(coords,nodes,8),(from,edges,4),(to,edges,4),
                (osmNodes,nodes,8),(osmWays,edges,8),(access,edges,2)] {
                guard at >= 140, at <= fileBytes, count <= (fileBytes-at)/width else { throw Failure.invalidLayout }
                let range = at..<(at+count*width)
                guard !ranges.contains(where: { $0.overlaps(range) }) else { throw Failure.invalidLayout }
                ranges.append(range)
            }
            legal = try LegalLayout(raw,fileBytes: fileBytes,coreRanges: ranges)
        }
    }
    let identity: Identity
    let proof: TopologyProof
    let preparation: Preparation
    private let layout: Layout
    private let pages: RoutingFilePages
    private let lock = NSLock()
    private var slots: [RoutingPageBorrow?]
    private var replacement = 0
    private var counters = QueryStatistics(nodes: 0,edges: 0,arcs: 0,scalars: 0,borrowedPages: 0)
    var nodeCount: Int { layout.nodes }
    var edgeCount: Int { layout.edges }
    var arcCount: Int { layout.arcs }
    var pageStatistics: RoutingFilePages.Statistics { pages.statistics }
    var queryStatistics: QueryStatistics { lock.lock(); defer { lock.unlock() }; return counters }

    init(url: URL, identity: Identity, proof suppliedProof: TopologyProof? = nil,
         limits: Limits = Limits(), cancelled: () -> Bool = { false }) throws {
        let began = ProcessInfo.processInfo.systemUptime
        guard limits.pageSlots > 0, limits.pageSlots <= 4,
              limits.pages.maximumLeases >= max(limits.pageSlots,5)+1,
              limits.pages.maximumReadBytes >= 65_536 else { throw Failure.invalidLimits }
        let source = try RoutingFilePages(url: url,limits: limits.pages)
        guard source.fileBytes == identity.bytes,
              try ExactSnapIndex.digest(source,cancelled: cancelled) == identity.sha256 else { throw Failure.identityMismatch }
        let header = try source.read(at: 0,count: 140,cancelled: cancelled)
        let descriptor = try header.withUnsafeBytes { try Layout($0,fileBytes: identity.bytes) }
        if let suppliedProof {
            guard suppliedProof.identity == identity, suppliedProof.formatVersion == 1 else { throw Failure.identityMismatch }
        }
        // Bounded streaming proof uses a temporary reader shared by validation;
        // no callbacks or arrays proportional to the region are allocated.
        let scan = Scanner(pages: source,layout: descriptor)
        if suppliedProof == nil { try scan.validate(cancelled: cancelled) }
        scan.release()
        try source.validate(cancelled: cancelled)
        self.pages = source; self.layout = descriptor; self.identity = identity
        self.proof = suppliedProof ?? TopologyProof(identity: identity)
        self.preparation = .init(hashedBytes: identity.bytes,
            validationNodes: suppliedProof == nil ? descriptor.nodes : 0,
            validationEdges: suppliedProof == nil ? descriptor.edges : 0,
            validationArcs: suppliedProof == nil ? descriptor.arcs : 0,
            elapsedSeconds: ProcessInfo.processInfo.systemUptime-began,reusedTopologyProof: suppliedProof != nil)
        slots = Array(repeating: nil,count: limits.pageSlots)
    }
    func close() { lock.lock(); slots = Array(repeating: nil,count: slots.count); pages.close(); lock.unlock() }
    /// Raw legal metadata is available; a turn evaluator using this interface
    /// is still required before this descriptor can calculate a legal route.
    func requireLegalMetadata() throws -> Never { throw Failure.legalMetadataUnavailable }
    func withLegalQuery<T>(cancelled: @escaping () -> Bool = { false },
                          _ body: (LegalQuery) throws -> T) throws -> T {
        try pages.validate(cancelled: cancelled)
        let query = LegalQuery(owner: self,cancelled: cancelled)
        defer { query.finish() }
        try query.requireCurrentCapability()
        let result = try body(query)
        try pages.validate(cancelled: cancelled)
        return result
    }
    func withQuery<T>(cancelled: @escaping () -> Bool = { false }, _ body: (Query) throws -> T) throws -> T {
        try pages.validate(cancelled: cancelled)
        let query = Query(owner: self,cancelled: cancelled)
        defer { query.finish() }
        let result = try body(query)
        try pages.validate(cancelled: cancelled)
        return result
    }
    private func scalar<T: RoutingLittleEndianScalar>(_ type: T.Type, at: Int,
        cancelled: () -> Bool) throws -> T {
        if cancelled() { throw RoutingPageError.cancelled }
        lock.lock(); defer { lock.unlock() }
        var borrows: UInt64 = 0
        let result: T = try Self.read(type,at: at,pages: pages,slots: &slots,replacement: &replacement,
            borrows: &borrows,cancelled: cancelled)
        counters = .init(nodes: counters.nodes,edges: counters.edges,arcs: counters.arcs,
            scalars: counters.scalars+1,borrowedPages: counters.borrowedPages+borrows)
        return result
    }
    private func count(nodes: UInt64 = 0,edges: UInt64 = 0,arcs: UInt64 = 0) {
        lock.lock(); defer { lock.unlock() }
        counters = .init(nodes: counters.nodes+nodes,edges: counters.edges+edges,arcs: counters.arcs+arcs,
            scalars: counters.scalars,borrowedPages: counters.borrowedPages)
    }
    private static func read<T: RoutingLittleEndianScalar>(_ type: T.Type,at: Int,pages: RoutingFilePages,
        slots: inout [RoutingPageBorrow?],replacement: inout Int,borrows: inout UInt64,
        cancelled: () -> Bool) throws -> T {
        for slot in slots {
            if let slot, at >= slot.fileOffset, at-slot.fileOffset <= slot.count-T.routingByteWidth {
                return slot.withUnsafeBytes { T.routingDecode($0,at: at-slot.fileOffset) }
            }
        }
        slots[replacement] = nil
        let page = try pages.borrowPage(containing: at,cancelled: cancelled); borrows += 1
        slots[replacement] = page; replacement = (replacement+1)%slots.count
        if at-page.fileOffset <= page.count-T.routingByteWidth {
            return page.withUnsafeBytes { T.routingDecode($0,at: at-page.fileOffset) }
        }
        return try pages.read(at: at,count: T.routingByteWidth,cancelled: cancelled).withUnsafeBytes { T.routingDecode($0,at: 0) }
    }
    final class Query {
        private var owner: PagedV4Core?
        private let cancelled: () -> Bool
        fileprivate init(owner: PagedV4Core,cancelled: @escaping () -> Bool) { self.owner = owner; self.cancelled = cancelled }
        fileprivate func finish() { owner = nil }
        func belongs(to source: PagedV4Core) -> Bool { owner === source }
        func validateSource() throws { let source = try get(); try source.pages.validate(cancelled: cancelled) }
        private func get() throws -> PagedV4Core {
            guard let owner else { throw Failure.queryClosed }
            if cancelled() { throw RoutingPageError.cancelled }
            return owner
        }
        func node(_ node: Int) throws -> Node {
            let owner = try get(), l = owner.layout
            guard (0..<l.nodes).contains(node) else { throw Failure.invalidRow }
            let x = try owner.scalar(Float.self,at: l.coords+node*8,cancelled: cancelled)
            let y = try owner.scalar(Float.self,at: l.coords+node*8+4,cancelled: cancelled)
            let osm = try owner.scalar(Int64.self,at: l.osmNodes+node*8,cancelled: cancelled)
            guard osm != 0, x.isFinite, y.isFinite,
                  (-180...180).contains(x), (-90...90).contains(y) else {
                throw Failure.invalidTopology
            }
            owner.count(nodes: 1); return .init(longitude: x,latitude: y,osmID: osm)
        }
        func edge(_ edge: Int) throws -> Edge {
            let owner = try get(), l = owner.layout
            guard (0..<l.edges).contains(edge) else { throw Failure.invalidRow }
            func i(_ at: Int) throws -> Int { Int(try owner.scalar(Int32.self,at: at+edge*4,cancelled: cancelled)) }
            let a = try i(l.from), b = try i(l.to)
            let meters = try owner.scalar(UInt32.self,at: l.meters+edge*4,cancelled: cancelled)
            let attr = try owner.scalar(UInt16.self,at: l.attrs+edge*2,cancelled: cancelled)
            let way = try owner.scalar(Int64.self,at: l.osmWays+edge*8,cancelled: cancelled)
            let forward = try owner.scalar(UInt8.self,at: l.access+edge*2,cancelled: cancelled)
            let reverse = try owner.scalar(UInt8.self,at: l.access+edge*2+1,cancelled: cancelled)
            guard forward <= 5, reverse <= 5 else { throw Failure.invalidLegalMetadata }
            owner.count(edges: 1)
            return .init(from: a,to: b,meters: meters,attributes: attr,osmWayID: way,forwardAccess: forward,reverseAccess: reverse)
        }
        func outgoing(_ node: Int, _ visit: (Arc) throws -> Void) throws {
            let owner = try get(), l = owner.layout
            guard (0..<l.nodes).contains(node) else { throw Failure.invalidRow }
            let begin = Int(try owner.scalar(Int32.self,at: l.offsets+node*4,cancelled: cancelled))
            let end = Int(try owner.scalar(Int32.self,at: l.offsets+(node+1)*4,cancelled: cancelled))
            guard begin >= 0, end >= begin, end <= l.arcs else { throw Failure.invalidTopology }
            for index in begin..<end {
                let target = Int(try owner.scalar(Int32.self,at: l.targets+index*4,cancelled: cancelled))
                let edge = Int(try owner.scalar(Int32.self,at: l.arcEdges+index*4,cancelled: cancelled))
                owner.count(arcs: 1); try visit(.init(index: index,source: node,target: target,edge: edge))
            }
        }
    }
    private final class Scanner {
        let pages: RoutingFilePages, layout: Layout
        // Verification repeatedly interleaves five columns. Dedicated borrows
        // prevent random endpoint rows evicting the sequential CSR columns.
        // All five remain charged to the existing 384 KiB source page budget.
        var slots: [RoutingPageBorrow?] = Array(repeating: nil,count: 5)
        init(pages: RoutingFilePages,layout: Layout) { self.pages = pages; self.layout = layout }
        func release() { slots = [] }
        func i(_ at: Int,_ column: Int,_ cancelled: () -> Bool) throws -> Int {
            if let page = slots[column], at >= page.fileOffset,
               at-page.fileOffset <= page.count-4 {
                return page.withUnsafeBytes { Int(Int32.routingDecode($0,at: at-page.fileOffset)) }
            }
            slots[column] = nil
            let page = try pages.borrowPage(containing: at,cancelled: cancelled)
            slots[column] = page
            if at-page.fileOffset <= page.count-4 {
                return page.withUnsafeBytes { Int(Int32.routingDecode($0,at: at-page.fileOffset)) }
            }
            return try pages.read(at: at,count: 4,cancelled: cancelled).withUnsafeBytes {
                Int(Int32.routingDecode($0,at: 0))
            }
        }
        func validate(cancelled: () -> Bool) throws {
            let l = layout
            let first = try i(l.offsets,0,cancelled), last = try i(l.offsets+l.nodes*4,0,cancelled)
            guard first == 0, last == l.arcs else { throw Failure.invalidTopology }
            for edge in 0..<l.edges {
                if edge & 1023 == 0 { try pages.validate(cancelled: cancelled) }
                let a = try i(l.from+edge*4,3,cancelled), b = try i(l.to+edge*4,4,cancelled)
                guard (0..<l.nodes).contains(a), (0..<l.nodes).contains(b) else { throw Failure.invalidTopology }
            }
            for node in 0..<l.nodes {
                if node & 1023 == 0 { try pages.validate(cancelled: cancelled) }
                let begin = try i(l.offsets+node*4,0,cancelled), end = try i(l.offsets+(node+1)*4,0,cancelled)
                guard begin >= 0, end >= begin, end <= l.arcs else { throw Failure.invalidTopology }
                for arc in begin..<end {
                    if arc & 1023 == 0 { try pages.validate(cancelled: cancelled) }
                    let target = try i(l.targets+arc*4,1,cancelled), edge = try i(l.arcEdges+arc*4,2,cancelled)
                    guard (0..<l.nodes).contains(target), (0..<l.edges).contains(edge) else { throw Failure.invalidTopology }
                    let a = try i(l.from+edge*4,3,cancelled), b = try i(l.to+edge*4,4,cancelled)
                    guard (a == node && b == target) || (b == node && a == target) else { throw Failure.invalidTopology }
                }
            }
        }
    }
}

extension PagedV4Core {
    /// Exact raw sections, including fields unused by today's native decoder.
    /// Chunks are at most 64KiB; consumers must budget any retained aggregation.
    enum LegalSection: CaseIterable, Hashable { case conditionals, provenance, capabilities, enums, metadata, geometryHash }
    struct Barrier: Equatable {
        let osmNodeID: Int64, graphNode: UInt32, decision: UInt8
        let reserved: (UInt8,UInt8,UInt8)
        static func == (a: Barrier,b: Barrier) -> Bool {
            a.osmNodeID == b.osmNodeID && a.graphNode == b.graphNode && a.decision == b.decision
                && a.reserved.0 == b.reserved.0 && a.reserved.1 == b.reserved.1 && a.reserved.2 == b.reserved.2
        }
    }
    struct ViaMember: Equatable { let osmWayID: Int64; let edge: Int32 }
    struct Restriction: Equatable {
        let osmRelationID: Int64
        let kind: UInt8, flags: UInt8
        let fromEdge: UInt32, toEdge: UInt32, viaNode: Int32
        let exceptMask: UInt16, vehicleMask: UInt16, conditionalIndex: Int32
        let via: [ViaMember]
        var only: Bool { flags & 2 != 0 }
    }
    private struct LegalLayout {
        let barriers: Range<Int>, restrictions: Range<Int>
        let sections: [LegalSection: Range<Int>]
        init(_ raw: UnsafeRawBufferPointer,fileBytes: Int,coreRanges: [Range<Int>]) throws {
            func offset(_ at: Int) -> Int { Int(UInt32.routingDecode(raw,at: at)) }
            let barrier = offset(116), restriction = offset(120), conditional = offset(124)
            let provenance = offset(128), capabilities = offset(132), hash = offset(136)
            let enums = offset(56), meta = offset(60), leaves = offset(72)
            guard barrier >= 140, restriction >= barrier+4, conditional >= restriction+4,
                  provenance > conditional, capabilities > provenance, hash > capabilities,
                  hash <= fileBytes-32, enums >= 140, meta > enums, leaves > meta else { throw Failure.invalidLegalMetadata }
            barriers = barrier..<restriction; restrictions = restriction..<conditional
            sections = [.conditionals: conditional..<provenance,.provenance: provenance..<capabilities,
                .capabilities: capabilities..<hash,.geometryHash: hash..<hash+32,
                .enums: enums..<meta,.metadata: meta..<leaves]
            let metadataRanges = [barriers,restrictions] + Array(sections.values)
            for (i,range) in metadataRanges.enumerated() {
                guard range.upperBound <= fileBytes,
                      !coreRanges.contains(where: { $0.overlaps(range) }),
                      !metadataRanges.prefix(i).contains(where: { $0.overlaps(range) }) else { throw Failure.invalidLegalMetadata }
            }
        }
    }
    final class LegalQuery {
        private var owner: PagedV4Core?
        private let cancelled: () -> Bool
        fileprivate init(owner: PagedV4Core,cancelled: @escaping () -> Bool) { self.owner = owner; self.cancelled = cancelled }
        fileprivate func finish() { owner = nil }
        func belongs(to source: PagedV4Core) -> Bool { owner === source }
        func validateSource() throws { let source = try get(); try source.pages.validate(cancelled: cancelled) }
        private func get() throws -> PagedV4Core {
            guard let owner else { throw Failure.queryClosed }
            if cancelled() { throw RoutingPageError.cancelled }
            return owner
        }
        func sectionLength(_ section: LegalSection) throws -> Int {
            let owner = try get(); return owner.layout.legal.sections[section]!.count
        }
        /// Raw JSON preserves conditional rules/timezone/fail-closed policy,
        /// unsupported fields and provenance. No speculative access interpretation.
        func sectionChunk(_ section: LegalSection,offset: Int,count: Int) throws -> RoutingByteLease {
            let owner = try get(), range = owner.layout.legal.sections[section]!
            guard offset >= 0, count >= 0, count <= 65_536, offset <= range.count,
                  count <= range.count-offset else { throw Failure.metadataLimit }
            return try owner.pages.read(at: range.lowerBound+offset,count: count,cancelled: cancelled)
        }
        func requireCurrentCapability() throws {
            let count = try sectionLength(.capabilities)
            guard count <= 65_536 else { throw Failure.metadataLimit }
            let lease = try sectionChunk(.capabilities,offset: 0,count: count)
            let data = lease.withUnsafeBytes { Data($0) }
            guard let values = try JSONSerialization.jsonObject(with: data) as? [String],
                  values.contains("legal-topology.v1") else { throw Failure.legalMetadataUnavailable }
        }
        func forEachBarrier(_ visit: (Int,Barrier) throws -> Void) throws {
            let owner = try get(), range = owner.layout.legal.barriers
            let count = Int(try owner.scalar(UInt32.self,at: range.lowerBound,cancelled: cancelled))
            guard count <= (range.count-4)/16 else { throw Failure.invalidLegalMetadata }
            for i in 0..<count {
                let at = range.lowerBound+4+i*16
                let bytes = try owner.pages.read(at: at,count: 16,cancelled: cancelled)
                let row = bytes.withUnsafeBytes { raw in
                    Barrier(osmNodeID: Int64.routingDecode(raw,at: 0),graphNode: UInt32.routingDecode(raw,at: 8),
                        decision: raw[12],reserved: (raw[13],raw[14],raw[15]))
                }
                guard Int(row.graphNode) < owner.nodeCount else { throw Failure.invalidLegalMetadata }
                try visit(i,row)
            }
        }
        /// At most 1024 via members (16KiB actual row payload ceiling). A larger
        /// source row is unavailable under this budget, never silently truncated.
        /// Whole restriction count does not allocate a whole restriction table.
        func forEachRestriction(_ visit: (Int,Restriction) throws -> Void) throws {
            let owner = try get(), range = owner.layout.legal.restrictions
            let count = Int(try owner.scalar(UInt32.self,at: range.lowerBound,cancelled: cancelled))
            guard count <= (range.count-4)/32 else { throw Failure.invalidLegalMetadata }
            var at = range.lowerBound+4
            for i in 0..<count {
                guard at <= range.upperBound-32 else { throw Failure.invalidLegalMetadata }
                let header = try owner.pages.read(at: at,count: 32,cancelled: cancelled)
                let fixed = header.withUnsafeBytes { raw in
                    (Int64.routingDecode(raw,at: 0),raw[8],raw[9],Int(UInt16.routingDecode(raw,at: 10)),
                     UInt32.routingDecode(raw,at: 12),UInt32.routingDecode(raw,at: 16),Int32.routingDecode(raw,at: 20),
                     UInt16.routingDecode(raw,at: 24),UInt16.routingDecode(raw,at: 26),Int32.routingDecode(raw,at: 28))
                }
                guard fixed.3 <= (range.upperBound-at-32)/12 else { throw Failure.invalidLegalMetadata }
                guard fixed.3 <= 1024 else { throw Failure.metadataLimit }
                guard Int(fixed.4) < owner.edgeCount, Int(fixed.5) < owner.edgeCount,
                      fixed.6 == -1 || (0..<owner.nodeCount).contains(Int(fixed.6)) else { throw Failure.invalidLegalMetadata }
                var via: [ViaMember] = []; via.reserveCapacity(fixed.3)
                guard via.capacity * MemoryLayout<ViaMember>.stride <= 16_384 else { throw Failure.metadataLimit }
                if fixed.3 > 0 {
                    let bytes = try owner.pages.read(at: at+32,count: fixed.3*12,cancelled: cancelled)
                    try bytes.withUnsafeBytes { raw in
                        for v in 0..<fixed.3 {
                            let edge = Int32.routingDecode(raw,at: v*12+8)
                            guard edge == -1 || (0..<owner.edgeCount).contains(Int(edge)) else { throw Failure.invalidLegalMetadata }
                            via.append(.init(osmWayID: Int64.routingDecode(raw,at: v*12),edge: edge))
                        }
                    }
                }
                try visit(i,.init(osmRelationID: fixed.0,kind: fixed.1,flags: fixed.2,
                    fromEdge: fixed.4,toEdge: fixed.5,viaNode: fixed.6,exceptMask: fixed.7,
                    vehicleMask: fixed.8,conditionalIndex: fixed.9,via: via))
                at += 32+fixed.3*12
            }
        }
    }
}
