import CoreLocation
import Foundation

/// Request-owned memo of the full-edge urban-wall predicate only. Table
/// collisions discard proofs and recompute; no route/state labels live here.
nonisolated final class UrbanEdgeMemo: @unchecked Sendable {
    private struct Entry { var key: UInt32; var blocked: UInt8 }
    private let owner: AnyObject
    private let fromLat: Double,fromLon: Double,toLat: Double,toLon: Double
    let boxes: [UrbanCore.Box]
    let payloadBytes: Int
    private let count: Int
    private let rows: UnsafeMutablePointer<Entry>
    private let lock=NSLock()
    private var hits: UInt64=0,misses: UInt64=0,evictions: UInt64=0
    init?(owner: AnyObject,from: CLLocationCoordinate2D,to: CLLocationCoordinate2D,
        boxes: [UrbanCore.Box],maximumPayloadBytes: Int = 1_048_576) {
        let filtered=boxes.filter { !$0.contains(from) && !$0.contains(to) }
        guard !filtered.isEmpty else { return nil }
        let permitted=maximumPayloadBytes/MemoryLayout<Entry>.stride
        guard permitted > 0 else { return nil }
        var count=1
        while count <= min(permitted,131_072)/2 { count *= 2 }
        self.count=count;payloadBytes=count*MemoryLayout<Entry>.stride
        self.owner=owner;fromLat=from.latitude;fromLon=from.longitude;toLat=to.latitude;toLon=to.longitude
        self.boxes=filtered
        rows=UnsafeMutablePointer<Entry>.allocate(capacity: count)
        rows.initialize(repeating: .init(key: 0,blocked: 0),count: count)
    }
    deinit { rows.deinitialize(count: count);rows.deallocate() }
    func matches(owner: AnyObject,from: CLLocationCoordinate2D,to: CLLocationCoordinate2D) -> Bool {
        self.owner === owner && fromLat == from.latitude && fromLon == from.longitude
            && toLat == to.latitude && toLon == to.longitude
    }
    func value(edge: Int,shouldStore: () -> Bool = { true },compute: () throws -> Bool) rethrows -> Bool {
        guard edge >= 0,edge < Int(UInt32.max) else { return try compute() }
        let key=UInt32(edge)+1,slot=edge&(count-1)
        lock.lock()
        if rows[slot].key == key {
            let result=rows[slot].blocked != 0;hits += 1;lock.unlock();return result
        }
        misses += 1;lock.unlock()
        let result=try compute() // Cancellation/read failures never become proofs.
        guard shouldStore() else { return result }
        lock.lock()
        if rows[slot].key != 0,rows[slot].key != key { evictions += 1 }
        rows[slot] = .init(key: key,blocked: result ? 1:0)
        lock.unlock()
        return result
    }
    func recordMeasurements(_ measurement: RoutingMeasurement?) {
        lock.lock();let h=hits,m=misses,e=evictions;hits=0;misses=0;evictions=0;lock.unlock()
        measurement?.increment(.urbanMemoHits,by: h)
        measurement?.increment(.urbanMemoMisses,by: m)
        measurement?.increment(.urbanMemoEvictions,by: e)
    }
}
