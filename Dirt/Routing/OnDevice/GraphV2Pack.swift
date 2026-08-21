import Foundation

/// Decoded `graph.v2.bin` (CSR). Same layout as `pack-fabric/routing/lib/pack-v2.js`.
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

    static let magic: UInt32 = 0x3247_3244
    static let version: UInt16 = 2

    let data: Data
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
    let crossPackSeams: [String: [CrossPackSeamAnchor]]
    let urbanCores: [UrbanCore.Box]
    let settlements: [UrbanCore.Box]
    private let idOffsets: [Int32]
    private let idBlob: Data

    var regionId: String?
    /// Optional road-shape sidecar. When present, painted routes follow the road.
    var geometry: GeometryV1Pack?

    init(data: Data) throws {
        var data = data
        // Large packs may be stored on R2 as gzip (wrangler 300MiB upload cap).
        if data.count >= 2, data[data.startIndex] == 0x1f,
           data[data.index(after: data.startIndex)] == 0x8b {
            data = try Self.gunzipped(data)
        }
        self.data = data
        guard data.count >= 72 else { throw PackError.truncated }
        let magic: UInt32 = data.readUInt32LE(0)
        guard magic == Self.magic else { throw PackError.badMagic }
        let ver: UInt16 = data.readUInt16LE(4)
        guard ver == Self.version else { throw PackError.unsupportedVersion(ver) }

        nodeCount = Int(data.readUInt32LE(8))
        undirectedEdgeCount = Int(data.readUInt32LE(12))
        directedArcCount = Int(data.readUInt32LE(16))
        let flags: UInt16 = data.readUInt16LE(6)

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
        let offEdgeFrom = (flags & 1) != 0 ? Int(data.readUInt32LE(64)) : 0
        let offEdgeTo = (flags & 1) != 0 ? Int(data.readUInt32LE(68)) : 0

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

        let enumsData = data.subdata(in: offEnums..<offMeta)
        let enums = (try? JSONSerialization.jsonObject(with: enumsData) as? [String: Any]) ?? [:]
        if let names = enums["ACCESS_NAME"] as? [String] {
            accessNames = names
        } else if let names = enums["ACCESS_NAME"] as? [Any] {
            accessNames = names.map { "\($0)" }
        } else {
            accessNames = ["motorized_permissive", "motorized_verified", "motorized_unknown", "motorized_restricted", "motorized_excluded"]
        }

        var decodedSeams: [String: [CrossPackSeamAnchor]] = [:]
        var decodedUrbanCores: [UrbanCore.Box] = []
        var decodedSettlements: [UrbanCore.Box] = []
        if let metaData = data.subdata(in: offMeta..<data.count) as Data?,
           let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] {
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

    func edgeId(_ ei: Int) -> String {
        guard ei >= 0, ei < undirectedEdgeCount else { return "" }
        let a = Int(idOffsets[ei])
        let b = Int(idOffsets[ei + 1])
        guard a >= 0, b >= a, b <= idBlob.count else { return "" }
        return String(data: idBlob.subdata(in: a..<b), encoding: .utf8) ?? ""
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
    /// Confidence: 0 high, 1 medium, 2 low (bits 9–10).
    static func unpackConfidence(_ attr: UInt16) -> Int { Int((attr >> 9) & 3) }
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
}
