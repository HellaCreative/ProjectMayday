import Foundation
import CryptoKit

public struct PackEnums: Decodable, Sendable {
    let surfaceLeafNames: [String]
    let roadClassLeafNames: [String]
    let structureLeafNames: [String]
    let accessLeafNames: [String]
    let surfaceFamilyMap: [String: String]?
    let roadTierMap: [String: String]?
}

public struct GeographicBox: Codable, Sendable {
    public let minLat: Double
    public let maxLat: Double
    public let minLon: Double
    public let maxLon: Double
    public let name: String?
    func contains(_ p: Coordinate) -> Bool {
        p.latitude >= minLat && p.latitude <= maxLat && p.longitude >= minLon && p.longitude <= maxLon
    }
    func intersects(_ a: Coordinate, _ b: Coordinate) -> Bool {
        let dx = b.longitude - a.longitude, dy = b.latitude - a.latitude
        var lo = 0.0, hi = 1.0
        for (p,q) in [(-dx,a.longitude-minLon), (dx,maxLon-a.longitude),
                      (-dy,a.latitude-minLat), (dy,maxLat-a.latitude)] {
            if p == 0 { if q < 0 { return false }; continue }
            let r = q / p
            if p < 0 { lo = max(lo,r) } else { hi = min(hi,r) }
            if lo > hi { return false }
        }
        return true
    }
}

public struct PackMetadata: Decodable, Sendable {
    public let regionId: String?
    public let sourceEpoch: String?
    public let urbanCores: [GeographicBox]?
}

/// V4 codec independently translated from pack-v4.js. All routing inputs are local.
/// Typed columns access the same mapped file; there are no province-sized decoded copies.
public final class GraphPack: Sendable {
    private let file: BinaryFile
    private let geometry: BinaryFile
    public let nodeCount: Int
    public let edgeCount: Int
    public let arcCount: Int
    public let graphSHA256: String
    public let geometrySHA256: String
    public let sourceEpoch: String?
    public let metadata: PackMetadata
    public let barriers: [Int:UInt8]
    public let restrictions: [TurnRestriction]
    public let restrictionIndex: RestrictionIndex
    public let enums: PackEnums
    let nodeOffsets: MappedColumn<Int32>
    let targets: MappedColumn<Int32>
    let arcEdges: MappedColumn<Int32>
    let edgeFrom: MappedColumn<Int32>
    let edgeTo: MappedColumn<Int32>
    let meters: MappedColumn<UInt32>
    let attrs: MappedColumn<UInt16>
    let coordinates: MappedColumn<UInt32>
    let access: MappedColumn<UInt8>
    let ways: MappedColumn<Int64>
    let nodes: MappedColumn<Int64>
    let surfaces: MappedColumn<UInt8>
    let roads: MappedColumn<UInt8>
    let structures: MappedColumn<UInt8>
    let layers: MappedColumn<Int8>
    let accessLeaves: MappedColumn<UInt8>
    let edgeFlags: MappedColumn<UInt8>
    let crossingSeconds: MappedColumn<UInt32>
    let geometryOffsets: MappedColumn<Int32>
    let geometryCoordinatesOffset: Int
    let geometryIsDouble: Bool
    let derivedIDs: Bool
    let idOffsets: MappedColumn<Int32>?
    let idBlobOffset: Int

    /// Planning envelope only. Reads graph node columns without opening road
    /// geometry or preparing legal search state. Matching still proves the road.
    static func nodeBounds(_ file: BinaryFile, budget: ComputationBudget) throws -> GeographicBox {
        guard try file.read(0, as: UInt32.self) == 0x34545244,
              try file.read(4, as: UInt16.self) == 4,
              try file.read(20, as: UInt32.self) == 140 else { throw RoutingFailure.invalidPack("V4 header required") }
        let count = Int(try file.read(8, as: UInt32.self))
        let offset = Int(try file.read(44, as: UInt32.self))
        guard count > 0, offset >= 140 else { throw RoutingFailure.invalidPack("empty node envelope") }
        let column = try MappedColumn(file: file, offset: offset, count: count * 2) as MappedColumn<UInt32>
        var west = 180.0, east = -180.0, south = 90.0, north = -90.0
        for node in 0..<count {
            if node & 4095 == 0 { try budget.check() }
            let point = Coordinate(longitude: Double(Float(bitPattern: column[node * 2])),
                                   latitude: Double(Float(bitPattern: column[node * 2 + 1])))
            guard point.isValid else { throw RoutingFailure.invalidPack("node envelope coordinate") }
            west = min(west, point.longitude); east = max(east, point.longitude)
            south = min(south, point.latitude); north = max(north, point.latitude)
        }
        return .init(minLat: south, maxLat: north, minLon: west, maxLon: east, name: nil)
    }

