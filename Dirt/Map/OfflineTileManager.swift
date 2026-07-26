import Foundation
import MapLibre
import Observation

/// Offline corridor cache for navigation.
///
/// **Disabled:** MapLibre Native aborts with an uncaught `std::regex_error` on
/// the `DatabaseFileSource` thread when building/resuming offline packs for
/// styles whose `glyphs` URL contains `{fontstack}/{range}` templates (and our
/// earlier remote Shortbread sprite path was also root-relative / invalid).
/// Start Navigation must not touch offline packs until that path is proven safe.
@Observable
final class OfflineTileManager {
    /// Kill-switch — keep false. MapLibre offline packs crash this app today.
    static let offlinePacksEnabled = false

    private(set) var isPrefetching = false
    private(set) var progress: Double = 0
    private(set) var currentIdentity: String?

    init() {
        // Leftover packs from earlier builds auto-resume and re-trigger the
        // DatabaseFileSource regex_error crash. Wipe them on launch.
        Self.purgeAllPacks()
    }

    static func supportsPrefetch(styleURL: URL) -> Bool {
        guard offlinePacksEnabled else { return false }
        guard let scheme = styleURL.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    /// Removes every MapLibre offline pack. Safe to call repeatedly.
    static func purgeAllPacks() {
        let storage = MLNOfflineStorage.shared
        for pack in storage.packs ?? [] {
            storage.removePack(pack, withCompletionHandler: nil)
        }
    }

    func startPrefetch(
        identity: String,
        coordinates: [RouteCoordinate],
        keepExisting: Bool,
        completion: @escaping () -> Void
    ) {
        // Hard no-op: never create or resume packs while the MapLibre bug lives.
        _ = identity
        _ = coordinates
        _ = keepExisting
        isPrefetching = false
        progress = 0
        currentIdentity = nil
        completion()
    }

    func skip() {
        isPrefetching = false
        progress = 0
    }
}
