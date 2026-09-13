import Foundation

/// Decoded `graph.v2.bin` / `graph.v3.bin` / `graph.v4.bin` (CSR).
/// V4 adds legal-topology sections; V2/V3 readers still reject V4-only safety
/// fields by requiring magic `DG2` unless this decoder is used.
/// Opted out of `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` so decode + Dijkstra
/// can run on `Task.detached` without freezing the map.
nonisolated final class GraphV2Pack: @unchecked Sendable {
    struct CrossPackSeamAnchor: Sendable {
        let neighborRegionId: String
        let longitude: Double
        let latitude: Double
        let osmWayId: String
        let localEdgeId: String
        let remoteEdgeId: String
        let gapMeters: Double
        var componentPair: String? = nil
        var networkSize: Int = 0
    }

    /// Resolved Graph-v3 leaf fields for one undirected edge (mirrors JS `edgeLeaves`).
    struct EdgeLeaves: Sendable, Equatable {
        let surfaceLeaf: String?
        let roadClassLeaf: String?
        let tracktype: Int
        let smoothness: Int
        let layer: Int
        let structureLeaf: String?
        let accessLeaf: String?
        let atvDesignated: Bool
        let seasonal: Bool
        let fromLeaves: Bool
    }

    struct TurnRestriction: Sendable {
        let osmRelationId: Int64
        let kind: UInt8
        let fromEdge: Int
        let toEdge: Int
        let viaNode: Int
        let only: Bool
        let vehicleMask: UInt16
        let viaEdges: [Int]
    }

    private struct TurnKey: Hashable, Sendable {
        let viaNode: Int
        let fromEdge: Int
    }

    /// Finite search-state expansion for exact V4 via-way restrictions.
    /// A restriction is active only after its own from-edge and ordered via
    /// sequence have been followed; reaching the same final road another way
    /// does not inherit that restriction.
    struct V4TurnStateSpace: Sendable {
        struct Progress: Hashable, Sendable {
            let id: Int
            let progress: Int
        }

        private struct Pattern: Sendable {
            let fromEdge: Int
            let toEdge: Int
            let viaEdges: [Int]
            let entryNode: Int
            let only: Bool
        }

        private struct Record: Sendable {
            let node: Int
            let incomingEdge: Int
            let active: [Progress]
        }

        private struct ArrivalKey: Hashable, Sendable {
            let node: Int
            let incomingEdge: Int
            let active: [Progress]
        }

        private struct TransitionKey: Hashable, Sendable {
            let state: Int
            let edge: Int
            let toNode: Int
        }

        let baseNodeCount: Int
        let startNode: Int
        let endNode: Int
        let stateCount: Int
        private let records: [Record]
        private let stateByArrival: [ArrivalKey: Int]
        private let transitionCache: [TransitionKey: Int]
        private let statefulEdges: Set<Int>
        private let blockedNode: [TurnKey: Set<Int>]
        private let onlyNode: [TurnKey: Set<Int>]
        private let patterns: [Pattern]
        private let starters: [Int: [Int]]

        static func build(pack: GraphV2Pack, startNode: Int, endNode: Int) -> Self {
            let n = pack.nodeCount
            guard pack.version >= 4, pack.legalTopology, !pack.restrictions.isEmpty else {
                return Self(
                    baseNodeCount: n, startNode: startNode, endNode: endNode,
                    stateCount: n + 2, records: [], stateByArrival: [:],
                    transitionCache: [:], statefulEdges: [], blockedNode: [:],
                    onlyNode: [:], patterns: [], starters: [:]
                )
            }

            var blockedNode: [TurnKey: Set<Int>] = [:]
            var onlyNode: [TurnKey: Set<Int>] = [:]
            var patterns: [Pattern] = []
            var starters: [Int: [Int]] = [:]
            var statefulEdges: Set<Int> = []
            for restriction in pack.restrictions where (restriction.vehicleMask & 1) != 0 {
                statefulEdges.insert(restriction.fromEdge)
                if !restriction.viaEdges.isEmpty {
                    let id = patterns.count
                    patterns.append(Pattern(
                        fromEdge: restriction.fromEdge,
                        toEdge: restriction.toEdge,
                        viaEdges: restriction.viaEdges,
                        entryNode: restriction.viaNode,
                        only: restriction.only
                    ))
                    starters[restriction.fromEdge, default: []].append(id)
                } else {
                    let key = TurnKey(viaNode: restriction.viaNode, fromEdge: restriction.fromEdge)
                    if restriction.only {
                        onlyNode[key, default: []].insert(restriction.toEdge)
                    } else {
                        blockedNode[key, default: []].insert(restriction.toEdge)
                    }
                }
            }

            func advance(
                _ active: [Progress],
                fromEdge: Int,
                toEdge: Int,
                viaNode: Int
            ) -> (allowed: Bool, active: [Progress]) {
                let key = TurnKey(viaNode: viaNode, fromEdge: fromEdge)
                if let only = onlyNode[key], !only.contains(toEdge) { return (false, []) }
                if blockedNode[key]?.contains(toEdge) == true { return (false, []) }

                let activeOnly = active.filter { patterns.indices.contains($0.id) && patterns[$0.id].only }
                if !activeOnly.isEmpty, !activeOnly.contains(where: { row in
                    let pattern = patterns[row.id]
                    let sequence = [pattern.fromEdge] + pattern.viaEdges + [pattern.toEdge]
                    return row.progress + 1 < sequence.count && sequence[row.progress + 1] == toEdge
                }) { return (false, []) }

                var next: [Progress] = []
                for row in active where patterns.indices.contains(row.id) {
                    let pattern = patterns[row.id]
                    let sequence = [pattern.fromEdge] + pattern.viaEdges + [pattern.toEdge]
                    guard row.progress + 1 < sequence.count,
                          sequence[row.progress + 1] == toEdge else { continue }
                    if row.progress + 1 == sequence.count - 1 {
                        if !pattern.only { return (false, []) }
                    } else {
                        next.append(Progress(id: row.id, progress: row.progress + 1))
                    }
                }

                let starting = (starters[fromEdge] ?? []).filter { id in
                    let entry = patterns[id].entryNode
                    return entry < 0 || entry == viaNode
                }
                let startingOnly = starting.filter { patterns[$0].only }
                if !startingOnly.isEmpty,
                   !startingOnly.contains(where: { patterns[$0].viaEdges.first == toEdge }) {
                    return (false, [])
                }
                for id in starting where patterns[id].viaEdges.first == toEdge {
                    next.append(Progress(id: id, progress: 1))
                }
                return (true, Array(Set(next)).sorted {
                    $0.id == $1.id ? $0.progress < $1.progress : $0.id < $1.id
                })
            }

            var records: [Record] = []
            var stateByArrival: [ArrivalKey: Int] = [:]
            var queue: [Int] = []
            func addState(node: Int, incomingEdge: Int, active: [Progress]) -> Int {
                let key = ArrivalKey(node: node, incomingEdge: incomingEdge, active: active)
                if let existing = stateByArrival[key] { return existing }
                let state = n + 2 + records.count
                stateByArrival[key] = state
                records.append(Record(node: node, incomingEdge: incomingEdge, active: active))
                queue.append(state)
                return state
            }
            for source in 0..<n {
                let arcStart = Int(pack.nodeOffsets[source])
                let arcEnd = Int(pack.nodeOffsets[source + 1])
                guard arcStart >= 0, arcEnd <= pack.edgeTargets.count else { continue }
                for arc in arcStart..<arcEnd {
                    let incoming = Int(pack.edgeUndirectedIndex[arc])
                    if !statefulEdges.contains(incoming) { continue }
                    _ = addState(node: Int(pack.edgeTargets[arc]), incomingEdge: incoming, active: [])
                }
            }

            var transitionCache: [TransitionKey: Int] = [:]
            var cursor = 0
            while cursor < queue.count {
                let state = queue[cursor]
                cursor += 1
                let record = records[state - (n + 2)]
                let arcStart = Int(pack.nodeOffsets[record.node])
                let arcEnd = Int(pack.nodeOffsets[record.node + 1])
                guard arcStart >= 0, arcEnd <= pack.edgeTargets.count else { continue }
                for arc in arcStart..<arcEnd {
                    let edge = Int(pack.edgeUndirectedIndex[arc])
                    let toNode = Int(pack.edgeTargets[arc])
                    let result = advance(
                        record.active, fromEdge: record.incomingEdge,
                        toEdge: edge, viaNode: record.node
                    )
                    let key = TransitionKey(state: state, edge: edge, toNode: toNode)
                    if !result.allowed {
                        transitionCache[key] = -1
                    } else if statefulEdges.contains(edge) || !result.active.isEmpty {
                        transitionCache[key] = addState(
                            node: toNode, incomingEdge: edge, active: result.active
                        )
                    } else {
                        transitionCache[key] = toNode
                    }
                }
            }

            return Self(
                baseNodeCount: n, startNode: startNode, endNode: endNode,
                stateCount: n + 2 + records.count, records: records,
                stateByArrival: stateByArrival, transitionCache: transitionCache,
                statefulEdges: statefulEdges, blockedNode: blockedNode,
                onlyNode: onlyNode, patterns: patterns, starters: starters
            )
        }

        func graphNode(of state: Int) -> Int {
            if state < baseNodeCount || state == startNode || state == endNode { return state }
            let index = state - (baseNodeCount + 2)
            return records.indices.contains(index) ? records[index].node : -1
        }

        func stateForArrival(node: Int, incomingEdge: Int) -> Int {
            stateByArrival[ArrivalKey(node: node, incomingEdge: incomingEdge, active: [])] ?? node
        }

        func transition(state: Int, outgoingEdge: Int, toNode: Int) -> Int {
            if state < baseNodeCount || state == startNode || state == endNode {
                return statefulEdges.contains(outgoingEdge)
                    ? stateForArrival(node: toNode, incomingEdge: outgoingEdge)
                    : toNode
            }
            return transitionCache[
                TransitionKey(state: state, edge: outgoingEdge, toNode: toNode)
            ] ?? -1
        }

        func allowsExit(state: Int, outgoingEdge: Int) -> Bool {
            if state < baseNodeCount || state == startNode || state == endNode { return true }
            let index = state - (baseNodeCount + 2)
            guard records.indices.contains(index) else { return false }
            let record = records[index]
            return advance(
                record.active, fromEdge: record.incomingEdge,
                toEdge: outgoingEdge, viaNode: record.node
            ).allowed
        }

        private func advance(
            _ active: [Progress],
            fromEdge: Int,
            toEdge: Int,
            viaNode: Int
        ) -> (allowed: Bool, active: [Progress]) {
            let key = TurnKey(viaNode: viaNode, fromEdge: fromEdge)
            if let only = onlyNode[key], !only.contains(toEdge) { return (false, []) }
            if blockedNode[key]?.contains(toEdge) == true { return (false, []) }
            let activeOnly = active.filter { patterns.indices.contains($0.id) && patterns[$0.id].only }
            if !activeOnly.isEmpty, !activeOnly.contains(where: { row in
                let pattern = patterns[row.id]
                let sequence = [pattern.fromEdge] + pattern.viaEdges + [pattern.toEdge]
                return row.progress + 1 < sequence.count && sequence[row.progress + 1] == toEdge
            }) { return (false, []) }
            var next: [Progress] = []
            for row in active where patterns.indices.contains(row.id) {
                let pattern = patterns[row.id]
                let sequence = [pattern.fromEdge] + pattern.viaEdges + [pattern.toEdge]
                guard row.progress + 1 < sequence.count,
                      sequence[row.progress + 1] == toEdge else { continue }
                if row.progress + 1 == sequence.count - 1 {
                    if !pattern.only { return (false, []) }
                } else {
                    next.append(Progress(id: row.id, progress: row.progress + 1))
                }
            }
            let starting = (starters[fromEdge] ?? []).filter { id in
                patterns[id].entryNode < 0 || patterns[id].entryNode == viaNode
            }
            let startingOnly = starting.filter { patterns[$0].only }
            if !startingOnly.isEmpty,
               !startingOnly.contains(where: { patterns[$0].viaEdges.first == toEdge }) {
                return (false, [])
            }
            for id in starting where patterns[id].viaEdges.first == toEdge {
                next.append(Progress(id: id, progress: 1))
            }
            return (true, Array(Set(next)).sorted {
                $0.id == $1.id ? $0.progress < $1.progress : $0.id < $1.id
            })
        }
    }

    static let magic: UInt32 = 0x3247_3244
    static let magicV4: UInt32 = 0x3454_5244
    static let versionV2: UInt16 = 2
    static let versionV3: UInt16 = 3
    static let versionV4: UInt16 = 4
    static let headerSizeV2 = 72
    static let headerSizeV3 = 100
    static let headerSizeV3Crossing = 104
    static let headerSizeV4 = 140
    /// flags bit0 = edgeFrom/edgeTo; bit1 = v3 leaf sections; bit2 = edgeCrossingSeconds;
    /// bit3 = V4 legal-topology; bit4 = derive edge ids from way/from/to.
    static let flagEdgeFromTo: UInt16 = 1
    static let flagV3Leaves: UInt16 = 2
    static let flagV3CrossingSeconds: UInt16 = 4
    static let flagV4LegalTopology: UInt16 = 8
    static let flagV4DerivedEdgeIDs: UInt16 = 16
    static let requiredV4Capability = "legal-topology.v1"
    /// Packed structure enum (lockstep regional/package.js STRUCTURE).
    static let structureNone = 0
    static let structureBridge = 1
    static let structureTunnel = 2
    static let structureFord = 3
    static let structureFerry = 4

    static func structureName(_ code: Int) -> String {
        switch code {
        case structureBridge: return "bridge"
        case structureTunnel: return "tunnel"
        case structureFord: return "ford"
        case structureFerry: return "ferry"
        case 5: return "blocked_passage"
        case 6: return "unknown"
        default: return "none"
        }
    }

    let version: UInt16
    let flags: UInt16
    let hasLeaves: Bool
    let nodeCount: Int
    let undirectedEdgeCount: Int
    let directedArcCount: Int
    let nodeOffsets: [Int32]
    let edgeTargets: [Int32]
    let edgeUndirectedIndex: [Int32]
    let edgeAttrs: [UInt16]
    let edgeMeters: [UInt32]
    let edgeFrom: [Int32]?
    let edgeTo: [Int32]?
    let nodeCoords: [Float] // lon,lat pairs
    let accessNames: [String]
    let surfaceLeafNames: [String]
    let roadClassLeafNames: [String]
    let structureLeafNames: [String]
    let accessLeafNames: [String]
    /// Leaf → family table from enumsJson (Phase E1). Empty on v2 packs.
    let surfaceFamilyMap: [String: SurfaceFamily]
    /// Leaf → Clean road tier from enumsJson (Phase E2).
    let roadTierMap: [String: RoadTier]
    let edgeSurfaceLeaf: [UInt8]?
    let edgeRoadClassLeaf: [UInt8]?
    let edgeGrade: [UInt8]?
    let edgeLayer: [Int8]?
    let edgeStructureLeaf: [UInt8]?
    let edgeAccessLeaf: [UInt8]?
    let edgeFlags: [UInt8]?
    let edgeCrossingSeconds: [UInt32]?
    let hasCrossingSeconds: Bool
    private(set) var crossPackSeams: [String: [CrossPackSeamAnchor]]
    let urbanCores: [UrbanCore.Box]
    let settlements: [UrbanCore.Box]
    private let idOffsets: [Int32]
    private let idBlob: Data
    let legalTopology: Bool
    let capabilities: [String]
    let sourceEpoch: String?
    /// Per-direction motorcycle access: 2 bytes per undirected edge (forward, reverse).
    let edgeAccess: [UInt8]
    let restrictions: [TurnRestriction]
    let osmWayIds: [Int64]
    let osmNodeIds: [Int64]
    private let blockedNodeTurns: [TurnKey: Set<Int>]
    private let onlyNodeTurns: [TurnKey: Set<Int>]
    private let blockedViaWayExits: [Int: Set<Int>]
    private let onlyViaWayEntries: [Int: Set<Int>]

    var regionId: String?
    /// Optional road-shape sidecar. When present, painted routes follow the road.
    var geometry: GeometryV1Pack?

    init(data: Data) throws {
        guard data.count >= Self.headerSizeV2 else { throw PackError.truncated }
        let magic: UInt32 = data.readUInt32LE(0)
        let isV4 = magic == Self.magicV4
        if isV4 {
            guard data.count >= Self.headerSizeV4 else { throw PackError.truncated }
        } else {
            guard magic == Self.magic else { throw PackError.badMagic }
        }
        let ver: UInt16 = data.readUInt16LE(4)
        if isV4 {
            guard ver == Self.versionV4 else { throw PackError.unsupportedVersion(ver) }
        } else {
            guard ver == Self.versionV2 || ver == Self.versionV3 else {
                throw PackError.unsupportedVersion(ver)
            }
        }
        version = ver
        flags = data.readUInt16LE(6)
        let headerSize = Int(data.readUInt32LE(20))
        let expectHeader: Int
        if isV4 {
            expectHeader = Self.headerSizeV4
        } else {
            expectHeader = ver == Self.versionV3 ? Self.headerSizeV3 : Self.headerSizeV2
        }
        // Tolerate older writers that omit headerSize field contents for v2.
        let effectiveHeader = headerSize > 0 ? headerSize : expectHeader
        guard data.count >= effectiveHeader else { throw PackError.truncated }
        if isV4 {
            guard (flags & Self.flagV4LegalTopology) != 0 else {
                throw PackError.missingCapability
            }
            for off in [104, 108, 112, 116, 120, 124, 128, 132, 136] {
                if data.readUInt32LE(off) == 0 { throw PackError.missingSafetySection }
            }
        }

        nodeCount = Int(data.readUInt32LE(8))
        undirectedEdgeCount = Int(data.readUInt32LE(12))
        directedArcCount = Int(data.readUInt32LE(16))

        let offNodeOffsets = Int(data.readUInt32LE(24))
        let offEdgeTargets = Int(data.readUInt32LE(28))
        let offEdgeUndirected = Int(data.readUInt32LE(32))
        let offEdgeAttrs = Int(data.readUInt32LE(36))
        let offEdgeMeters = Int(data.readUInt32LE(40))
        let offNodeCoords = Int(data.readUInt32LE(44))
        let offIdOffsets = Int(data.readUInt32LE(48))
        let offIdBlob = Int(data.readUInt32LE(52))
        let offEnums = Int(data.readUInt32LE(56))
        let offMeta = Int(data.readUInt32LE(60))
        let offEdgeFrom = (flags & Self.flagEdgeFromTo) != 0 ? Int(data.readUInt32LE(64)) : 0
        let offEdgeTo = (flags & Self.flagEdgeFromTo) != 0 ? Int(data.readUInt32LE(68)) : 0

        hasLeaves =
            ver >= Self.versionV3
            && (flags & Self.flagV3Leaves) != 0
            && effectiveHeader >= Self.headerSizeV3

        let offEdgeSurfaceLeaf = hasLeaves ? Int(data.readUInt32LE(72)) : 0
        let offEdgeRoadClassLeaf = hasLeaves ? Int(data.readUInt32LE(76)) : 0
        let offEdgeGrade = hasLeaves ? Int(data.readUInt32LE(80)) : 0
        let offEdgeLayer = hasLeaves ? Int(data.readUInt32LE(84)) : 0
        let offEdgeStructureLeaf = hasLeaves ? Int(data.readUInt32LE(88)) : 0
        let offEdgeAccessLeaf = hasLeaves ? Int(data.readUInt32LE(92)) : 0
        let offEdgeFlags = hasLeaves ? Int(data.readUInt32LE(96)) : 0
        let hasCrossingSeconds =
            ver >= Self.versionV3
            && (flags & Self.flagV3CrossingSeconds) != 0
            && effectiveHeader >= Self.headerSizeV3Crossing
        let offEdgeCrossingSeconds = hasCrossingSeconds ? Int(data.readUInt32LE(100)) : 0
        self.hasCrossingSeconds = hasCrossingSeconds

        nodeOffsets = data.readInt32Array(at: offNodeOffsets, count: nodeCount + 1)
        edgeTargets = data.readInt32Array(at: offEdgeTargets, count: directedArcCount)
        edgeUndirectedIndex = data.readInt32Array(at: offEdgeUndirected, count: directedArcCount)
        edgeAttrs = data.readUInt16Array(at: offEdgeAttrs, count: undirectedEdgeCount)
        edgeMeters = data.readUInt32Array(at: offEdgeMeters, count: undirectedEdgeCount)
        edgeFrom = offEdgeFrom > 0 ? data.readInt32Array(at: offEdgeFrom, count: undirectedEdgeCount) : nil
        edgeTo = offEdgeTo > 0 ? data.readInt32Array(at: offEdgeTo, count: undirectedEdgeCount) : nil
        nodeCoords = data.readFloat32Array(at: offNodeCoords, count: nodeCount * 2)
        if isV4 {
            let nodeAt = Int(data.readUInt32LE(104))
            guard nodeAt + nodeCount * 8 <= data.count else { throw PackError.missingSafetySection }
            osmNodeIds = (0..<nodeCount).map { data.readInt64LE(nodeAt + $0 * 8) }
        } else { osmNodeIds = [] }
        if isV4, (flags & Self.flagV4DerivedEdgeIDs) != 0 {
            idOffsets = []
            idBlob = Data()
        } else {
            idOffsets = data.readInt32Array(at: offIdOffsets, count: undirectedEdgeCount + 1)
            idBlob = data.subdata(in: offIdBlob..<offEnums)
        }

        let metaEnd: Int
        if hasLeaves && offEdgeSurfaceLeaf > offMeta {
            metaEnd = offEdgeSurfaceLeaf
        } else {
            metaEnd = data.count
        }
        let enumsData = data.subdata(in: offEnums..<offMeta)
        let enums = (try? JSONSerialization.jsonObject(with: enumsData) as? [String: Any]) ?? [:]
        accessNames = Self.stringArray(from: enums["ACCESS_NAME"]) ?? [
            "motorized_verified", "motorized_permissive", "motorized_unknown",
            "motorized_restricted", "motorized_excluded"
        ]
        surfaceLeafNames = Self.stringArray(from: enums["surfaceLeafNames"]) ?? [""]
        roadClassLeafNames = Self.stringArray(from: enums["roadClassLeafNames"]) ?? ["unknown"]
        structureLeafNames = Self.stringArray(from: enums["structureLeafNames"]) ?? [""]
        accessLeafNames = Self.stringArray(from: enums["accessLeafNames"]) ?? [""]
        surfaceFamilyMap = SurfaceFamilyStats.parseFamilyMap(enums["surfaceFamilyMap"])
        roadTierMap = RoadTierStats.parseTierMap(enums["roadTierMap"])

        if hasLeaves {
            edgeSurfaceLeaf = data.readUInt8Array(at: offEdgeSurfaceLeaf, count: undirectedEdgeCount)
            edgeRoadClassLeaf = data.readUInt8Array(at: offEdgeRoadClassLeaf, count: undirectedEdgeCount)
            edgeGrade = data.readUInt8Array(at: offEdgeGrade, count: undirectedEdgeCount)
            edgeLayer = data.readInt8Array(at: offEdgeLayer, count: undirectedEdgeCount)
            edgeStructureLeaf = data.readUInt8Array(at: offEdgeStructureLeaf, count: undirectedEdgeCount)
            edgeAccessLeaf = data.readUInt8Array(at: offEdgeAccessLeaf, count: undirectedEdgeCount)
            edgeFlags = data.readUInt8Array(at: offEdgeFlags, count: undirectedEdgeCount)
            edgeCrossingSeconds = hasCrossingSeconds
                ? data.readUInt32Array(at: offEdgeCrossingSeconds, count: undirectedEdgeCount)
                : nil
        } else {
            edgeSurfaceLeaf = nil
            edgeRoadClassLeaf = nil
            edgeGrade = nil
            edgeLayer = nil
            edgeStructureLeaf = nil
            edgeAccessLeaf = nil
            edgeFlags = nil
            edgeCrossingSeconds = nil
        }

        var decodedSeams: [String: [CrossPackSeamAnchor]] = [:]
        var decodedUrbanCores: [UrbanCore.Box] = []
        var decodedSettlements: [UrbanCore.Box] = []
        if let meta = try? JSONSerialization.jsonObject(
            with: data.subdata(in: offMeta..<metaEnd)
        ) as? [String: Any] {
            regionId = meta["regionId"] as? String ?? meta["province"] as? String
            if let neighbors = meta["crossPackSeams"] as? [String: Any] {
                for (rawNeighbor, rawRows) in neighbors {
                    guard let rows = rawRows as? [[String: Any]] else { continue }
                    let neighbor = rawNeighbor.lowercased()
                    decodedSeams[neighbor] = rows.compactMap { row in
                        guard let coordinate = row["coordinate"] as? [Any], coordinate.count >= 2,
                              let lon = coordinate[0] as? NSNumber,
                              let lat = coordinate[1] as? NSNumber else { return nil }
                        return CrossPackSeamAnchor(
                            neighborRegionId: neighbor,
                            longitude: lon.doubleValue,
                            latitude: lat.doubleValue,
                            osmWayId: String(describing: row["osmWayId"] ?? ""),
                            localEdgeId: String(describing: row["localEdgeId"] ?? ""),
                            remoteEdgeId: String(describing: row["remoteEdgeId"] ?? ""),
                            gapMeters: (row["gapMeters"] as? NSNumber)?.doubleValue ?? .infinity
                        )
                    }
                }
            }
            if let rows = meta["urbanCores"] as? [[String: Any]] {
                decodedUrbanCores = rows.compactMap { row in
                    guard let minLat = row["minLat"] as? NSNumber,
                          let maxLat = row["maxLat"] as? NSNumber,
                          let minLon = row["minLon"] as? NSNumber,
                          let maxLon = row["maxLon"] as? NSNumber else { return nil }
                    return UrbanCore.Box(
                        minLat: minLat.doubleValue,
                        maxLat: maxLat.doubleValue,
                        minLon: minLon.doubleValue,
                        maxLon: maxLon.doubleValue,
                        name: String(describing: row["name"] ?? "urban-core")
                    )
                }
            }
            if let rows = meta["settlements"] as? [[String: Any]] {
                decodedSettlements = rows.compactMap { row in
                    guard let minLat = row["minLat"] as? NSNumber,
                          let maxLat = row["maxLat"] as? NSNumber,
                          let minLon = row["minLon"] as? NSNumber,
                          let maxLon = row["maxLon"] as? NSNumber else { return nil }
                    return UrbanCore.Box(
                        minLat: minLat.doubleValue,
                        maxLat: maxLat.doubleValue,
                        minLon: minLon.doubleValue,
                        maxLon: maxLon.doubleValue,
                        name: String(describing: row["name"] ?? "settlement")
                    )
                }
            }
        }
        crossPackSeams = decodedSeams
        urbanCores = decodedUrbanCores
        settlements = decodedSettlements

        if isV4 {
            legalTopology = true
            let provenanceAt = Int(data.readUInt32LE(128))
            let capAt = Int(data.readUInt32LE(132))
            let shaAt = Int(data.readUInt32LE(136))
            guard provenanceAt < capAt, capAt < shaAt, shaAt + 32 <= data.count else {
                throw PackError.truncated
            }
            let provenance = (try? JSONSerialization.jsonObject(
                with: data.subdata(in: provenanceAt..<capAt)
            ) as? [String: Any]) ?? [:]
            sourceEpoch = provenance["sourceEpoch"] as? String
            let capData = data.subdata(in: capAt..<shaAt)
            let caps = (try? JSONSerialization.jsonObject(with: capData) as? [String]) ?? []
            guard caps.contains(Self.requiredV4Capability) else {
                throw PackError.missingCapability
            }
            capabilities = caps
            let accessAt = Int(data.readUInt32LE(112))
            let accessCount = undirectedEdgeCount * 2
            guard accessAt + accessCount <= data.count else { throw PackError.missingSafetySection }
            edgeAccess = Array(data.subdata(in: accessAt..<(accessAt + accessCount)))
            let wayAt = Int(data.readUInt32LE(108))
            var ways: [Int64] = []
            ways.reserveCapacity(undirectedEdgeCount)
            for i in 0..<undirectedEdgeCount {
                ways.append(data.readInt64LE(wayAt + i * 8))
            }
            osmWayIds = ways
            let restAt = Int(data.readUInt32LE(120))
            let restCount = Int(data.readUInt32LE(restAt))
            var parsed: [TurnRestriction] = []
            var cursor = restAt + 4
            parsed.reserveCapacity(restCount)
            for _ in 0..<restCount {
                let viaWayCount = Int(data.readUInt16LE(cursor + 10))
                var viaEdges: [Int] = []
                viaEdges.reserveCapacity(viaWayCount)
                for v in 0..<viaWayCount {
                    let edge = Int(data.readInt32LE(cursor + 32 + v * 12 + 8))
                    if edge >= 0 { viaEdges.append(edge) }
                }
                parsed.append(
                    TurnRestriction(
                        osmRelationId: data.readInt64LE(cursor),
                        kind: data[cursor + 8],
                        fromEdge: Int(data.readUInt32LE(cursor + 12)),
                        toEdge: Int(data.readUInt32LE(cursor + 16)),
                        viaNode: Int(data.readInt32LE(cursor + 20)),
                        only: (data[cursor + 9] & 2) != 0,
                        vehicleMask: data.readUInt16LE(cursor + 26),
                        viaEdges: viaEdges
                    )
                )
                cursor += 32 + viaWayCount * 12
            }
            restrictions = parsed
            var blockedNode: [TurnKey: Set<Int>] = [:]
            var onlyNode: [TurnKey: Set<Int>] = [:]
            var blockedVia: [Int: Set<Int>] = [:]
            var onlyVia: [Int: Set<Int>] = [:]
            for restriction in parsed where (restriction.vehicleMask & 1) != 0 {
                if let firstVia = restriction.viaEdges.first,
                   let lastVia = restriction.viaEdges.last {
                    if restriction.only {
                        onlyVia[restriction.fromEdge, default: []].insert(firstVia)
                    } else {
                        blockedVia[lastVia, default: []].insert(restriction.toEdge)
                    }
                    continue
                }
                let key = TurnKey(
                    viaNode: restriction.viaNode,
                    fromEdge: restriction.fromEdge
                )
                if restriction.only {
                    onlyNode[key, default: []].insert(restriction.toEdge)
                } else {
                    blockedNode[key, default: []].insert(restriction.toEdge)
                }
            }
            blockedNodeTurns = blockedNode
            onlyNodeTurns = onlyNode
            blockedViaWayExits = blockedVia
            onlyViaWayEntries = onlyVia
        } else {
            legalTopology = false
            capabilities = []
            sourceEpoch = nil
            edgeAccess = []
            restrictions = []
            osmWayIds = []
            blockedNodeTurns = [:]
            onlyNodeTurns = [:]
            blockedViaWayExits = [:]
            onlyViaWayEntries = [:]
        }
    }

    /// Install the independently hash-verified V4 border proof downloaded with
    /// this region. Keeping seams out of the graph lets the factory seal all
    /// graphs first, prove the complete continent, then add borders without a
    /// second graph rebuild.
    func applyCrossPackSeams(data: Data) throws {
        guard version >= Self.versionV4, legalTopology else { throw PackError.missingCapability }
        guard let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              document["schemaVersion"] as? String == "dirt-cross-pack-seams.v2",
              let sidecarRegion = document["regionId"] as? String,
              sidecarRegion.lowercased() == regionId?.lowercased(),
              let sidecarEpoch = document["sourceEpoch"] as? String,
              sourceEpoch == sidecarEpoch,
              let neighbors = document["neighbors"] as? [String: Any]
        else { throw PackError.invalidSeamSidecar }

        var decoded: [String: [CrossPackSeamAnchor]] = [:]
        for (rawNeighbor, rawRows) in neighbors {
            let neighbor = rawNeighbor.lowercased()
            guard neighbor.range(of: "^[a-z]{2}$", options: .regularExpression) != nil,
                  let rows = rawRows as? [[String: Any]] else {
                throw PackError.invalidSeamSidecar
            }
            decoded[neighbor] = try rows.map { row in
                guard let coordinate = row["coordinate"] as? [Any], coordinate.count >= 2,
                      let lon = coordinate[0] as? NSNumber,
                      let lat = coordinate[1] as? NSNumber,
                      let gap = row["gapMeters"] as? NSNumber,
                      gap.doubleValue >= 0, gap.doubleValue <= 2,
                      let osmWayId = row["osmWayId"],
                      let localEdgeId = row["localEdgeId"],
                      let remoteEdgeId = row["remoteEdgeId"],
                      !String(describing: osmWayId).isEmpty,
                      !String(describing: localEdgeId).isEmpty,
                      !String(describing: remoteEdgeId).isEmpty
                else { throw PackError.invalidSeamSidecar }
                return CrossPackSeamAnchor(
                    neighborRegionId: neighbor,
                    longitude: lon.doubleValue,
                    latitude: lat.doubleValue,
                    osmWayId: String(describing: osmWayId),
                    localEdgeId: String(describing: localEdgeId),
                    remoteEdgeId: String(describing: remoteEdgeId),
                    gapMeters: gap.doubleValue,
                    componentPair: row["componentPair"] as? String,
                    networkSize: (row["networkSize"] as? NSNumber)?.intValue ?? 0
                )
            }
        }
        crossPackSeams = decoded
    }

    private static func stringArray(from value: Any?) -> [String]? {
        if let names = value as? [String] { return names }
        if let names = value as? [Any] { return names.map { "\($0)" } }
        if let names = value as? [String: Any] {
            let indexed = names.compactMap { key, value -> (Int, String)? in
                guard let index = Int(key), index >= 0 else { return nil }
                return (index, "\(value)")
            }
            guard let lastIndex = indexed.map(\.0).max() else { return nil }
            var result = Array(repeating: "", count: lastIndex + 1)
            for (index, name) in indexed {
                result[index] = name
            }
            return result
        }
        return nil
    }

    func edgeId(_ ei: Int) -> String {
        guard ei >= 0, ei < undirectedEdgeCount else { return "" }
        if version == Self.versionV4, (flags & Self.flagV4DerivedEdgeIDs) != 0,
           ei < osmWayIds.count,
           let from = edgeFrom?[ei], let to = edgeTo?[ei] {
            return "w\(osmWayIds[ei]):\(from):\(to)"
        }
        let a = Int(idOffsets[ei])
        let b = Int(idOffsets[ei + 1])
        guard a >= 0, b >= a, b <= idBlob.count else { return "" }
        return String(data: idBlob.subdata(in: a..<b), encoding: .utf8) ?? ""
    }

    /// Private cross-pack translation. Keep published/local edge IDs unchanged,
    /// but carry road history across different regional node-number tables.
    func canonicalRoadID(_ localID: String) -> String? {
        let parts = localID.split(separator: ":")
        guard parts.count == 3, parts[0].first == "w",
              let a = Int(parts[1]), let b = Int(parts[2]),
              osmNodeIds.indices.contains(a), osmNodeIds.indices.contains(b) else { return nil }
        return "\(parts[0]):\(min(osmNodeIds[a], osmNodeIds[b])):\(max(osmNodeIds[a], osmNodeIds[b]))"
    }

    func localRoadIDs(matching canonical: Set<String>) -> Set<String> {
        guard !canonical.isEmpty, !osmNodeIds.isEmpty, let from = edgeFrom, let to = edgeTo else { return [] }
        let ways = Set(canonical.compactMap { $0.split(separator: ":").first.flatMap { Int64($0.dropFirst()) } })
        var result = Set<String>()
        for ei in osmWayIds.indices where ways.contains(osmWayIds[ei]) {
            let a = Int(from[ei]), b = Int(to[ei])
            guard osmNodeIds.indices.contains(a), osmNodeIds.indices.contains(b) else { continue }
            let id = "w\(osmWayIds[ei]):\(min(osmNodeIds[a], osmNodeIds[b])):\(max(osmNodeIds[a], osmNodeIds[b]))"
            if canonical.contains(id) { result.insert(edgeId(ei)) }
        }
        return result
    }

    /// True when the packed CSR contains a legal travel arc `from → to` on `edge`.
    func hasDirectedArc(from: Int, to: Int, edge: Int) -> Bool {
        guard from >= 0, from < nodeCount, to >= 0, edge >= 0, edge < undirectedEdgeCount else {
            return false
        }
        let start = Int(nodeOffsets[from])
        let end = Int(nodeOffsets[from + 1])
        guard start >= 0, end <= edgeTargets.count, start <= end else { return false }
        if start == end { return false }
        for i in start..<end {
            if Int(edgeTargets[i]) == to, Int(edgeUndirectedIndex[i]) == edge {
                return true
            }
        }
        return false
    }

    // MARK: - Graph-v3 leaf accessors (JS lockstep)

    func surfaceLeaf(_ ei: Int) -> String? {
        guard hasLeaves, let arr = edgeSurfaceLeaf, ei >= 0, ei < arr.count else { return nil }
        let idx = Int(arr[ei])
        if idx == 0 { return nil }
        return Self.nameAt(surfaceLeafNames, idx, fallback: nil)
    }

    func surfaceFamily(_ ei: Int) -> SurfaceFamily {
        guard hasLeaves else { return .unknown }
        return SurfaceFamilyStats.family(of: surfaceLeaf(ei), map: surfaceFamilyMap)
    }

    func roadClassLeaf(_ ei: Int) -> String? {
        guard hasLeaves, let arr = edgeRoadClassLeaf, ei >= 0, ei < arr.count else { return nil }
        return Self.nameAt(roadClassLeafNames, Int(arr[ei]), fallback: "unknown")
    }

    func roadTier(_ ei: Int) -> RoadTier {
        guard hasLeaves else { return .unknown }
        return RoadTierStats.tier(of: roadClassLeaf(ei), map: roadTierMap)
    }

    func structureLeaf(_ ei: Int) -> String? {
        guard hasLeaves, let arr = edgeStructureLeaf, ei >= 0, ei < arr.count else { return nil }
        let idx = Int(arr[ei])
        if idx == 0 { return nil }
        return Self.nameAt(structureLeafNames, idx, fallback: nil)
    }

    func accessLeaf(_ ei: Int) -> String? {
        guard hasLeaves, let arr = edgeAccessLeaf, ei >= 0, ei < arr.count else { return nil }
        let idx = Int(arr[ei])
        if idx == 0 { return nil }
        return Self.nameAt(accessLeafNames, idx, fallback: nil)
    }

    /// Tracktype nibble from `edgeGrade` bits 0–3 (0 = none).
    func tracktype(_ ei: Int) -> Int {
        guard hasLeaves, let arr = edgeGrade, ei >= 0, ei < arr.count else { return 0 }
        return Int(arr[ei] & 0x0F)
    }

    /// Smoothness nibble from `edgeGrade` bits 4–7 (0 = missing).
    func smoothness(_ ei: Int) -> Int {
        guard hasLeaves, let arr = edgeGrade, ei >= 0, ei < arr.count else { return 0 }
        return Int((arr[ei] >> 4) & 0x0F)
    }

    func layer(_ ei: Int) -> Int {
        guard hasLeaves, let arr = edgeLayer, ei >= 0, ei < arr.count else { return 0 }
        return Int(arr[ei])
    }

    func atvDesignated(_ ei: Int) -> Bool {
        guard hasLeaves, let arr = edgeFlags, ei >= 0, ei < arr.count else { return false }
        return (arr[ei] & 0x1) != 0
    }

    func seasonalFlag(_ ei: Int) -> Bool {
        guard hasLeaves, let arr = edgeFlags, ei >= 0, ei < arr.count else {
            return Self.unpackSeasonal(edgeAttrs[safe: ei] ?? 0)
        }
        return ((arr[ei] >> 1) & 0x1) != 0 || Self.unpackSeasonal(edgeAttrs[ei])
    }

    func crossingSeconds(_ ei: Int) -> UInt32 {
        guard hasCrossingSeconds, let arr = edgeCrossingSeconds, ei >= 0, ei < arr.count else { return 0 }
        return arr[ei]
    }

    /// Per-direction motorcycle access code (0 allowed … 2/5 deny, 3/4 endpoint-only).
    func v4AccessCode(ei: Int, from: Int, to: Int) -> UInt8 {
        guard legalTopology, ei >= 0, ei * 2 + 1 < edgeAccess.count else { return 0 }
        let forward = edgeFrom?[ei] == Int32(from) && edgeTo?[ei] == Int32(to)
        return edgeAccess[ei * 2 + (forward ? 0 : 1)]
    }

    func makeV4TurnStateSpace(startNode: Int, endNode: Int) -> V4TurnStateSpace {
        V4TurnStateSpace.build(pack: self, startNode: startNode, endNode: endNode)
    }

    func v4AccessAllowed(
        ei: Int,
        from: Int,
        to: Int,
        startEi: Int,
        endEi: Int,
        allowUnknown: Bool,
        startEndpointKind: String? = nil,
        endEndpointKind: String? = nil,
        customerStartEdges: Set<Int> = [],
        customerEndEdges: Set<Int> = []
    ) -> Bool {
        guard version >= 4, legalTopology else { return true }
        let code = Int(v4AccessCode(ei: ei, from: from, to: to))
        if code == 0 { return true }
        if code == 1 { return allowUnknown }
        if code == 2 || code == 5 { return false }
        if code == 3 {
            return (ei == startEi && startEndpointKind != "customers")
                || (ei == endEi && endEndpointKind != "customers")
        }
        if code == 4 {
            return ((ei == startEi || customerStartEdges.contains(ei)) && startEndpointKind == "customers")
                || ((ei == endEi || customerEndEdges.contains(ei)) && endEndpointKind == "customers")
        }
        return false
    }

    func turnAllowed(fromEdge: Int, toEdge: Int, viaNode: Int) -> Bool {
        let key = TurnKey(viaNode: viaNode, fromEdge: fromEdge)
        if let only = onlyNodeTurns[key], !only.contains(toEdge) { return false }
        if blockedNodeTurns[key]?.contains(toEdge) == true { return false }
        if blockedViaWayExits[fromEdge]?.contains(toEdge) == true { return false }
        if let onlyVia = onlyViaWayEntries[fromEdge], !onlyVia.contains(toEdge) { return false }
        return true
    }

    /// Live `find-path-v2` V4 hop filter. No-ops on V2/V3.
    func v4HopIllegal(
        ei: Int,
        from: Int,
        to: Int,
        startEi: Int,
        endEi: Int,
        incomingEi: Int
    ) -> Bool {
        guard version >= 4, legalTopology else { return false }
        let code = Int(v4AccessCode(ei: ei, from: from, to: to))
        if code == 2 || code == 5 { return true }
        if (code == 3 || code == 4), ei != startEi, ei != endEi { return true }
        if incomingEi < 0 || restrictions.isEmpty { return false }
        return !turnAllowed(fromEdge: incomingEi, toEdge: ei, viaNode: from)
    }

    static func isFerryStructure(_ code: Int) -> Bool {
        code == structureFerry
    }

    /// Full leaf snapshot matching JS `edgeLeaves(ei)`.
    func edgeLeaves(_ ei: Int) -> EdgeLeaves {
        guard hasLeaves else {
            return EdgeLeaves(
                surfaceLeaf: nil,
                roadClassLeaf: nil,
                tracktype: 0,
                smoothness: 0,
                layer: 0,
                structureLeaf: nil,
                accessLeaf: nil,
                atvDesignated: false,
                seasonal: Self.unpackSeasonal(edgeAttrs[safe: ei] ?? 0),
                fromLeaves: false
            )
        }
        return EdgeLeaves(
            surfaceLeaf: surfaceLeaf(ei),
            roadClassLeaf: roadClassLeaf(ei),
            tracktype: tracktype(ei),
            smoothness: smoothness(ei),
            layer: layer(ei),
            structureLeaf: structureLeaf(ei),
            accessLeaf: accessLeaf(ei),
            atvDesignated: atvDesignated(ei),
            seasonal: seasonalFlag(ei),
            fromLeaves: true
        )
    }

    private static func nameAt(_ names: [String], _ idx: Int, fallback: String?) -> String? {
        guard idx >= 0, idx < names.count else { return fallback }
        let v = names[idx]
        if v.isEmpty { return fallback }
        return v
    }

    /// Provincial capillary (DRA / FTEN / Access / MNRF / …). Same-region dirt only.
    static func isProvincialCapillaryEdge(_ edgeId: String) -> Bool {
        let id = edgeId.lowercased()
        return id.hasPrefix("bc-dra-")
            || id.hasPrefix("bc-ften-")
            || id.hasPrefix("ab-access-")
            || id.hasPrefix("on-mnrf-")
            || id.hasPrefix("ns-nstdb-")
            || id.hasPrefix("nb-forest-")
            || id.hasPrefix("qc-multi-")
            || id.hasPrefix("nl-ffa-")
    }

    /// OSM through-network (motorway → smallest OSM road/track), including OSM
    /// tip stitches (`pack-`). Used for province/state hops — never capillary.
    static func isOsmCoreEdge(_ edgeId: String) -> Bool {
        if isProvincialCapillaryEdge(edgeId) { return false }
        if edgeId.hasPrefix("soft-stitch-") { return false }
        return true
    }

    static func unpackSurface(_ attr: UInt16) -> Int { Int(attr & 7) }
    static func unpackAccess(_ attr: UInt16) -> Int { Int((attr >> 3) & 7) }
    static func unpackStructure(_ attr: UInt16) -> Int { Int((attr >> 6) & 7) }
    /// Confidence: 0 high, 1 medium, 2 low (bits 9–10).
    static func unpackConfidence(_ attr: UInt16) -> Int { Int((attr >> 9) & 3) }
    static func unpackSeasonal(_ attr: UInt16) -> Bool { ((attr >> 11) & 1) == 1 }
    /// Road-track class packed in bits 12–15 (0 when older packs omit it).
    static func unpackRoadClass(_ attr: UInt16) -> Int { Int((attr >> 12) & 15) }

    static func roadClassName(_ code: Int) -> String {
        switch code {
        case 1: return "freeway"
        case 2: return "arterial"
        case 3: return "collector"
        case 4: return "local"
        case 5: return "service"
        case 6: return "resource"
        case 7: return "recreation"
        case 8: return "track"
        case 9: return "double_track"
        case 10: return "ramp"
        default: return "unknown"
        }
    }

    enum PackError: Error {
        case truncated
        case badMagic
        case unsupportedVersion(UInt16)
        case missingCapability
        case missingSafetySection
        case invalidSeamSidecar
    }
}