    public convenience init(graphURL: URL, geometryURL: URL, budget: ComputationBudget = .init(seconds: 60)) throws {
        try self.init(graph: BinaryFile(url: graphURL), geometry: BinaryFile(url: geometryURL), budget: budget)
    }
    init(graph: BinaryFile, geometry: BinaryFile, budget: ComputationBudget,
         structuralValidation: Bool = true) throws {
        try budget.check()
        try graph.range(0, 140)
        guard try graph.read(0, as: UInt32.self) == 0x34545244,
              try graph.read(4, as: UInt16.self) == 4,
              try graph.read(20, as: UInt32.self) == 140 else { throw RoutingFailure.invalidPack("V4 header required") }
        let flags = try graph.read(6, as: UInt16.self)
        guard flags & 11 == 11 else { throw RoutingFailure.invalidPack("missing legal topology or leaves") }
        let n = Int(try graph.read(8, as: UInt32.self))
        let e = Int(try graph.read(12, as: UInt32.self))
        let arcs = Int(try graph.read(16, as: UInt32.self))
        func offset(_ header: Int) throws -> Int {
            let value = Int(try graph.read(header, as: UInt32.self))
            guard value >= 140, value <= graph.data.count else { throw RoutingFailure.invalidPack("missing section \(header)") }
            return value
        }
        func column<T>(_ header: Int, _ count: Int, _ type: T.Type) throws -> MappedColumn<T> {
            try MappedColumn(file: graph, offset: offset(header), count: count)
        }
        nodeCount = n; edgeCount = e; arcCount = arcs
        file = graph; self.geometry = geometry
        nodeOffsets = try column(24,n+1,Int32.self)
        targets = try column(28,arcs,Int32.self); arcEdges = try column(32,arcs,Int32.self)
        edgeFrom = try column(64,e,Int32.self); edgeTo = try column(68,e,Int32.self)
        meters = try column(40,e,UInt32.self); attrs = try column(36,e,UInt16.self)
        coordinates = try column(44,n*2,UInt32.self)
        access = try column(112,e*2,UInt8.self)
        nodes = try column(104,n,Int64.self); ways = try column(108,e,Int64.self)
        surfaces = try column(72,e,UInt8.self); roads = try column(76,e,UInt8.self)
        accessLeaves = try column(92,e,UInt8.self); edgeFlags = try column(96,e,UInt8.self)
        layers = try column(84,e,Int8.self)
        structures = try column(88,e,UInt8.self); crossingSeconds = try column(100,e,UInt32.self)
        let capabilities = try graph.json(offset(132),offset(136),as: [String].self)
        guard capabilities.contains("legal-topology.v1") else { throw RoutingFailure.invalidPack("missing legal-topology.v1") }
        enums = try graph.json(offset(56),offset(60),as: PackEnums.self)
        metadata = try graph.json(offset(60),offset(72),as: PackMetadata.self)
        sourceEpoch = try graph.json(offset(128),offset(132),as: PackMetadata.self).sourceEpoch
        // BinaryFile memoizes SHA256; reuse the same digest for identity and fields.
        graphSHA256 = graph.sha256
        let geometryDigest = geometry.sha256Digest()
        geometrySHA256 = geometry.sha256
        let identityAt = try offset(136)
        try graph.range(identityAt,32)
        guard geometryDigest == graph.data.subdata(in: identityAt..<(identityAt+32)) else {
            throw RoutingFailure.invalidPack("graph/geometry identity mismatch")
        }
        try budget.check()
        try geometry.range(0,16)
        guard try geometry.read(0,as: UInt32.self) == 0x4d4f4547,
              try geometry.read(4,as: UInt16.self) == 1,
              try geometry.read(8,as: UInt32.self) == UInt32(e) else { throw RoutingFailure.invalidPack("geometry header") }
        geometryOffsets = try MappedColumn(file: geometry,offset: 16,count: e+1)
        geometryIsDouble = try geometry.read(6,as: UInt16.self) & 1 != 0
        let width = geometryIsDouble ? 8 : 4
        geometryCoordinatesOffset = ((16+(e+1)*4+width-1)/width)*width
        let coordinateCount = Int(try geometry.read(12,as: UInt32.self))
        try geometry.range(geometryCoordinatesOffset,coordinateCount,stride: width)
        derivedIDs = flags & 16 != 0
        idOffsets = try derivedIDs ? nil : column(48,e+1,Int32.self)
        idBlobOffset = try offset(52)
        guard nodeOffsets[0] == 0, nodeOffsets[n] == arcs else { throw RoutingFailure.invalidPack("adjacency bounds") }
        if structuralValidation {
            for i in 0..<n {
                if i & 4095 == 0 { try budget.check() }
                guard nodeOffsets[i] >= 0, nodeOffsets[i] <= nodeOffsets[i+1], nodeOffsets[i+1] <= arcs else {
                    throw RoutingFailure.invalidPack("adjacency order")
                }
                let point = Coordinate(longitude: Double(Float(bitPattern: coordinates[i*2])), latitude: Double(Float(bitPattern: coordinates[i*2+1])))
                guard point.isValid else { throw RoutingFailure.invalidPack("coordinate") }
                for a in Int(nodeOffsets[i])..<Int(nodeOffsets[i+1]) {
                    let ei = Int(arcEdges[a]), target = Int(targets[a])
                    guard ei >= 0, ei < e, target >= 0, target < n else { throw RoutingFailure.invalidPack("arc index") }
                    guard (edgeFrom[ei] == i && edgeTo[ei] == target) || (edgeTo[ei] == i && edgeFrom[ei] == target) else {
                        throw RoutingFailure.invalidPack("arc endpoints")
                    }
                }
            }
            guard geometryOffsets[0] == 0, geometryOffsets[e] == coordinateCount else { throw RoutingFailure.invalidPack("geometry bounds") }
            for i in 0..<e {
                if i & 4095 == 0 { try budget.check() }
                guard edgeFrom[i] >= 0, edgeFrom[i] < n, edgeTo[i] >= 0, edgeTo[i] < n,
                      access[i*2] <= 5, access[i*2+1] <= 5,
                      Int(surfaces[i]) < enums.surfaceLeafNames.count, Int(roads[i]) < enums.roadClassLeafNames.count,
                      Int(structures[i]) < enums.structureLeafNames.count,
                      Int(accessLeaves[i]) < enums.accessLeafNames.count,
                      geometryOffsets[i] >= 0, geometryOffsets[i] <= geometryOffsets[i+1],
                      geometryOffsets[i+1] <= coordinateCount, geometryOffsets[i] % 2 == 0 else {
                    throw RoutingFailure.invalidPack("edge facts")
                }
                if let ids = idOffsets {
                    guard ids[i] >= 0, ids[i] <= ids[i+1], idBlobOffset + Int(ids[i+1]) <= (try offset(56)) else {
                        throw RoutingFailure.invalidPack("edge identity bounds")
                    }
                }
            }
        } else {
            guard geometryOffsets[0] == 0, geometryOffsets[e] == coordinateCount else {
                throw RoutingFailure.invalidPack("geometry bounds")
            }
        }
        let barrierAt = try offset(116), barrierEnd = try offset(120)
        let barrierCount = Int(try graph.read(barrierAt,as: UInt32.self))
        guard barrierCount <= (barrierEnd-barrierAt-4)/16 else { throw RoutingFailure.invalidPack("barrier section") }
        var parsedBarriers: [Int:UInt8] = [:]
        for i in 0..<barrierCount {
            let at = barrierAt+4+i*16
            let node = Int(try graph.read(at+8,as: UInt32.self))
            guard node < n, try graph.read(at+12,as: UInt8.self) <= 5 else { throw RoutingFailure.invalidPack("barrier record") }
            parsedBarriers[node] = try graph.read(at+12,as: UInt8.self)
        }
        barriers = parsedBarriers
        let restAt = try offset(120), restEnd = try offset(124)
        let count = Int(try graph.read(restAt,as: UInt32.self))
        guard count <= (restEnd-restAt-4)/32 else { throw RoutingFailure.invalidPack("restriction count") }
        var cursor = restAt+4, parsed: [TurnRestriction] = []
        for i in 0..<count {
            if i & 1023 == 0 { try budget.check() }
            guard cursor+32 <= restEnd else { throw RoutingFailure.invalidPack("restriction header") }
            let viaCount = Int(try graph.read(cursor+10,as: UInt16.self))
            guard viaCount <= (restEnd-cursor-32)/12 else { throw RoutingFailure.invalidPack("restriction via edges") }
            var via: [Int] = []
            for v in 0..<viaCount {
                let edge = Int(try graph.read(cursor+40+v*12,as: Int32.self))
                if edge >= 0 { guard edge < e else { throw RoutingFailure.invalidPack("via index") }; via.append(edge) }
            }
            let from = Int(try graph.read(cursor+12,as: UInt32.self)), to = Int(try graph.read(cursor+16,as: UInt32.self))
            let node = Int(try graph.read(cursor+20,as: Int32.self))
            guard from < e, to < e, node >= -1, node < n else { throw RoutingFailure.invalidPack("restriction index") }
            parsed.append(.init(relationID: try graph.read(cursor,as: Int64.self),fromEdge: from,toEdge: to,viaNode: node,
                                viaEdges: via,only: try graph.read(cursor+9,as: UInt8.self) & 2 != 0,
                                vehicleMask: try graph.read(cursor+26,as: UInt16.self)))
            cursor += 32+viaCount*12
        }
        restrictions = parsed
        restrictionIndex = RestrictionIndex(parsed)
    }

