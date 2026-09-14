import Foundation

/// Complete spatial coverage only: never retains a graph, distance field or
/// reachability verdict. Each hit still evaluates this calculation's predicate.
nonisolated final class StationCoverageCache: @unchecked Sendable {
    struct Limits {
        var maximumPayloadBytes=1_048_576
        var maximumEntries=4096
        var maximumEntryEdges=4096
        var maximumConcurrentCaptures=4
    }
    private struct Key: Equatable { let latitude: Double,longitude: Double,meters: Double; let cellSuperset: Bool }
    private final class Entry {
        weak var owner: AnyObject?
        weak var index: AnyObject?
        let key: Key
        let edges: [Int32]
        let bytes: Int
        init(owner: AnyObject,index: AnyObject,key: Key,edges: [Int32]) {
            self.owner=owner;self.index=index;self.key=key;self.edges=edges
            bytes=edges.capacity*MemoryLayout<Int32>.stride
        }
    }
    private let lock=NSLock(),limits: Limits
    private var entries: [Entry]=[]
    private var bytes=0,captures=0
    init(limits: Limits = .init()) {
        var bounded=limits
        bounded.maximumPayloadBytes=max(0,min(1_048_576,limits.maximumPayloadBytes))
        bounded.maximumEntries=max(0,min(4096,limits.maximumEntries))
        bounded.maximumEntryEdges=max(0,min(4096,limits.maximumEntryEdges))
        bounded.maximumConcurrentCaptures=max(0,min(4,limits.maximumConcurrentCaptures))
        self.limits=bounded
    }

    /// Hit callbacks execute under the cache lock and must not reenter it.
    /// No array reference escapes, so eviction cannot leave uncharged payload.
    /// A failed/short-circuited enumeration never publishes a partial list.
    func enumerate(owner: AnyObject,index: AnyObject,latitude: Double,longitude: Double,meters: Double,
        cellSuperset: Bool = false,
        cancelled: () -> Bool,
        visit: (Int) throws -> Void,
        build: (_ emit: (Int) throws -> Void) throws -> Void) throws {
        guard !cancelled() else { throw RoutingPageError.cancelled }
        let measurement=RoutingWorkContext.measurement
        let phase=measurement?.begin(.stationCoverage)
        defer { measurement?.end(phase) }
        let key=Key(latitude: latitude,longitude: longitude,meters: meters,cellSuperset: cellSuperset)
        lock.lock()
        if let found=entries.firstIndex(where: { $0.owner === owner && $0.index === index && $0.key == key }) {
            defer { lock.unlock() }
            measurement?.increment(.stationCoverageCacheHits)
            measurement?.set(.stationCoverageCacheBytes,to: UInt64(bytes))
            for i in entries[found].edges.indices {
                if i&255 == 0,cancelled() { throw RoutingPageError.cancelled }
                try visit(Int(entries[found].edges[i]))
            }
            return
        }
        let capturing=captures < limits.maximumConcurrentCaptures && limits.maximumEntryEdges > 0
            && limits.maximumPayloadBytes > 0 && limits.maximumEntries > 0
        if capturing { captures += 1 }
        measurement?.set(.stationCoverageCaptureBytes,to: UInt64(captures*limits.maximumEntryEdges*4))
        lock.unlock()
        defer { if capturing {
            lock.lock();captures -= 1
            measurement?.set(.stationCoverageCaptureBytes,to: UInt64(captures*limits.maximumEntryEdges*4))
            lock.unlock()
        } }
        measurement?.increment(.stationCoverageCacheMisses)
        let scratch = capturing ? UnsafeMutablePointer<Int32>.allocate(capacity: limits.maximumEntryEdges) : nil
        var collectedCount=0,eligible=capturing
        defer { scratch?.deinitialize(count: collectedCount);scratch?.deallocate() }
        try withoutActuallyEscaping(visit) { visitor in
        try build { edge in
            if eligible {
                if edge < 0 || edge > Int(Int32.max) || collectedCount >= limits.maximumEntryEdges {
                    eligible=false
                } else { scratch!.advanced(by: collectedCount).initialize(to: Int32(edge));collectedCount += 1 }
            }
            try visitor(edge)
        }
        }
        guard eligible else { return }
        guard !cancelled() else { throw RoutingPageError.cancelled }
        // A sorted unique set is equivalent for these all-candidate predicates;
        // it is never used to rank or replace the ordinary snap candidates.
        measurement?.sampleIfDue()
        var collected=Array(UnsafeBufferPointer(start: scratch,count: collectedCount))
        collected.sort()
        var kept=0
        for i in collected.indices {
            if i&255 == 0,cancelled() { throw RoutingPageError.cancelled }
            if kept == 0 || collected[i] != collected[kept-1] { collected[kept]=collected[i];kept += 1 }
        }
        collected.removeSubrange(kept..<collected.count)
        let entry=Entry(owner: owner,index: index,key: key,edges: collected)
        guard entry.bytes <= limits.maximumPayloadBytes else { return }
        lock.lock();defer { lock.unlock() }
        var removed=0
        for i in entries.indices.reversed() where entries[i].owner == nil || entries[i].index == nil {
            bytes -= entries[i].bytes;entries.remove(at: i);removed += 1
        }
        // A concurrent identical scan may have completed while this one ran.
        if entries.contains(where: { $0.owner === owner && $0.index === index && $0.key == key }) { return }
        while !entries.isEmpty && (entries.count >= limits.maximumEntries || entry.bytes > limits.maximumPayloadBytes-bytes) {
            bytes -= entries.removeFirst().bytes;removed += 1
        }
        guard entry.bytes <= limits.maximumPayloadBytes-bytes else { return }
        entries.append(entry);bytes += entry.bytes
        measurement?.increment(.stationCoverageEntriesEvicted,by: UInt64(removed))
        measurement?.set(.stationCoverageCacheBytes,to: UInt64(bytes))
    }
}
