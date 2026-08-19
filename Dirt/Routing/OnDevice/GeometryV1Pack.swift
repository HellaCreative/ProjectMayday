import CoreLocation
import Foundation

/// Decoded `geometry.v1.bin` — per-edge road polylines for path paint.
/// Layout matches `routing/lib/pack-v2.js` `decodeGeometryV1`.
/// Opted out of `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` for off-main decode.
nonisolated final class GeometryV1Pack: @unchecked Sendable {
    static let magic: UInt32 = 0x4D4F_4547 // "GEOM"

    let data: Data
    let edgeCount: Int
    private let offsets: [Int32]
    /// Interleaved lon,lat (float32 or float64 depending on flags).
    private let coords32: [Float]?
    private let coords64: [Double]?

    init(data: Data) throws {
        self.data = data
        guard data.count >= 16 else { throw PackError.truncated }
        let magic: UInt32 = data.readUInt32LE(0)
        guard magic == Self.magic else { throw PackError.badMagic }
        edgeCount = Int(data.readUInt32LE(8))
        let coordCount = Int(data.readUInt32LE(12))
        let flags: UInt16 = data.readUInt16LE(6)
        let useFloat64 = (flags & 1) != 0

        let header = 16
        offsets = data.readInt32Array(at: header, count: edgeCount + 1)
        var coordsAt = header + (edgeCount + 1) * 4
        if coordsAt % 4 != 0 { coordsAt += 4 - (coordsAt % 4) }
        if useFloat64, coordsAt % 8 != 0 { coordsAt += 8 - (coordsAt % 8) }

        let bytesPer = useFloat64 ? 8 : 4
        let need = coordsAt + coordCount * bytesPer
        guard need <= data.count else { throw PackError.truncated }

        if useFloat64 {
            coords64 = data.readFloat64Array(at: coordsAt, count: coordCount)
            coords32 = nil
        } else {
            coords32 = data.readFloat32Array(at: coordsAt, count: coordCount)
            coords64 = nil
        }
    }

    /// Polyline for undirected edge `ei` as lon/lat coordinates.
    func polyline(edgeIndex ei: Int) -> [CLLocationCoordinate2D] {
        guard ei >= 0, ei < edgeCount else { return [] }
        let start = Int(offsets[ei])
        let end = Int(offsets[ei + 1])
        guard start >= 0, end >= start, end % 2 == 0 else { return [] }
        var out: [CLLocationCoordinate2D] = []
        out.reserveCapacity((end - start) / 2)
        var i = start
        while i + 1 < end {
            let lon: Double
            let lat: Double
            if let c64 = coords64 {
                lon = c64[i]
                lat = c64[i + 1]
            } else if let c32 = coords32 {
                lon = Double(c32[i])
                lat = Double(c32[i + 1])
            } else {
                break
            }
            out.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            i += 2
        }
        return out
    }

    func polyline(edgeIndex ei: Int, forward: Bool) -> [CLLocationCoordinate2D] {
        let coords = polyline(edgeIndex: ei)
        return forward ? coords : coords.reversed()
    }

    enum PackError: Error {
        case truncated
        case badMagic
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

    nonisolated func readFloat32Array(at offset: Int, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        let byteCount = count * 4
        return subdata(in: offset..<(offset + byteCount)).withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
    }

    nonisolated func readFloat64Array(at offset: Int, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let byteCount = count * 8
        return subdata(in: offset..<(offset + byteCount)).withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Double.self).prefix(count))
        }
    }
}
