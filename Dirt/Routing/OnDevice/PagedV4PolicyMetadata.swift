import Foundation

/// Source-bound compact policy data only. No graph construction or node/edge
/// table allocation. Valid metadata preserves native optional-field defaults;
/// malformed present avoidance rows fail instead of becoming an empty map.
nonisolated struct PagedV4PolicyMetadata {
    struct Limits {
        var maximumInputBytes = 256 * 1024
        var maximumBoxes = 4096
        var maximumRetainedNameBytes = 256 * 1024
        var maximumRetainedPayloadBytes = 768 * 1024
    }
    enum Failure: Error, Equatable { case invalidLimits, metadataLimit, malformedMetadata, identityMismatch }
    struct Resolved {
        let urbanCores: [UrbanCore.Box]
        let settlementWalls: [UrbanCore.Box]
        let scoredSettlements: [UrbanCore.Box]
    }
    let identity: PagedV4Core.Identity
    let regionID: String?
    let urbanCores: [UrbanCore.Box]
    let settlements: [UrbanCore.Box]
    let inputBytes: Int
    /// Actual array capacities plus retained UTF8 lengths. Object/allocator and
    /// temporary JSON decode overhead are separate from this payload accounting.
    let retainedPayloadBytes: Int

    init(core: PagedV4Core,limits: Limits = Limits(),
         cancelled: @escaping () -> Bool = { RoutingWorkContext.stopReason != nil }) throws {
        guard limits.maximumInputBytes > 0, limits.maximumInputBytes <= 2*1024*1024,
              limits.maximumBoxes >= 0, limits.maximumBoxes <= 65_536,
              limits.maximumRetainedNameBytes >= 0, limits.maximumRetainedPayloadBytes > 0 else {
            throw Failure.invalidLimits
        }
        let decoded = try core.withLegalQuery(cancelled: cancelled) { query -> (String?,[UrbanCore.Box],[UrbanCore.Box],Int,Int) in
            let length = try query.sectionLength(.metadata)
            guard length > 0, length <= limits.maximumInputBytes else { throw Failure.metadataLimit }
            var data = Data(); data.reserveCapacity(length)
            for offset in stride(from: 0,to: length,by: 65_536) {
                let lease = try query.sectionChunk(.metadata,offset: offset,count: min(65_536,length-offset))
                lease.withUnsafeBytes { data.append(contentsOf: $0) }
            }
            if cancelled() { throw RoutingPageError.cancelled }
            let parsed: Any
            do { parsed = try JSONSerialization.jsonObject(with: data) }
            catch { throw Failure.malformedMetadata }
            guard let object = parsed as? [String: Any] else { throw Failure.malformedMetadata }
            let region = object["regionId"] as? String ?? object["province"] as? String
            var namesBytes = region?.utf8.count ?? 0, boxCount = 0
            func boxes(_ key: String,_ fallbackName: String) throws -> [UrbanCore.Box] {
                guard let value = object[key], !(value is NSNull) else { return [] }
                guard let raw = value as? [[String: Any]] else { throw Failure.malformedMetadata }
                guard raw.count <= limits.maximumBoxes-boxCount else { throw Failure.metadataLimit }
                var rows: [UrbanCore.Box] = []; rows.reserveCapacity(raw.count)
                guard rows.capacity * MemoryLayout<UrbanCore.Box>.stride <= limits.maximumRetainedPayloadBytes else { throw Failure.metadataLimit }
                for row in raw {
                    if cancelled() { throw RoutingPageError.cancelled }
                    guard let minLat = row["minLat"] as? NSNumber, let maxLat = row["maxLat"] as? NSNumber,
                          let minLon = row["minLon"] as? NSNumber, let maxLon = row["maxLon"] as? NSNumber else {
                        throw Failure.malformedMetadata
                    }
                    let a = minLat.doubleValue,b = maxLat.doubleValue,c = minLon.doubleValue,d = maxLon.doubleValue
                    guard a.isFinite,b.isFinite,c.isFinite,d.isFinite,a <= b,c <= d else { throw Failure.malformedMetadata }
                    let name = String(describing: row["name"] ?? fallbackName)
                    guard name.utf8.count <= limits.maximumRetainedNameBytes-namesBytes else { throw Failure.metadataLimit }
                    namesBytes += name.utf8.count
                    rows.append(.init(minLat: a,maxLat: b,minLon: c,maxLon: d,name: name))
                }
                boxCount += rows.count
                return rows
            }
            let urban = try boxes("urbanCores","urban-core"), settlements = try boxes("settlements","settlement")
            let payload = (urban.capacity+settlements.capacity)*MemoryLayout<UrbanCore.Box>.stride + namesBytes
            guard namesBytes <= limits.maximumRetainedNameBytes,payload <= limits.maximumRetainedPayloadBytes else { throw Failure.metadataLimit }
            if cancelled() { throw RoutingPageError.cancelled }
            return (region,urban,settlements,length,payload)
        }
        identity = core.identity; regionID = decoded.0; urbanCores = decoded.1; settlements = decoded.2
        inputBytes = decoded.3; retainedPayloadBytes = decoded.4
    }
    func validate(for core: PagedV4Core,cancelled: @escaping () -> Bool = { RoutingWorkContext.stopReason != nil }) throws {
        guard core.identity == identity else { throw Failure.identityMismatch }
        try core.withLegalQuery(cancelled: cancelled) { _ in }
    }
    /// Exactly OnDeviceRouter.activeRidePreferences and its three box resolvers.
    /// Initial fuel ignores recreational preferences, as the native path does.
    func resolved(profile: RouteProfile,preferences: RidePreferences?,initialFuelApproach: Bool) -> Resolved {
        let active: RidePreferences?
        if !initialFuelApproach, let value = preferences, value.normalized != RidePreferences() { active = value.normalized }
        else { active = nil }
        if active?.avoidCities == false { return .init(urbanCores: [],settlementWalls: [],scoredSettlements: []) }
        return .init(urbanCores: urbanCores.isEmpty ? UrbanCore.boxes : urbanCores,
            settlementWalls: settlements,
            scoredSettlements: UrbanCore.settlementBoxes(embedded: settlements,regionId: regionID,profile: profile))
    }
}
