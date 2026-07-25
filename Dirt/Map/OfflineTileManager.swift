import Foundation
import MapLibre
import Observation

/// Best-effort offline corridor cache for navigation, using MapLibre offline
/// packs (bounding-box pyramid, z8–14 — not a true corridor; documented limit).
///
/// Session rules from the web POC:
/// 1. Prefetch only on Start Navigation.
/// 2. Same route identity → keep the pack and let MapLibre top up.
/// 3. Mid-trip recalculation keeps tiles; a new corridor pack is added.
/// 4. Packs for a different route identity are removed when a new navigation
///    session starts. Ending navigation never wipes the cache by itself.
@Observable
final class OfflineTileManager {
    private(set) var isPrefetching = false
    private(set) var progress: Double = 0
    private(set) var currentIdentity: String?
    private var progressObserver: NSObjectProtocol?
    private var completion: (() -> Void)?

    func startPrefetch(identity: String, coordinates: [RouteCoordinate], keepExisting: Bool, completion: @escaping () -> Void) {
        guard coordinates.count > 1 else {
            completion()
            return
        }
        finishObserving()
        self.completion = completion
        currentIdentity = identity
        isPrefetching = true
        progress = 0

        let storage = MLNOfflineStorage.shared
        let identityData = Data(identity.utf8)

        if !keepExisting {
            for pack in storage.packs ?? [] where pack.context != identityData {
                storage.removePack(pack, withCompletionHandler: nil)
            }
        }

        var south = coordinates[0].latitude
        var north = coordinates[0].latitude
        var west = coordinates[0].longitude
        var east = coordinates[0].longitude
        for coordinate in coordinates {
            south = min(south, coordinate.latitude)
            north = max(north, coordinate.latitude)
            west = min(west, coordinate.longitude)
            east = max(east, coordinate.longitude)
        }
        let pad = 0.02
        let bounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: south - pad, longitude: west - pad),
            ne: CLLocationCoordinate2D(latitude: north + pad, longitude: east + pad)
        )
        let region = MLNTilePyramidOfflineRegion(styleURL: AppConfig.mapStyleURL, bounds: bounds, fromZoomLevel: 8, toZoomLevel: 14)

        progressObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.MLNOfflinePackProgressChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let pack = notification.object as? MLNOfflinePack else { return }
            guard pack.context == identityData else { return }
            let done = Double(pack.progress.countOfResourcesCompleted)
            let expected = max(1, Double(pack.progress.countOfResourcesExpected))
            self.progress = min(1, done / expected)
            if pack.state == .complete || self.progress >= 0.999 {
                self.finish()
            }
        }

        if let existing = (storage.packs ?? []).first(where: { $0.context == identityData }) {
            existing.resume()
        } else {
            storage.addPack(for: region, withContext: identityData) { [weak self] pack, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let pack {
                        pack.resume()
                    } else {
                        _ = error
                        self.finish()
                    }
                }
            }
        }

        // Never block the ride start on a slow network: cap the wait.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            self?.finish()
        }
    }

    func skip() {
        finish()
    }

    private func finish() {
        guard isPrefetching else { return }
        isPrefetching = false
        finishObserving()
        let callback = completion
        completion = nil
        callback?()
    }

    private func finishObserving() {
        if let progressObserver {
            NotificationCenter.default.removeObserver(progressObserver)
            self.progressObserver = nil
        }
    }
}
