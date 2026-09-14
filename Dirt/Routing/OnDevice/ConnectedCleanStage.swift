import CoreLocation
import Foundation

/// Unactivated single Clean pass on exact recorded nodes. No profile substitution,
/// fallback orchestration, tap matching, customer access or fractional connectors.
/// Unlike serial hop winners, every prefix competes under ONE stage metre cap.
nonisolated enum ConnectedCleanStage {
    enum CleanPass: String {
        case pavedWall, unpavedWall, pavedUrban, unpavedUrban
        var cityWall: Bool { self == .pavedWall || self == .unpavedWall }
        var pavedOnly: Bool { self == .pavedWall || self == .pavedUrban }
        var disclosure: [String] {
            (pavedOnly ? [] : ["cleanUnpavedFallback=lastResort"])
                + (cityWall ? [] : ["urbanCoreFallback=lastResort"])
        }
    }
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
        let ancestorCanonicalSourceReads: Int
        let ancestorRecordVisits: Int
        let accountedPeakPayloadBytes: Int
    }
    enum Failure: Error { case unsupported(String), incomplete(String), passExhausted, resourceLimit, cancelled, invalidInput }
    private struct Record {
        let cursor: ConnectedPackStageView.Cursor
        let predecessor: Int
        let historyID: Int
        let road: ConnectedPackStageView.Traversal?
        let canonicalRoad: ConnectedPackStageView.CanonicalRoad?
        let roadDepth: Int
    }
    private struct QueueItem { let label: Int; let cost: Double }

    static func calculate(view: ConnectedPackStageView, origin: Endpoint, destination: Endpoint,
        profile: RouteProfile, maxMeters: Double, context: HopSearchContext,
        pass: CleanPass = .pavedWall,
        ridePreferences: RidePreferences? = nil, avoidEdgeIDs: Set<String> = [],
        policySources: [any ConnectedCleanPolicySource]? = nil,
        cacheCanonicalHistory: Bool = true,
        limits: Limits = Limits()) throws -> Result {
        defer { view.publishDiagnostics() }
        guard profile == .cleanest, context.profile == .cleanest,
              context.costMode == .profile, context.cityWall == pass.cityWall, context.pavedOnly == pass.pavedOnly,
              !context.variety, context.noBacktrack, context.priorEdgeIds.isEmpty,
              context.arrivalEdgeId == nil, context.customerStartEdges.isEmpty,
              context.customerEndEdges.isEmpty, context.roadRemaining == nil,
              context.urbanEdgeMemo == nil, context.maxPathMeters == nil,
              context.calculationDeadline == nil else { throw Failure.unsupported("Only explicitly selected ordinary-endpoint Clean passes are implemented") }
        guard maxMeters.isFinite, maxMeters > 0, limits.maximumLabels > 0, limits.maximumLabels <= 65_536,
              limits.maximumQueueEntries > 0, limits.maximumQueueEntries <= 131_072, limits.maximumPops > 0,
              limits.maximumGeometryPoints > 0, limits.maximumGeometryPoints <= 1_000_000,
              limits.timeBudgetMilliseconds > 0,
              limits.timeBudgetMilliseconds <= 18_000 else { throw Failure.invalidInput }
        let deadline = RoutingWorkContext.limitedDeadline(milliseconds: limits.timeBudgetMilliseconds)
        return try RoutingWorkContext.$deadline.withValue(deadline) {
            try run(view: view, origin: origin, destination: destination,
                maxMeters: maxMeters, context: context, ridePreferences: ridePreferences,
                avoidEdgeIDs: avoidEdgeIDs, policySources: policySources, cacheCanonicalHistory: cacheCanonicalHistory, limits: limits)
        }
    }

    private static func run(view: ConnectedPackStageView, origin: Endpoint, destination: Endpoint,
        maxMeters: Double, context: HopSearchContext, ridePreferences: RidePreferences?,
        avoidEdgeIDs: Set<String>, policySources: [any ConnectedCleanPolicySource]?, cacheCanonicalHistory: Bool, limits: Limits) throws -> Result {
        func check() throws { try RoutingWorkContext.check() }
        try check()
        let policies: [any ConnectedCleanPolicySource]
        if let policySources { policies = policySources }
        else {
            policies = try (0..<view.sourceCount).map {
                ArrayConnectedCleanPolicySource(pack: try view.sourcePack($0),graphSHA256: try view.sourceIdentityHash(pack: $0))
            }
        }
        guard policies.count == view.sourceCount,policies.indices.contains(origin.pack),policies.indices.contains(destination.pack) else { throw Failure.invalidInput }
        for (index,policy) in policies.enumerated() {
            guard policy.graphSHA256 == (try view.sourceIdentityHash(pack: index)) else { throw PagedV4Core.Failure.identityMismatch }
            try policy.validate()
        }
        let from = try policies[origin.pack].endpoint(node: origin.node,edge: origin.matchedEdge)
        let to = try policies[destination.pack].endpoint(node: destination.node,edge: destination.matchedEdge)
        func highway(_ policy: any ConnectedCleanPolicySource,_ edge: Int) throws -> Bool {
            let tier = try policy.roadTier(edge)
            return tier == .motorway || tier == .trunk || tier == .arterial
        }
        let fromHighway = try highway(policies[origin.pack],origin.matchedEdge)
        let toHighway = try highway(policies[destination.pack],destination.matchedEdge)
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
        var ancestorCanonicalSourceReads = 0, ancestorRecordVisits = 0
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
                    road: ConnectedPackStageView.Traversal?, canonical: ConnectedPackStageView.CanonicalRoad? = nil, cost: Double, meters: Double) throws {
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
            let depth = (predecessor >= 0 ? records[predecessor]!.roadDepth : 0) + (road == nil ? 0 : 1)
            records[id] = .init(cursor: cursor, predecessor: predecessor, historyID: historyID, road: road,
                canonicalRoad: cacheCanonicalHistory ? canonical : nil, roadDepth: depth)
            if cursor.pack == destination.pack, try view.node(cursor) == destination.node {
                if let previous = incumbent {
                    if cost < (try labels.label(previous).cost) { incumbent = id }
                } else { incumbent = id }
            }
            try push(.init(label: id, cost: cost))
        }
        try insert(cursor: view.startCursor(pack: origin.pack,node: origin.node),
            predecessor: -1, road: nil, cost: 0, meters: 0)
        do {
            while let entry = pop() {
                try check(); pops += 1
                guard pops <= limits.maximumPops else { throw Failure.resourceLimit }
                let label = try labels.label(entry.label)
                if !label.isActive { continue }
                guard let record = records[entry.label] else { throw Failure.invalidInput }
                if entry.label == incumbent { break }
                let policy = policies[record.cursor.pack]
                try policy.validate()
                var priorRoad: ConnectedPackStageView.Traversal?
                let scratchBudget = record.roadDepth * MemoryLayout<ConnectedPackStageView.CanonicalRoad>.stride * 2
                guard metadataBytes + labels.accountedPayloadBytes + scratchBudget <= limits.maximumPayloadBytes else { throw Failure.resourceLimit }
                var history = entry.label
                var usedRoads: [ConnectedPackStageView.CanonicalRoad] = []
                usedRoads.reserveCapacity(record.roadDepth)
                // These temporary histories are bounded by labels; scratch payload
                // is separately checked below and never retained for every label.
                while history >= 0 {
                    try check()
                    guard let previous = records[history] else { throw Failure.invalidInput }
                    ancestorRecordVisits += 1
                    if let road = previous.road {
                        if priorRoad == nil { priorRoad = road }
                        if cacheCanonicalHistory {
                            guard let canonical = previous.canonicalRoad else { throw Failure.invalidInput }
                            usedRoads.append(canonical)
                        } else {
                            ancestorCanonicalSourceReads += 1
                            usedRoads.append(try view.canonicalRoad(road.road))
                        }
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
                    if try !policy.allowed(edge: road.road.edge, fromNode: road.from, toNode: road.to,
                        startEdge: record.cursor.pack == origin.pack ? origin.matchedEdge : -1,
                        endEdge: record.cursor.pack == destination.pack ? destination.matchedEdge : -1,
                        from: from, to: to, avoid: avoidEdgeIDs, preferences: ridePreferences, context: context) { return }
                    let step = try policy.cost(edge: road.road.edge, fromNode: road.from, toNode: road.to,
                        from: from, to: to, startHighway: fromHighway, endHighway: toHighway,
                        preferences: ridePreferences, context: context, predecessorTier: {
                            guard let priorRoad else { return nil }
                            return try policies[priorRoad.road.pack].roadTier(priorRoad.road.edge)
                        })
                    guard step.isFinite, step >= 0 else { throw Failure.invalidInput }
                    try insert(cursor: road.destination, predecessor: entry.label, road: road, canonical: canonical,
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
        guard let winner = incumbent else {
            if unsupportedOriginTransfer { throw Failure.incomplete("Unarrived origin transfer was not searched") }
            // Only complete exhaustion of this explicit recorded-node pass may
            // advance a diagnostic to the next native rung. Errors and caps
            // leave above through their original typed failure.
            throw Failure.passExhausted
        }
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
        // Graph node coordinates are stored as Float32. Compare at that exact
        // source precision, including when geometry itself stores Float64.
        func recordedMatch(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
            a.latitude.isFinite && a.longitude.isFinite
                && Float(a.latitude) == Float(b.latitude)
                && Float(a.longitude) == Float(b.longitude)
        }
        var geometry: [CLLocationCoordinate2D] = []
        for road in chain {
            try check()
            let shape = try policies[road.road.pack].geometry(edge: road.road.edge,fromNode: road.from)
            let recordedFrom = try policies[road.road.pack].endpoint(node: road.from,edge: road.road.edge)
            let recordedTo = try policies[road.road.pack].endpoint(node: road.to,edge: road.road.edge)
            guard let first = shape.first,let last = shape.last,
                  recordedMatch(first,recordedFrom),recordedMatch(last,recordedTo) else {
                throw Failure.incomplete("Road geometry does not reach recorded edge endpoints")
            }
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
        guard let first = geometry.first, let last = geometry.last,
              recordedMatch(first, from), recordedMatch(last, to) else {
            throw Failure.incomplete("Geometry does not reach recorded endpoints")
        }
        if unsupportedOriginTransfer {
            limitation = [limitation, "unarrivedOriginTransferUnsupported"].compactMap { $0 }.joined(separator: ";")
        }
        for policy in policies { try policy.validate() }
        try view.validateSources()
        try check()
        let selected = try labels.label(winner)
        return .init(roads: chain, coordinates: geometry, meters: selected.meters, cost: selected.cost,
            limitation: limitation, acceptedLabels: labels.count, poppedLabels: pops,
            ancestorCanonicalSourceReads: ancestorCanonicalSourceReads, ancestorRecordVisits: ancestorRecordVisits,
            accountedPeakPayloadBytes: peakPayload)
    }
}