    public func coordinate(node: Int) -> Coordinate {
        Coordinate(longitude: Double(Float(bitPattern: coordinates[node*2])),latitude: Double(Float(bitPattern: coordinates[node*2+1])))
    }
    public func edgeID(_ edge: Int) -> String {
        if derivedIDs { return "w\(ways[edge]):\(edgeFrom[edge]):\(edgeTo[edge])" }
        guard let ids = idOffsets else { return "" }
        return String(decoding: file.data[(idBlobOffset+Int(ids[edge]))..<(idBlobOffset+Int(ids[edge+1]))],as: UTF8.self)
    }
    public func osmNodeID(_ node: Int) -> Int64 { nodes[node] }
    public func osmWayID(_ edge: Int) -> Int64 { ways[edge] }
    public func distance(_ edge: Int) -> Double { Double(meters[edge]) }
    public func accessCode(_ edge: Int, forward: Bool) -> UInt8 { access[edge*2+(forward ? 0 : 1)] }
    public func surfaceLeaf(_ edge: Int) -> String { enums.surfaceLeafNames[Int(surfaces[edge])] }
    public func roadClass(_ edge: Int) -> String { enums.roadClassLeafNames[Int(roads[edge])] }
    public func accessLeaf(_ edge: Int) -> String { enums.accessLeafNames[Int(accessLeaves[edge])] }
    public func atvDesignated(_ edge: Int) -> Bool { edgeFlags[edge] & 1 != 0 }
    public func layer(_ edge: Int) -> Int { Int(layers[edge]) }
    public func structure(_ edge: Int) -> String {
        let leaf = enums.structureLeafNames[Int(structures[edge])]
        if !leaf.isEmpty { return leaf }
        // fabric-v4 packs keep ferry timing (and coarse attrs bit ferry=4) but
        // omit structureLeaf "ferry" from the leaf dictionary. crossingSeconds
        // is ferry-only in the pack contract — restore the UI/routing signifier.
        if crossingSeconds[edge] > 0 { return "ferry" }
        if (attrs[edge] >> 6) & 7 == 4 { return "ferry" }
        return leaf
    }
    public func polyline(_ edge: Int) -> [Coordinate] {
        let start = Int(geometryOffsets[edge]), end = Int(geometryOffsets[edge+1])
        return stride(from: start,to: end,by: 2).map { i in
            if geometryIsDouble {
                return Coordinate(longitude: Double(bitPattern: geometry.unchecked(geometryCoordinatesOffset+i*8,as: UInt64.self)),
                                  latitude: Double(bitPattern: geometry.unchecked(geometryCoordinatesOffset+(i+1)*8,as: UInt64.self)))
            }
            return Coordinate(longitude: Double(Float(bitPattern: geometry.unchecked(geometryCoordinatesOffset+i*4,as: UInt32.self))),
                              latitude: Double(Float(bitPattern: geometry.unchecked(geometryCoordinatesOffset+(i+1)*4,as: UInt32.self))))
        }
    }
}
