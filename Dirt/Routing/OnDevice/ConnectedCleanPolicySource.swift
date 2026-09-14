import CoreLocation
import Foundation

/// Scoped first-Clean policy view. Search owns profile/endpoint restrictions,
/// labels, global distance budget and actual incoming turn state separately.
nonisolated protocol ConnectedCleanPolicySource {
    var graphSHA256: String { get }
    func validate() throws
    func endpoint(node: Int,edge: Int) throws -> CLLocationCoordinate2D
    func roadTier(_ edge: Int) throws -> RoadTier
    func geometry(edge: Int,fromNode: Int) throws -> [CLLocationCoordinate2D]
    func allowed(edge: Int,fromNode: Int,toNode: Int,startEdge: Int,endEdge: Int,
        from: CLLocationCoordinate2D,to: CLLocationCoordinate2D,avoid: Set<String>,
        preferences: RidePreferences?,context: HopSearchContext) throws -> Bool
    func cost(edge: Int,fromNode: Int,toNode: Int,from: CLLocationCoordinate2D,to: CLLocationCoordinate2D,
        startHighway: Bool,endHighway: Bool,preferences: RidePreferences?,context: HopSearchContext,
        predecessorTier: () throws -> RoadTier?) throws -> Double
}
nonisolated struct ArrayConnectedCleanPolicySource: ConnectedCleanPolicySource {
    let graphSHA256: String
    private let router: OnDeviceRouter
    private let pack: GraphV2Pack
    init(pack: GraphV2Pack,graphSHA256: String) { self.pack = pack; self.graphSHA256 = graphSHA256; router = OnDeviceRouter(pack: pack) }
    func validate() throws { try RoutingWorkContext.check() }
    func endpoint(node: Int,edge: Int) throws -> CLLocationCoordinate2D {
        guard (0..<pack.nodeCount).contains(node),(0..<pack.undirectedEdgeCount).contains(edge),
              pack.edgeFrom?[edge] == Int32(node) || pack.edgeTo?[edge] == Int32(node) else { throw ConnectedCleanStage.Failure.invalidInput }
        return .init(latitude: Double(pack.nodeCoords[node*2+1]),longitude: Double(pack.nodeCoords[node*2]))
    }
    func roadTier(_ edge: Int) throws -> RoadTier { try pack.roadTier(edge) }
    func geometry(edge: Int,fromNode: Int) throws -> [CLLocationCoordinate2D] { try router.connectedRoadCoordinates(edge: edge,fromNode: fromNode) }
    func allowed(edge: Int,fromNode: Int,toNode: Int,startEdge: Int,endEdge: Int,
        from: CLLocationCoordinate2D,to: CLLocationCoordinate2D,avoid: Set<String>,
        preferences: RidePreferences?,context: HopSearchContext) throws -> Bool {
        var router = router; router.ridePreferences = preferences; router.sessionSeed = context.sessionSeed
        return try router.connectedCleanRoadAllowed(edge: edge,fromNode: fromNode,toNode: toNode,
            originEdge: startEdge,destinationEdge: endEdge,origin: from,destination: to,avoidEdgeIDs: avoid,context: context)
    }
    func cost(edge: Int,fromNode: Int,toNode: Int,from: CLLocationCoordinate2D,to: CLLocationCoordinate2D,
        startHighway: Bool,endHighway: Bool,preferences: RidePreferences?,context: HopSearchContext,
        predecessorTier: () throws -> RoadTier?) throws -> Double {
        var router = router; router.ridePreferences = preferences; router.sessionSeed = context.sessionSeed
        return try router.connectedCleanRoadCost(edge: edge,fromNode: fromNode,toNode: toNode,
            origin: from,destination: to,originOnHighway: startHighway,destinationOnHighway: endHighway,
            predecessorTier: predecessorTier,context: context)
    }
}
/// Prepared file readers have bounded caches. No GraphV2Pack is constructed.
/// Bundle ownership must remain bounded by the source/window manager.
/// Prepare readers and enter this scope inside the caller's existing
/// RoutingWorkContext deadline; neither construction nor access renews it.
nonisolated final class PagedConnectedCleanPolicyBundle {
    let core: PagedV4Core, details: PagedEdgeDetail
    let metadata: PagedV4PolicyMetadata, leaves: PagedCleanPolicyReadAccess.Metadata
    let geometry: GeometryV1Pack, snap: ExactSnapIndex
    init(core: PagedV4Core,details: PagedEdgeDetail,metadata: PagedV4PolicyMetadata,
         geometryURL: URL,geometryIdentity: GeometryV1Pack.Identity,snapIndexURL: URL) throws {
        try RoutingWorkContext.check()
        guard let detailID = details.identity, detailID.sha256 == core.identity.sha256,
              detailID.bytes == core.identity.bytes else { throw PagedV4Core.Failure.identityMismatch }
        try metadata.validate(for: core)
        try core.withLegalQuery(cancelled: { RoutingWorkContext.stopReason != nil }) { legal in
            let lease = try legal.sectionChunk(.geometryHash,offset: 0,count: 32)
            let hash = lease.withUnsafeBytes { $0.map { String(format: "%02x",$0) }.joined() }
            guard hash == geometryIdentity.sha256 else { throw PagedV4Core.Failure.identityMismatch }
        }
        self.core = core; self.details = details; self.metadata = metadata
        leaves = try .init(core: core)
        geometry = try .init(url: geometryURL,identity: geometryIdentity,expectedEdgeCount: core.edgeCount,
            cancelled: { RoutingWorkContext.stopReason != nil })
        snap = try .init(url: snapIndexURL,identity: .init(graphSHA256: core.identity.sha256,graphBytes: core.identity.bytes,
            geometrySHA256: geometryIdentity.sha256,geometryBytes: geometryIdentity.bytes),cancelled: { RoutingWorkContext.stopReason != nil })
        try RoutingWorkContext.check()
    }
    func withPolicy<T>(query: PagedV4Core.Query,_ body: (any ConnectedCleanPolicySource) throws -> T) throws -> T {
        guard query.belongs(to: core) else { throw PagedV4Core.Failure.identityMismatch }
        return try details.withQuery(cancelled: { RoutingWorkContext.stopReason != nil }) { detailQuery in
            try snap.withBoundsQuery(cancelled: { RoutingWorkContext.stopReason != nil }) { bounds in
                let policy = try PagedConnectedCleanPolicySource(bundle: self,query: query,detailQuery: detailQuery,bounds: bounds)
                let result = try body(policy)
                try policy.validate(); return result
            }
        }
    }
}
private nonisolated struct PagedConnectedCleanPolicySource: ConnectedCleanPolicySource {
    let bundle: PagedConnectedCleanPolicyBundle
    let query: PagedV4Core.Query, detailQuery: PagedEdgeDetail.Query
    let bounds: ExactSnapIndex.BoundsQuery
    let leaf: PagedCleanPolicyReadAccess
    var graphSHA256: String { bundle.core.identity.sha256 }
    init(bundle: PagedConnectedCleanPolicyBundle,query: PagedV4Core.Query,
         detailQuery: PagedEdgeDetail.Query,bounds: ExactSnapIndex.BoundsQuery) throws {
        self.bundle = bundle; self.query = query; self.detailQuery = detailQuery; self.bounds = bounds
        leaf = try .init(metadata: bundle.leaves,details: bundle.details,query: detailQuery)
    }
    func validate() throws {
        try RoutingWorkContext.check(); try query.validateSource()
        try bundle.geometry.validateSource(cancelled: { RoutingWorkContext.stopReason != nil })
        guard detailQuery.belongs(to: bundle.details) else { throw PagedEdgeDetail.Failure.queryClosed }
    }
    private func point(_ node: Int) throws -> CLLocationCoordinate2D {
        let row = try query.node(node); return .init(latitude: Double(row.latitude),longitude: Double(row.longitude))
    }
    func endpoint(node: Int,edge: Int) throws -> CLLocationCoordinate2D {
        let row = try query.edge(edge)
        guard row.from == node || row.to == node else { throw ConnectedCleanStage.Failure.invalidInput }
        return try point(node)
    }
    func roadTier(_ edge: Int) throws -> RoadTier { try leaf.roadTier(edge) }
    func geometry(edge: Int,fromNode: Int) throws -> [CLLocationCoordinate2D] {
        let row = try query.edge(edge)
        guard row.from == fromNode || row.to == fromNode else { throw PagedV4Core.Failure.invalidTopology }
        let shape = try bundle.geometry.polyline(edgeIndex: edge,forward: row.from == fromNode)
        guard shape.count >= 2 else { throw ConnectedCleanStage.Failure.incomplete("geometryUnavailable") }
        return shape
    }
    func allowed(edge: Int,fromNode: Int,toNode: Int,startEdge: Int,endEdge: Int,
        from: CLLocationCoordinate2D,to: CLLocationCoordinate2D,avoid: Set<String>,
        preferences: RidePreferences?,context: HopSearchContext) throws -> Bool {
        guard context.profile == .cleanest else { throw ConnectedCleanStage.Failure.unsupported("Only Clean access is implemented") }
        let row = try query.edge(edge)
        guard (row.from == fromNode && row.to == toNode) || (row.to == fromNode && row.from == toNode) else { throw PagedV4Core.Failure.invalidTopology }
        let code = row.from == fromNode && row.to == toNode ? row.forwardAccess : row.reverseAccess
        if !NativeV4AccessPolicy.allowed(code: code,edge: edge,startEdge: startEdge,endEdge: endEdge,
            allowUnknown: false,startEndpointKind: nil,endEndpointKind: nil,
            customerStartEdges: context.customerStartEdges,customerEndEdges: context.customerEndEdges) { return false }
        if edge != startEdge && edge != endEdge && !context.customerStartEdges.contains(edge) && !context.customerEndEdges.contains(edge) {
            if try RoadTierStats.isBlockedForCleanLeaf(family: leaf.surfaceFamily(edge),tier: leaf.roadTier(edge),
                pavedOnly: context.pavedOnly,isEndpointEdge: false) { return false }
        }
        let id = try query.edgeID(edge)
        if !id.isEmpty, avoid.contains(id) { return false }
        let boxes = bundle.metadata.resolved(profile: .cleanest,preferences: preferences,initialFuelApproach: false)
        return try !NativeRoadBlockPolicy.blocked(point(toNode),edgeFrom: point(fromNode),edgeIndex: edge,
            from: from,to: to,ctx: context,sourceIdentity: bundle,hasGeometry: true,
            urbanCores: { boxes.urbanCores },settlements: { boxes.settlementWalls },
            boundsMayIntersect: { edge,box in
                let radius = 110_000 * max((box.maxLat-box.minLat)/2,(box.maxLon-box.minLon)/2)
                return try bundle.snap.mayIntersect(edge: edge,latitude: (box.minLat+box.maxLat)/2,
                    longitude: (box.minLon+box.maxLon)/2,meters: radius,query: bounds,
                    cancelled: { RoutingWorkContext.stopReason != nil })
            },geometryForEdge: { try bundle.geometry.polyline(edgeIndex: $0) })
    }
    func cost(edge: Int,fromNode: Int,toNode: Int,from: CLLocationCoordinate2D,to: CLLocationCoordinate2D,
        startHighway: Bool,endHighway: Bool,preferences: RidePreferences?,context: HopSearchContext,
        predecessorTier: () throws -> RoadTier?) throws -> Double {
        guard context.profile == .cleanest, context.costMode == .profile else { throw ConnectedCleanStage.Failure.unsupported("Only first Clean profile cost is implemented") }
        let row = try query.edge(edge), pointTo = try point(toNode), pointFrom = try point(fromNode)
        guard (row.from == fromNode && row.to == toNode) || (row.to == fromNode && row.from == toNode) else { throw PagedV4Core.Failure.invalidTopology }
        func meters(_ a: CLLocationCoordinate2D,_ b: CLLocationCoordinate2D) -> Double {
            CLLocation(latitude: a.latitude,longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude,longitude: b.longitude))
        }
        let id = try query.edgeID(edge)
        let active = preferences.flatMap { $0.normalized == RidePreferences() ? nil : $0.normalized }
        let boxes = bundle.metadata.resolved(profile: .cleanest,preferences: preferences,initialFuelApproach: false)
        let away = OnDeviceProfileCosts.approachAwayExtra(profile: .cleanest,dFromMeters: meters(pointFrom,to),
            dToMeters: meters(pointTo,to),abMeters: meters(from,to),regionId: bundle.metadata.regionID)
        return try NativeFullRoadPolicy.step(baseCost: {
            try NativeCleanProfileStep.cost(read: leaf,edge: edge,attributes: row.attributes,meters: Double(row.meters),
                ctx: context,toLL: pointTo,endLL: to,projectedOrigin: from,startOnMajorHighway: startHighway,
                endOnMajorHighway: endHighway,activePreferences: active)
        },meters: Double(row.meters),attributes: row.attributes,profile: .cleanest,ctx: context,toLL: pointTo,
            edgeFrom: pointFrom,from: from,to: to,endLL: to,projectedOrigin: from,
            startOnMajorHighway: startHighway,endOnMajorHighway: endHighway,awayExtraMeters: away,
            applySoftCorridor: false,hasLeaves: true,initialFuelApproach: false,
            urbanCores: { boxes.urbanCores },settlementBoxes: { boxes.scoredSettlements },
            backtrack: { cost in
                guard !id.isEmpty else { return cost }
                if id == context.arrivalEdgeId { return cost*12 }
                if context.priorEdgeIds.contains(id) { return cost*max(active?.preferDifferentRoads == true ? 16 : 1,context.backtrackFactor) }
                return cost
            },currentTier: { try leaf.roadTier(edge) },predecessorTier: predecessorTier)
    }
}
