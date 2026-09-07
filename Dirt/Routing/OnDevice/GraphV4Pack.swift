import CryptoKit
import Foundation

/// Decoder for `graph.v4.bin`. Rejects V3 magic, missing capabilities, and
/// missing restriction/barrier/access sections. Does not silently ignore safety data.
nonisolated final class GraphV4Pack: @unchecked Sendable {
    static let magic: UInt32 = 0x3454_5244
    static let version: UInt16 = 4
    static let headerSize = 140
    static let flagLegalTopology: UInt16 = 8
    static let requiredCapability = "legal-topology.v1"

    struct Restriction: Sendable {
        let osmRelationId: Int64
        let kind: UInt8
        let fromEdge: Int
        let toEdge: Int
        let viaNode: Int
        let only: Bool
        let vehicleMask: UInt16
    }

    enum PackError: Error {
        case unsupportedVersion
        case missingCapability
        case missingSafetySection
        case geometryMismatch
        case mixedContract
        case truncated
    }

    let version: UInt16
    let nodeCount: Int
    let undirectedEdgeCount: Int
    let directedArcCount: Int
    let capabilities: [String]
    let osmNodeIds: [Int64]
    let osmWayIds: [Int64]
    let edgeAccess: [UInt8]
    let restrictions: [Restriction]
    let barrierCount: Int
    let geometrySha256: Data
    let provenanceJSON: [String: Any]

    init(data: Data, geometry: Data? = nil) throws {
        guard data.count >= Self.headerSize else { throw PackError.truncated }
        let magic: UInt32 = data.readUInt32LE(0)
        let ver: UInt16 = data.readUInt16LE(4)
        guard magic == Self.magic, ver == Self.version else {
            throw PackError.unsupportedVersion
        }
        let flags: UInt16 = data.readUInt16LE(6)
        guard (flags & Self.flagLegalTopology) != 0 else {
            throw PackError.missingCapability
        }
        let headerSize = Int(data.readUInt32LE(20))
        guard headerSize >= Self.headerSize else { throw PackError.missingSafetySection }
        for off in [104, 108, 112, 116, 120, 124, 128, 132, 136] {
            if data.readUInt32LE(off) == 0 { throw PackError.missingSafetySection }
        }
        version = ver
        nodeCount = Int(data.readUInt32LE(8))
        undirectedEdgeCount = Int(data.readUInt32LE(12))
        directedArcCount = Int(data.readUInt32LE(16))

        let capAt = Int(data.readUInt32LE(132))
        let shaAt = Int(data.readUInt32LE(136))
        guard capAt < shaAt, shaAt + 32 <= data.count else { throw PackError.truncated }
        let capData = data.subdata(in: capAt..<shaAt)
        let caps = (try? JSONSerialization.jsonObject(with: capData) as? [String]) ?? []
        guard caps.contains(Self.requiredCapability) else { throw PackError.missingCapability }
        capabilities = caps

        geometrySha256 = data.subdata(in: shaAt..<(shaAt + 32))
        if let geometry {
            let digest = Data(SHA256.hash(data: geometry))
            guard digest == geometrySha256 else { throw PackError.geometryMismatch }
        }

        let provAt = Int(data.readUInt32LE(128))
        let provData = data.subdata(in: provAt..<capAt)
        provenanceJSON = (try? JSONSerialization.jsonObject(with: provData) as? [String: Any]) ?? [:]

        let accessAt = Int(data.readUInt32LE(112))
        edgeAccess = Array(data.subdata(in: accessAt..<(accessAt + undirectedEdgeCount * 2)))

        let nodeAt = Int(data.readUInt32LE(104))
        var nodes: [Int64] = []
        nodes.reserveCapacity(nodeCount)
        for i in 0..<nodeCount {
            nodes.append(data.readInt64LE(nodeAt + i * 8))
        }
        osmNodeIds = nodes

        let wayAt = Int(data.readUInt32LE(108))
        var ways: [Int64] = []
        ways.reserveCapacity(undirectedEdgeCount)
        for i in 0..<undirectedEdgeCount {
            ways.append(data.readInt64LE(wayAt + i * 8))
        }
        osmWayIds = ways

        let barAt = Int(data.readUInt32LE(116))
        barrierCount = Int(data.readUInt32LE(barAt))

        let restAt = Int(data.readUInt32LE(120))
        let restCount = Int(data.readUInt32LE(restAt))
        var parsed: [Restriction] = []
        var cursor = restAt + 4
        for _ in 0..<restCount {
            let viaWayCount = Int(data.readUInt16LE(cursor + 10))
            parsed.append(
                Restriction(
                    osmRelationId: data.readInt64LE(cursor),
                    kind: data[cursor + 8],
                    fromEdge: Int(data.readUInt32LE(cursor + 12)),
                    toEdge: Int(data.readUInt32LE(cursor + 16)),
                    viaNode: Int(data.readInt32LE(cursor + 20)),
                    only: (data[cursor + 9] & 2) != 0,
                    vehicleMask: data.readUInt16LE(cursor + 26)
                )
            )
            cursor += 32 + viaWayCount * 12
        }
        restrictions = parsed
    }

    static func rejectMixedContract(epochs: [String]) throws {
        if Set(epochs).count > 1 { throw PackError.mixedContract }
    }

    func turnAllowed(fromEdge: Int, toEdge: Int, viaNode: Int) -> Bool {
        for r in restrictions where (r.vehicleMask & 1) != 0 {
            if r.fromEdge == fromEdge, r.toEdge == toEdge, r.viaNode == viaNode, !r.only {
                return false
            }
            if r.only, r.fromEdge == fromEdge, r.viaNode == viaNode, r.toEdge != toEdge {
                return false
            }
        }
        return true
    }
}

private extension Data {
    nonisolated func readUInt32LE(_ offset: Int) -> UInt32 {
        self[offset..<offset + 4].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    }

    nonisolated func readUInt16LE(_ offset: Int) -> UInt16 {
        self[offset..<offset + 2].withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
    }

    nonisolated func readInt32LE(_ offset: Int) -> Int32 {
        self[offset..<offset + 4].withUnsafeBytes { $0.load(as: Int32.self).littleEndian }
    }

    nonisolated func readInt64LE(_ offset: Int) -> Int64 {
        self[offset..<offset + 8].withUnsafeBytes { $0.load(as: Int64.self).littleEndian }
    }
}
