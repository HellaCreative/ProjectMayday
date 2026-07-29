import Compression
import Foundation

// MARK: - Gzip decompression

extension Data {
    /// Decompress gzip-encoded data.  Strips the gzip header/trailer and
    /// raw-DEFLATE-decodes the payload using the system Compression framework.
    /// `nonisolated` so background `Task.detached` decode paths stay off the main actor
    /// under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
    nonisolated func gunzipped() throws -> Data {
        guard count > 18, self[0] == 0x1f, self[1] == 0x8b else {
            throw URLError(.cannotDecodeRawData)
        }
        let flags = self[3]
        var off = 10
        if flags & 0x04 != 0 {                          // FEXTRA
            guard off + 2 <= count else { throw URLError(.cannotDecodeRawData) }
            off += 2 + (Int(self[off]) | (Int(self[off + 1]) << 8))
        }
        if flags & 0x08 != 0 {                          // FNAME (null-terminated)
            while off < count, self[off] != 0 { off += 1 }
            off += 1
        }
        if flags & 0x10 != 0 {                          // FCOMMENT (null-terminated)
            while off < count, self[off] != 0 { off += 1 }
            off += 1
        }
        if flags & 0x02 != 0 { off += 2 }              // FHCRC
        guard off + 8 <= count else { throw URLError(.cannotDecodeRawData) }

        let payload = subdata(in: off..<(count - 8))
        // Text/JSON gzip typically compresses 5–15×; allocate 8× with 16 KB floor.
        let capacity = Swift.max(payload.count * 8, 16_384)
        var out = [UInt8](repeating: 0, count: capacity)
        let written = payload.withUnsafeBytes { src -> Int in
            guard let ptr = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return compression_decode_buffer(&out, capacity, ptr, payload.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { throw URLError(.cannotDecodeRawData) }
        return Data(out.prefix(written))
    }
}

// MARK: - Layer preference snapshot (UserDefaults mirror, no SwiftUI dependency)

/// Read-once snapshot of all Layers preferences from UserDefaults.
/// Use this in UIKit / Coordinator / Manager contexts where @AppStorage is unavailable.
struct LayerPrefsSnapshot {
    let showFuel: Bool
    let showCampgrounds: Bool
    let showLodging: Bool
    let showLiquor: Bool
    let showNSLines: Bool
    let showNBLines: Bool
    let showQCLines: Bool
    let showONLines: Bool
    let showBCLines: Bool
    let showABLines: Bool

    init() {
        let ud = UserDefaults.standard
        showFuel        = ud.bool(forKey: "dirt.layers.fuel")
        showCampgrounds = ud.bool(forKey: "dirt.layers.camp")
        showLodging     = ud.bool(forKey: "dirt.layers.lodging")
        showLiquor      = ud.bool(forKey: "dirt.layers.liquor")
        showNSLines     = ud.bool(forKey: "dirt.layers.network.ns")
        showNBLines     = ud.bool(forKey: "dirt.layers.network.nb")
        showQCLines     = ud.bool(forKey: "dirt.layers.network.qc")
        showONLines     = ud.bool(forKey: "dirt.layers.network.on")
        showBCLines     = ud.bool(forKey: "dirt.layers.network.bc")
        showABLines     = ud.bool(forKey: "dirt.layers.network.ab")
    }

    var anyPOIEnabled: Bool { showFuel || showCampgrounds || showLodging || showLiquor }
    var anyProvinceEnabled: Bool {
        showNSLines || showNBLines || showQCLines || showONLines || showBCLines || showABLines
    }

    /// Selected province for viewport-lens mode (HTML mutual exclusion). Nil = corridor-only.
    var lensProvince: String? {
        if showNSLines { return "NS" }
        if showNBLines { return "NB" }
        if showQCLines { return "QC" }
        if showONLines { return "ON" }
        if showBCLines { return "BC" }
        if showABLines { return "AB" }
        return nil
    }

    func isPOIEnabled(category: String) -> Bool {
        switch category {
        case "fuel":       return showFuel
        case "campground": return showCampgrounds
        case "lodging":    return showLodging
        case "liquor":     return showLiquor
        default:           return false
        }
    }
}
