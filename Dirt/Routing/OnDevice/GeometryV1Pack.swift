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
    private let coordsAt: Int
    private let useFloat64: Bool

    init(data: Data) throws {
        let measurement = RoutingWorkContext.measurement
        let decodePhase = measurement?.begin(.decode)
        defer { measurement?.end(decodePhase) }
        self.data = data
        guard data.count >= 16 else { throw PackError.truncated }
        let magic: UInt32 = data.readUInt32LE(0)
        guard magic == Self.magic else { throw PackError.badMagic }
        edgeCount = Int(data.readUInt32LE(8))
        let coordCount = Int(data.readUInt32LE(12))
        let flags: UInt16 = data.readUInt16LE(6)
        useFloat64 = (flags & 1) != 0

        let header = 16
        offsets = data.readInt32Array(at: header, count: edgeCount + 1)
        var coordinateOffset = header + (edgeCount + 1) * 4
        if coordinateOffset % 4 != 0 { coordinateOffset += 4 - (coordinateOffset % 4) }
        if useFloat64, coordinateOffset % 8 != 0 { coordinateOffset += 8 - (coordinateOffset % 8) }
        coordsAt = coordinateOffset

        let bytesPer = useFloat64 ? 8 : 4
        let need = coordsAt + coordCount * bytesPer
        guard need <= data.count else { throw PackError.truncated }
    }

    /// Polyline for undirected edge `ei` as lon/lat coordinates.
    func polyline(edgeIndex ei: Int) -> [CLLocationCoordinate2D] {
        guard ei >= 0, ei < edgeCount else { return [] }
        let start = Int(offsets[ei])
        let end = Int(offsets[ei + 1])
        guard start >= 0, end >= start, end % 2 == 0 else { return [] }
        var out: [CLLocationCoordinate2D] = []
        out.reserveCapacity((end - start) / 2)
        data.withUnsafeBytes { raw in
            var i = start
            while i + 1 < end {
                let lon: Double
                let lat: Double
                if useFloat64 {
                    lon = Double(bitPattern: raw.loadUnaligned(
                        fromByteOffset: coordsAt + i * 8, as: UInt64.self
                    ).littleEndian)
                    lat = Double(bitPattern: raw.loadUnaligned(
                        fromByteOffset: coordsAt + (i + 1) * 8, as: UInt64.self
                    ).littleEndian)
                } else {
                    lon = Double(Float(bitPattern: raw.loadUnaligned(
                        fromByteOffset: coordsAt + i * 4, as: UInt32.self
                    ).littleEndian))
                    lat = Double(Float(bitPattern: raw.loadUnaligned(
                        fromByteOffset: coordsAt + (i + 1) * 4, as: UInt32.self
                    ).littleEndian))
                }
                out.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                i += 2
            }
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
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }

    nonisolated func readUInt16LE(_ offset: Int) -> UInt16 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian }
    }

    nonisolated func readInt32Array(at offset: Int, count: Int) -> [Int32] {
        guard count > 0 else { return [] }
        return withUnsafeBytes { raw in
            (0..<count).map { raw.loadUnaligned(fromByteOffset: offset + $0 * 4, as: Int32.self).littleEndian }
        }
    }

}