private extension Array {
    nonisolated subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}

private extension Data {
    nonisolated func readUInt32LE(_ offset: Int) -> UInt32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }

    nonisolated func readUInt16LE(_ offset: Int) -> UInt16 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian }
    }

    nonisolated func readInt32LE(_ offset: Int) -> Int32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self).littleEndian }
    }

    nonisolated func readInt64LE(_ offset: Int) -> Int64 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int64.self).littleEndian }
    }

    nonisolated func readInt32Array(at offset: Int, count: Int) -> [Int32] {
        guard count > 0 else { return [] }
        let byteCount = count * 4
        return subdata(in: offset..<(offset + byteCount)).withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int32.self).prefix(count)).map { Int32(littleEndian: $0) }
        }
    }

    nonisolated func readUInt16Array(at offset: Int, count: Int) -> [UInt16] {
        guard count > 0 else { return [] }
        let byteCount = count * 2
        return subdata(in: offset..<(offset + byteCount)).withUnsafeBytes { raw in
            Array(raw.bindMemory(to: UInt16.self).prefix(count)).map { UInt16(littleEndian: $0) }
        }
    }

    nonisolated func readUInt32Array(at offset: Int, count: Int) -> [UInt32] {
        guard count > 0 else { return [] }
        let byteCount = count * 4
        return subdata(in: offset..<(offset + byteCount)).withUnsafeBytes { raw in
            Array(raw.bindMemory(to: UInt32.self).prefix(count)).map { UInt32(littleEndian: $0) }
        }
    }

    nonisolated func readFloat32Array(at offset: Int, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        let byteCount = count * 4
        return subdata(in: offset..<(offset + byteCount)).withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
    }

    nonisolated func readUInt8Array(at offset: Int, count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        return Array(subdata(in: offset..<(offset + count)))
    }

    nonisolated func readInt8Array(at offset: Int, count: Int) -> [Int8] {
        guard count > 0 else { return [] }
        return subdata(in: offset..<(offset + count)).withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int8.self).prefix(count))
        }
    }
}
