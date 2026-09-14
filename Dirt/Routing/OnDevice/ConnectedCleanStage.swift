import CoreLocation
import Foundation

/// Unactivated single Clean pass on exact recorded nodes. No profile substitution,
/// fallback orchestration, tap matching, customer access or fractional connectors.
/// Unlike serial hop winners, every prefix competes under ONE stage metre cap.
nonisolated enum ConnectedCleanStage {
    struct Endpoint { let pack: Int; let node: Int; let matchedEdge: Int }
    struct Limits {
        var maximumLabels = 8192
        var maximumQueueEntries = 16384
        var maximumPayloadBytes = 8 * 1024 * 1024
        var maximumPops = 100_000
        var maximumGeometryPoints = 200_000
        var timeBudgetMilliseconds = 18_000
    }
    struct Result {
        let roads: [ConnectedPackStageView.Traversal]
        let coordinates: [CLLocationCoordinate2D]
        let meters: Double
        let cost: Double
        let limitation: String?
        let acceptedLabels: Int
        let poppedLabels: Int
        let accountedPeakPayloadBytes: Int
    }
    enum Failure: Error { case unsupported(String), incomplete(String), resourceLimit, cancelled, invalidInput }
    private struct Record {
        let cursor: ConnectedPackStageView.Cursor
        let predecessor: Int
        let historyID: Int
        let road: ConnectedPackStageView.Traversal?
    }
    private struct QueueItem { let label: Int; let cost: Double }

    static func calculate(view: ConnectedPackStageView, origin: Endpoint, destination: Endpoint,
        profile: RouteProfile, maxMeters: Double, context: HopSearchContext,
        ridePreferences: RidePreferences? = nil, avoidEdgeIDs: Set<String> = [],
        limits: Limits = Limits()) throws -> Result {
        guard profile == .cleanest, context.profile == .cleanest,
              context.costMode == .profile, context.cityWall, context.pavedOnly,
              !context.variety, context.noBacktrack, context.priorEdgeIds.isEmpty,
              context.arrivalEdgeId == nil, context.customerStartEdges.isEmpty,
              context.customerEndEdges.isEmpty, context.roadRemaining == nil,
              context.urbanEdgeMemo == nil, context.maxPathMeters == nil,
              context.calculationDeadline == nil else { throw Failure.unsupported("Only ordinary-endpoint first Clean pass is implemented") }
        guard maxMeters.isFinite, maxMeters > 0, limits.maximumLabels > 0, limits.maximumLabels <= 65_536,
              limits.maximumQueueEntries > 0, limits.maximumQueueEntries <= 131_072, limits.maximumPops > 0,
              limits.maximumGeometryPoints > 0, limits.maximumGeometryPoints <= 1_000_000,
              limits.timeBudgetMilliseconds > 0,
              limits.timeBudgetMilliseconds <= 18_000 else { throw Failure.invalidInput }
        let deadline = RoutingWorkContext.limitedDeadline(milliseconds: limits.timeBudgetMilliseconds)
        return try RoutingWorkContext.$deadline.withValue(deadline) {
            try run(view: view, origin: origin, destination: destination,
                maxMeters: maxMeters, context: context, ridePreferences: ridePreferences,
                avoidEdgeIDs: avoidEdgeIDs, limits: limits)
        }
    }

    private static func run(view: ConnectedPackStageView, origin: Endpoint, destination: Endpoint,
        maxMeters: Double, context: HopSearchContext, ridePreferences: RidePreferences?,
        avoidEdgeIDs: Set<String>, limits: Limits) throws -> Result {
        func check() throws { try RoutingWorkContext.check() }
        try check()
        let originPack = try view.sourcePack(origin.pack), destinationPack = try view.sourcePack(destination.pack)
        func endpoint(_ value: Endpoint, pack: GraphV2Pack) throws -> CLLocationCoordinate2D {
            guard value.node >= 0, value.node < pack.nodeCount,
                  value.matchedEdge >= 0, value.matchedEdge < pack.undirectedEdgeCount,
                  pack.edgeFrom?[value.matchedEdge] == Int32(value.node) || pack.edgeTo?[value.matchedEdge] == Int32(value.node)
            else { throw Failure.invalidInput }
            return .init(latitude: Double(pack.nodeCoords[value.node * 2 + 1]), longitude: Double(pack.nodeCoords[value.node * 2]))
        }
        let from = try endpoint(origin, pack: originPack), to = try endpoint(destination, pack: destinationPack)
        func highway(_ pack: GraphV2Pack, _ edge: Int) throws -> Bool {
            let tier = try pack.roadTier(edge)
            return tier == .motorway || tier == .trunk || tier == .arterial
        }
        let fromHighway = try highway(originPack, origin.matchedEdge), toHighway = try highway(destinationPack, destination.matchedEdge)
        let nominalMetadata = limits.maximumLabels * MemoryLayout<Record?>.stride
            + limits.maximumQueueEntries * MemoryLayout<QueueItem>.stride
        guard nominalMetadata < limits.maximumPayloadBytes else { throw Failure.resourceLimit }
        var records = [Record?](repeating: nil, count: limits.maximumLabels)
        var queue = [QueueItem](repeating: .init(label: 0, cost: 0), count: limits.maximumQueueEntries)
        let metadataBytes = records.capacity * MemoryLayout<Record?>.stride + queue.capacity * MemoryLayout<QueueItem>.stride
        guard metadataBytes < limits.maximumPayloadBytes else { throw Failure.resourceLimit }
        var labelLimits = ConnectedCostLengthLabels.Limits()
        labelLimits.maximumLabels = limits.maximumLabels
        labelLimits.maximumPayloadBytes = limits.maximumPayloadBytes - metadataBytes
        let labels = try ConnectedCostLengthLabels(limits: labelLimits, cancelled: { RoutingWorkContext.stopReason != nil })
        var queueCount = 0, pops = 0
        var incumbent: Int?
        var limitation: String?
        var unsupportedOriginTransfer = false
        var peakPayload = metadataBytes + labels.accountedPayloadBytes
        var liveHistoryPayload = 0
        func push(_ item: QueueItem) throws {
            guard queueCount < queue.count else { throw Failure.resourceLimit }
            var index = queueCount; queueCount += 1; queue[index] = item
            while index > 0 {
                let parent = (index - 1) >> 1
                if queue[parent].cost <= queue[index].cost { break }
                queue.swapAt(parent,index); index = parent
            }
        }
        func pop() -> QueueItem? {
            guard queueCount > 0 else { return nil }
            let result = queue[0]; queueCount -= 1
            if queueCount == 0 { return result }
            queue[0] = queue[queueCount]; var index = 0
            while true {
                let left = index * 2 + 1, right = left + 1
                var smallest = index
                if left < queueCount && queue[left].cost < queue[smallest].cost { smallest = left }
                if right < queueCount && queue[right].cost < queue[smallest].cost { smallest = right }
                if smallest == index { break }
                queue.swapAt(index,smallest); index = smallest
            }
            return result
        }
        func insert(cursor: ConnectedPackStageView.Cursor, predecessor: Int,
                    road: ConnectedPackStageView.Traversal?, cost: Double, meters: Double) throws {
            let arrival = ConnectedCostLengthLabels.Arrival(pack: cursor.pack,
                turnState: cursor.turnState, incomingRoad: cursor.incomingEdge)
            // Advance conservative identity only when a real road is traversed.
            // Storage-only seam transfer retains identity, so A→B→A equal labels
            // are dominated rather than creating infinitely new path histories.
            let historyID: Int
            if road != nil { historyID = labels.count + 1 }
            else { historyID = predecessor >= 0 ? (records[predecessor]?.historyID ?? 0) : 0 }
            let nextPage = labels.count % labelLimits.pageCapacity == 0
                ? min(labelLimits.pageCapacity, limits.maximumLabels - labels.count)
                    * MemoryLayout<ConnectedCostLengthLabels.Label>.stride : 0
            guard metadataBytes + labels.accountedPayloadBytes + liveHistoryPayload + nextPage <= limits.maximumPayloadBytes else { throw Failure.resourceLimit }
            let added = try labels.insert(arrival: arrival, history: historyID,
                cost: cost, meters: meters, predecessor: predecessor)
            guard case .accepted(let id) = added else { return }
            records[id] = .init(cursor: cursor, predecessor: predecessor, historyID: historyID, road: road)
            if cursor.pack == destination.pack, try view.node(cursor) == destination.node {
                if let previous = incumbent {
                    if cost < (try labels.label(previous).cost) { incumbent = id }
                } else { incumbent = id }
            }
            try push(.init(label: id, cost: cost))
        }
        try insert(cursor: .init(pack: origin.pack, turnState: origin.node, incomingEdge: -1, arrivedFrom: -1),
            predecessor: -1, road: nil, cost: 0, meters: 0)
        do {
            while let entry = pop() {
                try check(); pops += 1
                guard pops <= limits.maximumPops else { throw Failure.resourceLimit }
                let label = try labels.label(entry.label)
                if !label.isActive { continue }
                guard let record = records[entry.label] else { throw Failure.invalidInput }
                if entry.label == incumbent { break }
                let pack = try view.sourcePack(record.cursor.pack)
                var router = OnDeviceRouter(pack: pack)
                router.ridePreferences = ridePreferences
                router.sessionSeed = context.sessionSeed
                var priorRoad: ConnectedPackStageView.Traversal?
                let scratchBudget = labels.count * MemoryLayout<ConnectedPackStageView.CanonicalRoad>.stride * 2
                guard metadataBytes + labels.accountedPayloadBytes + scratchBudget <= limits.maximumPayloadBytes else { throw Failure.resourceLimit }
                var history = entry.label
                var usedRoads: [ConnectedPackStageView.CanonicalRoad] = []
                usedRoads.reserveCapacity(labels.count)
                // These temporary histories are bounded by labels; scratch payload
                // is separately checked below and never retained for every label.
                while history >= 0 {
                    try check()
                    guard let previous = records[history] else { throw Failure.invalidInput }
                    if let road = previous.road {
                        if priorRoad == nil { priorRoad = road }
                        usedRoads.append(try view.canonicalRoad(road.road))
                    }
                    history = previous.predecessor
                }
                let historyPayload = usedRoads.capacity * MemoryLayout<ConnectedPackStageView.CanonicalRoad>.stride
                guard metadataBytes + labels.accountedPayloadBytes + historyPayload <= limits.maximumPayloadBytes else { throw Failure.resourceLimit }
                liveHistoryPayload = historyPayload
                peakPayload = max(peakPayload, metadataBytes + labels.accountedPayloadBytes + historyPayload)
                try view.outgoing(record.cursor) { road in
                    let canonical = try view.canonicalRoad(road.road)
                    if usedRoads.contains(canonical) { return } // Full-real-edge PathRetrace overlap.
                    let meters = label.meters + road.meters
                    if meters > maxMeters { return }
                    if try !router.connectedCleanRoadAllowed(edge: road.road.edge, fromNode: road.from, toNode: road.to,
                        originEdge: record.cursor.pack == origin.pack ? origin.matchedEdge : -1,
                        destinationEdge: record.cursor.pack == destination.pack ? destination.matchedEdge : -1,
                        origin: from, destination: to, avoidEdgeIDs: avoidEdgeIDs, context: context) { return }
                    let step = try router.connectedCleanRoadCost(edge: road.road.edge, fromNode: road.from, toNode: road.to,
                        origin: from, destination: to, originOnHighway: fromHighway, destinationOnHighway: toHighway,
                        predecessorTier: {
                            guard let priorRoad else { return nil }
                            return try view.sourcePack(priorRoad.road.pack).roadTier(priorRoad.road.edge)
                        }, context: context)
                    guard step.isFinite, step >= 0 else { throw Failure.invalidInput }
                    try insert(cursor: road.destination, predecessor: entry.label, road: road,
                        cost: label.cost + step, meters: meters)
                }
                if record.predecessor < 0 && record.cursor.incomingEdge < 0 {
                    // An unarrived origin has no legal incoming token to export.
                    // Continue local roads, but disclose the unsearched transfer.
                    unsupportedOriginTransfer = try view.hasPortal(record.cursor)
                } else {
                    for cursor in try view.transfers(record.cursor) {
                        try insert(cursor: cursor, predecessor: entry.label, road: nil, cost: label.cost, meters: label.meters)
                    }
                }
                liveHistoryPayload = 0
            }
        } catch {
            // A data/validation failure invalidates the calculation. Only bounded
            // resource exhaustion may retain an already completed legal incumbent.
            let labelResource = (error as? ConnectedCostLengthLabels.Failure).map {
                if case .resourceLimit = $0 { return true }; return false
            } == true
            let resource = labelResource || (error as? Failure).map {
                if case .resourceLimit = $0 { return true }; return false
            } == true
            guard resource, RoutingWorkContext.stopReason == nil, incumbent != nil else { throw error }
            limitation = "resourceLimit"
        }
        guard let winner = incumbent else { throw Failure.incomplete("Clean pass has no incumbent; fallback orchestration unsupported") }
        // Search accounting excludes source-owned graphs, native geometry decode
        // and source caches. This is not a whole-process resident-memory claim.
        let chainAllowance = labels.count * MemoryLayout<ConnectedPackStageView.Traversal>.stride * 2
        guard metadataBytes + labels.accountedPayloadBytes + chainAllowance <= limits.maximumPayloadBytes else { throw Failure.resourceLimit }
        var chain: [ConnectedPackStageView.Traversal] = [], current = winner
        chain.reserveCapacity(labels.count)
        while current >= 0 {
            guard let row = records[current] else { throw Failure.invalidInput }
            if let road = row.road { chain.append(road) }
            current = row.predecessor
        }
        chain.reverse()
        var geometry: [CLLocationCoordinate2D] = []
        for road in chain {
            try check()
            let router = OnDeviceRouter(pack: try view.sourcePack(road.road.pack))
            let shape = try router.connectedRoadCoordinates(edge: road.road.edge, fromNode: road.from)
            guard geometry.count + shape.count <= limits.maximumGeometryPoints else { throw Failure.resourceLimit }
            let outputAllowance = 2 * (geometry.count + shape.count) * MemoryLayout<CLLocationCoordinate2D>.stride
                + chain.capacity * MemoryLayout<ConnectedPackStageView.Traversal>.stride
            guard metadataBytes + labels.accountedPayloadBytes + outputAllowance <= limits.maximumPayloadBytes else { throw Failure.resourceLimit }
            peakPayload = max(peakPayload, metadataBytes + labels.accountedPayloadBytes + outputAllowance)
            if let last = geometry.last, let first = shape.first {
                guard last.latitude == first.latitude, last.longitude == first.longitude else {
                    throw Failure.incomplete("Source geometry junction mismatch")
                }
                geometry.append(contentsOf: shape.dropFirst())
            } else { geometry.append(contentsOf: shape) }
        }
        if chain.isEmpty {
            guard origin.pack == destination.pack, origin.node == destination.node else {
                throw Failure.incomplete("Zero-road result does not establish destination")
            }
            geometry = [from]
        }
        // Graph node coordinates are stored as Float32. Compare at that exact
        // source precision, including when geometry itself stores Float64.
        func recordedMatch(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
            a.latitude.isFinite && a.longitude.isFinite
                && Float(a.latitude) == Float(b.latitude)
                && Float(a.longitude) == Float(b.longitude)
        }
        guard let first = geometry.first, let last = geometry.last,
              recordedMatch(first, from), recordedMatch(last, to) else {
            throw Failure.incomplete("Geometry does not reach recorded endpoints")
        }
        if unsupportedOriginTransfer {
            limitation = [limitation, "unarrivedOriginTransferUnsupported"].compactMap { $0 }.joined(separator: ";")
        }
        try view.validateSources()
        try check()
        let selected = try labels.label(winner)
        return .init(roads: chain, coordinates: geometry, meters: selected.meters, cost: selected.cost,
            limitation: limitation, acceptedLabels: labels.count, poppedLabels: pops,
            accountedPeakPayloadBytes: peakPayload)
    }
}
