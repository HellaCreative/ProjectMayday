import Foundation

/// Search-local memo of an exact directed CSR arc's static scalar cost. No
/// accumulated length/dirt, legal turn state, predecessor or virtual arc enters
/// this table. A collision recomputes the original arithmetic unchanged.
nonisolated final class DirectedStepMemo {
    private struct Entry { var key: UInt32; var cost: Double }
    private let rows: UnsafeMutablePointer<Entry>
    private let count: Int
    let payloadBytes: Int
    private(set) var hits: UInt64=0,misses: UInt64=0,evictions: UInt64=0
    init?(maximumPayloadBytes: Int = 1_048_576) {
        let allowed=min(65_536,maximumPayloadBytes/MemoryLayout<Entry>.stride)
        guard allowed > 0 else { return nil }
        var count=1;while count <= allowed/2 { count *= 2 }
        self.count=count;payloadBytes=count*MemoryLayout<Entry>.stride
        rows=UnsafeMutablePointer<Entry>.allocate(capacity: count)
        rows.initialize(repeating: .init(key: 0,cost: 0),count: count)
    }
    deinit { rows.deinitialize(count: count);rows.deallocate() }
    func value(arc: Int,make: () -> Double) -> Double {
        guard arc >= 0,arc < Int(UInt32.max) else { return make() }
        let key=UInt32(arc)+1,slot=arc&(count-1)
        if rows[slot].key == key { hits += 1;return rows[slot].cost }
        misses += 1
        let cost=make()
        if rows[slot].key != 0 { evictions += 1 }
        rows[slot] = .init(key: key,cost: cost)
        return cost
    }
}
