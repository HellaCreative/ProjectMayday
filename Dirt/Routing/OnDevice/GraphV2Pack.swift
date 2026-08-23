import Foundation

/// Decoded `graph.v2.bin` / `graph.v3.bin` (CSR). Same layout as `pack-fabric/routing/lib/pack-v2.js`.
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

    static let magic: UInt32 = 0x3247_3244
    static let versionV2: UInt16 = 2
    static let versionV3: UInt16 = 3
    static let headerSizeV2 = 72
    static let headerSizeV3 = 100
    static let headerSizeV3Crossing = 104
    /// flags bit0 = edgeFrom/edgeTo; bit1 = v3 leaf sections; bit2 = edgeCrossingSeconds.
    static let flagEdgeFromTo: UInt16 = 1
    static let flagV3Leaves: UInt16 = 2
    static let flagV3CrossingSeconds: UInt16 = 4
    /// Packed structure enum: ferry (lockstep regional/package.js).
    static let structureFerry = 4

    let data: Data
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
    let crossPackSeams: [String: [CrossPackSeamAnchor]]
    let urbanCores: [UrbanCore.Box]
    let settlements: [UrbanCore.Box]
    private let idOffsets: [Int32]
    private let idBlob: Data

    var regionId: String?
    /// Optional road-shape sidecar. When present, painted routes follow the road.
    var geometry: GeometryV1Pack?

    init(data: Data) throws {
        self.data = data
        guard data.count >= Self.headerSizeV2 else { throw PackError.truncated }
        let magic: UInt32 = data.readUInt32LE(0)
        guard magic == Self.magic else { throw PackError.badMagic }
        let ver: UInt16 = data.readUInt16LE(4)
        guard ver == Self.versionV2 || ver == Self.versionV3 else {
            throw PackError.unsupportedVersion(ver)
        }
        version = ver
        flags = data.readUInt16LE(6)
        let headerSize = Int(data.readUInt32LE(20))
        let expectHeader = ver == Self.versionV3 ? Self.headerSizeV3 : Self.headerSizeV2
        // Tolerate older writers that omit headerSize field contents for v2.
        let effectiveHeader = headerSize > 0 ? headerSize : expectHeader
        guard data.count >= effectiveHeader else { throw PackError.truncated }

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
        idOffsets = data.readInt32Array(at: offIdOffsets, count: undirectedEdgeCount + 1)
        idBlob = data.subdata(in: offIdBlob..<offEnums)

        let metaEnd: Int
        if hasLeaves && offEdgeSurfaceLeaf > offMeta {
            metaEnd = offEdgeSurfaceLeaf
        } else {
            metaEnd = data.count
        }
        let enumsData = data.subdata(in: offEnums..<offMeta)
        let enums = (try? JSONSerialization.jsonObject(with: enumsData) as? [String: Any]) ?? [:]
        accessNames = Self.stringArray(from: enums["ACCESS_NAME"]) ?? [
            "motorized_permissive", "motorized_verified", "motorized_unknown",
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
    }

    private static func stringArray(from value: Any?) -> [String]? {
        if let names = value as? [String] { return names }
        if let names = value as? [Any] { return names.map { "\($0)" } }
        return nil
    }

    func edgeId(_ ei: Int) -> String {
        guard ei >= 0, ei < undirectedEdgeCount else { return "" }
        let a = Int(idOffsets[ei])
        let b = Int(idOffsets[ei + 1])
        guard a >= 0, b >= a, b <= idBlob.count else { return "" }
        return String(data: idBlob.subdata(in: a..<b), encoding: .utf8) ?? ""
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
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}

private extension Data {
    nonisolated func readUInt32LE(_ offset: Int) -> UInt32 {
        self[offset..<offset + 4].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    }

    nonisolated func readUInt16LE(_ offset: Int) -> UInt16 {
        self[offset..<offset + 2].withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
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
