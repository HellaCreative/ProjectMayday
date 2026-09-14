import Foundation

nonisolated enum ExactSnapIndexPreparation {
    /// Bounded borrowed scalar windows. Two fixed slots retain at most 128KiB
    /// through the source's shared payload/lease budget. Byte semantics are
    /// identical to RoutingPagedColumn; rows do not allocate or fstat on hits.
    /// Preparation revalidates all source bytes before publishing its result.
    private final class ScalarWindow<Element: RoutingLittleEndianScalar> {
        private let source: RoutingFilePages
        private let offset: Int
        private let count: Int
        private let elementsPerBlock: Int
        private var slots: [(key: Int, lease: RoutingByteLease?)] = [(-1,nil),(-1,nil)]
        private var mostRecentSlot = 1
        private(set) var blockLoads = 0
        init(source: RoutingFilePages,offset: Int,count: Int) throws {
            guard offset >= 0, count >= 0, offset <= source.fileBytes,
                  count <= (source.fileBytes-offset)/Element.routingByteWidth else { throw RoutingPageError.invalidRange }
            self.source = source; self.offset = offset; self.count = count
            elementsPerBlock = 65_536/Element.routingByteWidth
        }
        private(set) var scalarReads = 0
        private(set) var bufferBorrows = 0
        private(set) var cancellationChecks = 0
        private var pendingScalars = 0
        private func checkWork(_ count: Int,cancelled: () -> Bool) throws {
            pendingScalars += count
            if pendingScalars >= 1024 {
                cancellationChecks += 1;pendingScalars = 0
                guard !cancelled() else { throw RoutingPageError.cancelled }
            }
        }
        private func block(_ key: Int,cancelled: () -> Bool) throws -> RoutingByteLease {
            // Both endpoints commonly live in blocks with equal parity. A
            // direct-mapped pair copies 64KiB on every alternating endpoint;
            // full associativity keeps both under the identical payload cap.
            let slot: Int
            if slots[0].key == key { slot = 0 }
            else if slots[1].key == key { slot = 1 }
            else {
                slot = slots[0].lease == nil ? 0 : (slots[1].lease == nil ? 1 : 1 - mostRecentSlot)
                slots[slot] = (-1, nil)
                let first = key * elementsPerBlock
                let lease = try source.read(at: offset + first * Element.routingByteWidth,
                    count: min(elementsPerBlock, count - first) * Element.routingByteWidth,
                    cancelled: cancelled)
                slots[slot] = (key, lease)
                blockLoads += 1
            }
            mostRecentSlot = slot
            return slots[slot].lease!
        }
        /// lon/lat pairs cannot straddle these even-sized scalar blocks.
        func pair(_ index: Int,cancelled: () -> Bool) throws -> (Element,Element) {
            guard index >= 0,index < count-1,index&1 == 0 else { throw RoutingPageError.invalidRange }
            try checkWork(2,cancelled: cancelled)
            let lease = try block(index/elementsPerBlock,cancelled: cancelled)
            scalarReads += 2;bufferBorrows += 1
            return lease.withUnsafeBytes {
                let at = (index%elementsPerBlock)*Element.routingByteWidth
                return (Element.routingDecode($0,at: at),Element.routingDecode($0,at: at+Element.routingByteWidth))
            }
        }
        /// Bounded buffer borrow: at most1024scalars between cancellation gates,
        /// with no per-point Data access, closure creation or clock reads.
        func withPairs(_ range: Range<Int>,cancelled: () -> Bool,
            _ visit: (UnsafeRawBufferPointer,Int,Int) throws -> Void) throws {
            guard range.lowerBound >= 0,range.upperBound <= count,
                  range.lowerBound&1 == 0,range.upperBound&1 == 0 else { throw RoutingPageError.invalidRange }
            var cursor = range.lowerBound
            while cursor < range.upperBound {
                let within = cursor%elementsPerBlock
                let amount = min(1024,min(range.upperBound-cursor,elementsPerBlock-within))
                try checkWork(amount,cancelled: cancelled)
                let lease = try block(cursor/elementsPerBlock,cancelled: cancelled)
                scalarReads += amount;bufferBorrows += 1
                try lease.withUnsafeBytes { try visit($0,within*Element.routingByteWidth,amount) }
                cursor += amount
            }
        }
    }

    /// Convenience for fixtures/local immutable inputs. Production should use
    /// the already-verified manifest identity rather than hash twice for naming.
    static func sourceIdentity(graphURL: URL, geometryURL: URL,
        cancelled: () -> Bool = { false }) throws -> ExactSnapIndex.Identity {
        let graph = try RoutingFilePages(url: graphURL, limits: ExactSnapIndex.pageLimits)
        let geometry = try RoutingFilePages(url: geometryURL, limits: ExactSnapIndex.pageLimits)
        defer { graph.close(); geometry.close() }
        return try .init(graphSHA256: ExactSnapIndex.digest(graph, cancelled: cancelled), graphBytes: graph.fileBytes,
            geometrySHA256: ExactSnapIndex.digest(geometry, cancelled: cancelled), geometryBytes: geometry.fileBytes)
    }

    /// Reuse verifies the derivative checksum. Creation verifies both immutable
    /// source hashes before and after preparation; errors never invoke a dense
    /// in-memory fallback. Caller budgets cancellation/deadline over this whole
    /// operation and reports its preparation progress independently of search.
    static func prepare(graphURL: URL, geometryURL: URL, destination: URL,
        identity: ExactSnapIndex.Identity, limits: ExactSnapIndexBuilder.Limits = .init(),
        cancelled: () -> Bool = { false }) throws -> ExactSnapIndex {
        let graph = try RoutingFilePages(url: graphURL, limits: ExactSnapIndex.pageLimits)
        let geometry = try RoutingFilePages(url: geometryURL, limits: ExactSnapIndex.pageLimits)
        defer { graph.close(); geometry.close() }
        guard graph.fileBytes == identity.graphBytes, geometry.fileBytes == identity.geometryBytes,
              try ExactSnapIndex.digest(graph, cancelled: cancelled) == identity.graphSHA256,
              try ExactSnapIndex.digest(geometry, cancelled: cancelled) == identity.geometrySHA256 else {
            throw ExactSnapIndex.Failure.identityMismatch
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            do { return try ExactSnapIndex(url: destination, identity: identity, cancelled: cancelled) }
            catch ExactSnapIndex.Failure.identityMismatch { /* stale private derivative */ }
            catch ExactSnapIndex.Failure.corrupt { /* rebuild from validated sources */ }
            catch ExactSnapIndex.Failure.invalidFormat { /* obsolete private format */ }
        }
        let h = try graph.read(at: 0, count: 140, cancelled: cancelled)
        let fields = h.withUnsafeBytes { raw in (0..<35).map { Int(UInt32.routingDecode(raw, at: $0*4)) } }
        let version = h.withUnsafeBytes { UInt16.routingDecode($0, at: 4) }
        let flags = h.withUnsafeBytes { UInt16.routingDecode($0, at: 6) }
        guard fields[0] == Int(GraphV2Pack.magicV4), version == 4, flags & 9 == 9,
              fields[5] >= 140 else { throw ExactSnapIndex.Failure.invalidFormat }
        let nodes = fields[2], edges = fields[3]
        let from = try RoutingPagedColumn<Int32>(source: graph, byteOffset: fields[16], count: edges)
        let to = try RoutingPagedColumn<Int32>(source: graph, byteOffset: fields[17], count: edges)
        let coordinates = try ScalarWindow<Float>(source: graph,offset: fields[11],count: nodes*2)
        let gh = try geometry.read(at: 0, count: 16, cancelled: cancelled)
        let geometryFields = gh.withUnsafeBytes { raw in (0..<4).map { Int(UInt32.routingDecode(raw, at: $0*4)) } }
        let doubles = gh.withUnsafeBytes { UInt16.routingDecode($0, at: 6) & 1 != 0 }
        guard geometryFields[0] == Int(GeometryV1Pack.magic), geometryFields[2] == edges else { throw ExactSnapIndex.Failure.invalidFormat }
        let offsets = try RoutingPagedColumn<Int32>(source: geometry, byteOffset: 16, count: edges+1)
        var coordsAt = 16 + (edges+1)*4
        if doubles, coordsAt % 8 != 0 { coordsAt += 8 - coordsAt%8 }
        let width = doubles ? 8 : 4, coordCount = geometryFields[3]
        guard coordsAt <= geometry.fileBytes, coordCount <= (geometry.fileBytes-coordsAt)/width else { throw ExactSnapIndex.Failure.corrupt }
        let floatGeometry: ScalarWindow<Float>? = doubles ? nil : try ScalarWindow<Float>(source: geometry,offset: coordsAt,count: coordCount)
        let doubleGeometry: ScalarWindow<Double>? = doubles ? try ScalarWindow<Double>(source: geometry,offset: coordsAt,count: coordCount) : nil
        defer {
            let measurement = RoutingWorkContext.measurement
            measurement?.increment(.indexSourceBlockLoads, by: UInt64(coordinates.blockLoads + (floatGeometry?.blockLoads ?? 0) + (doubleGeometry?.blockLoads ?? 0)))
            measurement?.increment(.indexSourceScalars,by: UInt64(coordinates.scalarReads+(floatGeometry?.scalarReads ?? 0)+(doubleGeometry?.scalarReads ?? 0)))
            measurement?.increment(.indexSourceBufferBorrows,by: UInt64(coordinates.bufferBorrows+(floatGeometry?.bufferBorrows ?? 0)+(doubleGeometry?.bufferBorrows ?? 0)))
            measurement?.increment(.indexScanCancellationChecks,by: UInt64(coordinates.cancellationChecks+(floatGeometry?.cancellationChecks ?? 0)+(doubleGeometry?.cancellationChecks ?? 0)))
        }
        // Only the current contiguous endpoint block is retained. Coordinate
        // and geometry leases are scoped to each edge/chunk.
        var blockStart = -1
        var fromBlock: RoutingByteColumn<Int32>?, toBlock: RoutingByteColumn<Int32>?, offsetBlock: RoutingByteColumn<Int32>?
        try ExactSnapIndexBuilder.build(to: destination, identity: identity, edgeCount: edges, limits: limits, cancelled: cancelled, beforePublish: {
            guard try ExactSnapIndex.digest(graph, cancelled: cancelled) == identity.graphSHA256,
                  try ExactSnapIndex.digest(geometry, cancelled: cancelled) == identity.geometrySHA256 else {
                throw ExactSnapIndex.Failure.identityMismatch
            }
        }) { edge in
            let start = edge / 4096 * 4096
            if blockStart != start {
                let end = min(edges,start+4096)
                fromBlock = nil; toBlock = nil; offsetBlock = nil
                fromBlock = try from.lease(start..<end, cancelled: cancelled)
                toBlock = try to.lease(start..<end, cancelled: cancelled)
                offsetBlock = try offsets.lease(start..<(end+1), cancelled: cancelled)
                blockStart = start
            }
            let a = Int(fromBlock![edge]), b = Int(toBlock![edge])
            if a < 0 || b < 0 || a >= nodes || b >= nodes { return nil }
            let ac = try coordinates.pair(a*2,cancelled: cancelled)
            let bc = try coordinates.pair(b*2,cancelled: cancelled)
            let aLon = Double(ac.0),aLat = Double(ac.1),bLon = Double(bc.0),bLat = Double(bc.1)
            var minLon = min(aLon,bLon), maxLon = max(aLon,bLon), minLat = min(aLat,bLat), maxLat = max(aLat,bLat)
            let first = Int(offsetBlock![edge]), last = Int(offsetBlock![edge+1])
            guard first >= 0, last >= first, last <= coordCount, first%2 == 0, last%2 == 0 else { throw ExactSnapIndex.Failure.corrupt }
            if let doubleGeometry {
                try doubleGeometry.withPairs(first..<last,cancelled: cancelled) { raw,at,count in
                    for i in stride(from: 0,to: count,by: 2) {
                        let lon = Double.routingDecode(raw,at: at+i*8),lat = Double.routingDecode(raw,at: at+(i+1)*8)
                        guard lon.isFinite,lat.isFinite else { throw ExactSnapIndex.Failure.corrupt }
                        minLon = min(minLon,lon);maxLon = max(maxLon,lon)
                        minLat = min(minLat,lat);maxLat = max(maxLat,lat)
                    }
                }
            } else if let floatGeometry {
                try floatGeometry.withPairs(first..<last,cancelled: cancelled) { raw,at,count in
                    for i in stride(from: 0,to: count,by: 2) {
                        let lon = Double(Float.routingDecode(raw,at: at+i*4)),lat = Double(Float.routingDecode(raw,at: at+(i+1)*4))
                        guard lon.isFinite,lat.isFinite else { throw ExactSnapIndex.Failure.corrupt }
                        minLon = min(minLon,lon);maxLon = max(maxLon,lon)
                        minLat = min(minLat,lat);maxLat = max(maxLat,lat)
                    }
                }
            } else { throw ExactSnapIndex.Failure.invalidFormat }
            return ExactSnapIndexBuilder.Edge(aLon: aLon,aLat: aLat,bLon: bLon,bLat: bLat,
                minLon: minLon,maxLon: maxLon,minLat: minLat,maxLat: maxLat)
        }
        return try ExactSnapIndex(url: destination, identity: identity, cancelled: cancelled)
    }
}
