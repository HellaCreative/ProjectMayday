import Foundation

/// One build's most recent completed forward vector. No graph/field owners or
/// speculative hints. Ordered input identity is compared byte-for-byte.
@MainActor
final class FuelReachabilityReuse {
    struct Request {
        let from: RouteCoordinate, toward: RouteCoordinate
        let pumps: [POIFeature]
        let maximumMeters: Double
        let profile: RouteProfile
        let allowUnknown: Bool
    }
    private struct Entry { let key: [UInt8]; let values: [Double] }
    private var entry: Entry?
    let maximumPayloadBytes: Int
    private(set) var hits = 0
    private(set) var retainedPayloadBytes = 0
    init(maximumPayloadBytes: Int = 1_048_576) { self.maximumPayloadBytes = max(0,maximumPayloadBytes) }

    private func key(_ request: Request,_ identity: String) -> [UInt8]? {
        guard !identity.isEmpty,request.maximumMeters.isFinite,request.maximumMeters > 0,
              request.pumps.count <= maximumPayloadBytes/8 else { return nil }
        var bytes: [UInt8] = []
        func word(_ value: UInt64) -> Bool {
            guard bytes.count <= maximumPayloadBytes-8 else { return false }
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
            return bytes.capacity <= maximumPayloadBytes
        }
        func string(_ value: String) -> Bool {
            let length = value.utf8.count
            guard length <= maximumPayloadBytes,word(UInt64(length)),bytes.count <= maximumPayloadBytes-length else { return false }
            bytes.append(contentsOf: value.utf8)
            return bytes.capacity <= maximumPayloadBytes
        }
        func point(_ x: Double,_ y: Double) -> Bool { x.isFinite && y.isFinite && word(x.bitPattern) && word(y.bitPattern) }
        guard string(identity),string(request.profile.rawValue),word(request.allowUnknown ? 1 : 0),
              point(request.from.longitude,request.from.latitude),point(request.toward.longitude,request.toward.latitude),
              word(request.maximumMeters.bitPattern),word(UInt64(request.pumps.count)) else { return nil }
        for pump in request.pumps {
            if !string(pump.id) || !point(pump.longitude,pump.latitude) { return nil }
        }
        return bytes
    }
    func resolve(_ request: Request,currentIdentity: () -> String,
        check: () throws -> Void = { try RoutingWorkContext.check() },
        load: () async throws -> [String: Double]) async throws -> [String: Double] {
        try check()
        let identity = currentIdentity(),candidateKey = key(request,identity)
        if let candidateKey,let old = entry,old.key == candidateKey {
            try check()
            guard currentIdentity() == identity else { entry = nil;retainedPayloadBytes = 0;throw RoutingPageError.sourceChanged }
            var result: [String: Double] = [:]
            for (pump,value) in zip(request.pumps,old.values) where value.isFinite { result[pump.id] = value }
            try check();hits += 1
            RoutingDebugLog.shared.event("fuel forward vector reuse accepted stations=\(result.count)")
            return result
        }
        // A failed attempt cannot leave an earlier vector available for retry.
        entry = nil;retainedPayloadBytes = 0
        let result = try await load()
        try check()
        // Preparation may legitimately activate another installed region. The
        // loader still owns validation; identity changes simply prevent reuse.
        guard currentIdentity() == identity else { return result }
        // Empty legacy responses conflate absent preparation and zero matches.
        // Preserve behavior but never turn that ambiguity into a cached proof.
        guard let candidateKey,!result.isEmpty,
              candidateKey.capacity <= maximumPayloadBytes,
              request.pumps.count <= (maximumPayloadBytes-candidateKey.capacity)/MemoryLayout<Double>.stride else { return result }
        var values = [Double](repeating: .nan,count: request.pumps.count)
        for (index,pump) in request.pumps.enumerated() {
            if let value = result[pump.id] {
                guard value.isFinite,value >= 0,value <= request.maximumMeters else { return result }
                values[index] = value
            }
        }
        // Reject unexpected output keys instead of dropping them on reuse.
        guard result.keys.allSatisfy({ id in request.pumps.contains { $0.id == id } }) else { return result }
        let payload = candidateKey.capacity + values.capacity*MemoryLayout<Double>.stride
        guard payload <= maximumPayloadBytes else { return result }
        try check()
        guard currentIdentity() == identity else { return result }
        entry = .init(key:candidateKey,values:values);retainedPayloadBytes = payload
        return result
    }
}
nonisolated enum FuelReachabilityReuseScope {
    @TaskLocal static var current: FuelReachabilityReuse?
}
