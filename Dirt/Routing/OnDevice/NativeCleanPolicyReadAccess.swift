import CoreLocation
import Foundation

/// Small first slice of native policy reads. Does not implement legal access,
/// geometry/town exclusion, full-road outer penalties, matching or profile choice.
nonisolated protocol NativeCleanPolicyReadAccess {
    func crossingSeconds(_ edge: Int) throws -> UInt32
    func roadTier(_ edge: Int) throws -> RoadTier
    func surfaceFamily(_ edge: Int) throws -> SurfaceFamily
    func roadClassName(_ edge: Int) throws -> String
}
nonisolated struct ArrayCleanPolicyReadAccess: NativeCleanPolicyReadAccess {
    let pack: GraphV2Pack
    let query: PagedEdgeDetail.Query?
    func crossingSeconds(_ edge: Int) throws -> UInt32 { try pack.crossingSeconds(edge,query: query) }
    func roadTier(_ edge: Int) throws -> RoadTier { try pack.roadTier(edge,query: query) }
    func surfaceFamily(_ edge: Int) throws -> SurfaceFamily { try pack.surfaceFamily(edge,query: query) }
    func roadClassName(_ edge: Int) throws -> String {
        if let name = try pack.roadClassLeaf(edge,query: query) { return name }
        return GraphV2Pack.roadClassName(GraphV2Pack.unpackRoadClass(pack.edgeAttrs[edge]))
    }
}
nonisolated struct PagedCleanPolicyReadAccess: NativeCleanPolicyReadAccess {
    enum Failure: Error, Equatable { case identityMismatch, metadataLimit, invalidMetadata }
    struct Metadata {
        let identity: PagedV4Core.Identity
        let surfaceNames: [String], roadNames: [String]
        let familyMap: [String: SurfaceFamily], tierMap: [String: RoadTier]
        /// Input cap bounds compact decoding, not allocator/RSS measurement.
        let sourceBytes: Int
        init(core: PagedV4Core, cancelled: @escaping () -> Bool = { RoutingWorkContext.stopReason != nil }) throws {
            let bytes = try core.withLegalQuery(cancelled: cancelled) { query -> Data in
                let count = try query.sectionLength(.enums)
                guard count <= 65_536 else { throw Failure.metadataLimit }
                let lease = try query.sectionChunk(.enums,offset: 0,count: count)
                return lease.withUnsafeBytes { Data($0) }
            }
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let surfaceNames = object["surfaceLeafNames"] as? [String],
                  let roadNames = object["roadClassLeafNames"] as? [String],
                  !surfaceNames.isEmpty, !roadNames.isEmpty,
                  surfaceNames.count <= 256,roadNames.count <= 256 else { throw Failure.invalidMetadata }
            if let raw = object["surfaceFamilyMap"] {
                guard let map = raw as? [String: String], map.values.allSatisfy({ SurfaceFamily(rawValue: $0.lowercased()) != nil }) else { throw Failure.invalidMetadata }
            }
            if let raw = object["roadTierMap"] {
                guard let map = raw as? [String: String], map.values.allSatisfy({ RoadTier(rawValue: $0.lowercased()) != nil }) else { throw Failure.invalidMetadata }
            }
            if cancelled() { throw RoutingPageError.cancelled }
            // Parsing happens after obtaining owned bytes. Validate the source
            // again before publishing metadata, including cancellation after parse.
            try core.withLegalQuery(cancelled: cancelled) { _ in }
            self.identity = core.identity; self.surfaceNames = surfaceNames; self.roadNames = roadNames
            familyMap = SurfaceFamilyStats.parseFamilyMap(object["surfaceFamilyMap"])
            tierMap = RoadTierStats.parseTierMap(object["roadTierMap"])
            sourceBytes = bytes.count
        }
    }
    let metadata: Metadata
    private let details: PagedEdgeDetail
    private let query: PagedEdgeDetail.Query
    init(metadata: Metadata,details: PagedEdgeDetail,query: PagedEdgeDetail.Query) throws {
        guard let identity = details.identity, identity.sha256 == metadata.identity.sha256,
              identity.bytes == metadata.identity.bytes, query.belongs(to: details) else { throw Failure.identityMismatch }
        self.metadata = metadata; self.details = details; self.query = query
        // Subsequent value reads also enforce query ownership and closed scope.
    }
    private func value(_ field: PagedEdgeDetail.Field,_ edge: Int) throws -> UInt32? {
        try details.value(field,at: edge,using: query)
    }
    func crossingSeconds(_ edge: Int) throws -> UInt32 { try value(.crossingSeconds,edge) ?? 0 }
    func roadClassName(_ edge: Int) throws -> String {
        guard let code = try value(.roadClass,edge) else { throw Failure.invalidMetadata }
        let index = Int(code)
        if index == 0 { return "unknown" }
        guard metadata.roadNames.indices.contains(index) else { throw Failure.invalidMetadata }
        return metadata.roadNames[index]
    }
    func roadTier(_ edge: Int) throws -> RoadTier {
        try RoadTierStats.tier(of: roadClassName(edge),map: metadata.tierMap)
    }
    func surfaceFamily(_ edge: Int) throws -> SurfaceFamily {
        guard let code = try value(.surface,edge) else { throw Failure.invalidMetadata }
        let index = Int(code)
        if index == 0 { return .unknown }
        guard metadata.surfaceNames.indices.contains(index) else { throw Failure.invalidMetadata }
        let name: String? = metadata.surfaceNames[index]
        return SurfaceFamilyStats.family(of: name,map: metadata.familyMap)
    }
}
nonisolated enum NativeCleanProfileStep {
    enum Failure: Error { case unsupportedContext }
    /// Exact extraction of native Clean/profile base step, including ferry's
    /// early return. Caller retains fullRealRoadStep's original outer sequence.
    static func cost<R: NativeCleanPolicyReadAccess>(read: R,edge: Int,attributes: UInt16,
        meters edgeMeters: Double,ctx: HopSearchContext,toLL: CLLocationCoordinate2D,
        endLL: CLLocationCoordinate2D,projectedOrigin: CLLocationCoordinate2D,
        startOnMajorHighway: Bool,endOnMajorHighway: Bool,
        activePreferences: RidePreferences?) throws -> Double {
        guard ctx.profile == .cleanest, ctx.costMode == .profile else { throw Failure.unsupportedContext }
        func meters(_ a: CLLocationCoordinate2D,_ b: CLLocationCoordinate2D) -> Double {
            CLLocation(latitude: a.latitude,longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude,longitude: b.longitude))
        }
        func preference(_ base: Double) throws -> Double {
            guard let preferences = activePreferences else { return base }
            return try NativeRidePreferenceCosts.edgeCost(base: base,meters: edgeMeters,
                roadClass: read.roadClassName(edge),preferences: preferences)
        }
        if GraphV2Pack.isFerryStructure(GraphV2Pack.unpackStructure(attributes)) {
            let sec = OnDeviceProfileCosts.ferryCrossingSeconds(distanceMeters: edgeMeters,
                storedSeconds: try read.crossingSeconds(edge))
            return try preference(OnDeviceProfileCosts.ferryRelaxStepCost(crossingSeconds: sec))
        }
        let km = edgeMeters / 1000.0
        let tier = try read.roadTier(edge)
        let family = try read.surfaceFamily(edge)
        var step = km * RoadTierStats.cleanLeafCostMult(tier: tier,family: family)
        step *= RoadTierStats.e4LeafCostMult(tier: tier,avoidMotorways: ctx.avoidMotorways,
            preferBackRoads: ctx.preferBackRoads,metersFromStart: meters(toLL,projectedOrigin),
            metersToDestination: meters(toLL,endLL),startOnHighway: startOnMajorHighway,endOnHighway: endOnMajorHighway)
        return try preference(step)
    }
}
