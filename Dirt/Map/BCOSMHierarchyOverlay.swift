import Foundation
import Observation

/// Feasibility-test overlay: paints bundled `BC.mbtiles` OSM hierarchy
/// (motorway → path/cycleway, no footway) via a localhost vector-tile proxy.
///
/// Does **not** replace on-device routing packs — visual evaluation only.
@MainActor
@Observable
final class BCOSMHierarchyOverlay {
    static let prefsKey = "dirt.layers.bc.osmHierarchy"

    private(set) var tileURLTemplate: String?
    private(set) var generation = 0
    private(set) var statusMessage: String?
    private(set) var isActive = false

    @ObservationIgnored private weak var mapState: MapState?
    @ObservationIgnored private var proxy: MBTilesVectorProxy?
    @ObservationIgnored private var startTask: Task<Void, Never>?

    init(mapState: MapState) {
        self.mapState = mapState
    }

    /// Resolution order for Xcode → device runs:
    /// 1. `DIRT_BC_MBTILES` env override
    /// 2. App bundle `BC.mbtiles` (copied from `Dirt/Resources` via synchronized group)
    /// 3. Documents `BC.mbtiles` (optional sideload)
    static func resolveMBTilesURL() -> URL? {
        if let env = ProcessInfo.processInfo.environment["DIRT_BC_MBTILES"], !env.isEmpty {
            let url = URL(fileURLWithPath: env)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let bundled = Bundle.main.url(forResource: "BC", withExtension: "mbtiles") {
            return bundled
        }
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let copy = docs.appendingPathComponent("BC.mbtiles")
            if FileManager.default.fileExists(atPath: copy.path) { return copy }
        }
        return nil
    }

    func applyPrefs() {
        let want = UserDefaults.standard.bool(forKey: Self.prefsKey)
        if want {
            startIfNeeded()
        } else {
            stop()
        }
    }

    private func startIfNeeded() {
        if isActive, tileURLTemplate != nil { return }
        startTask?.cancel()
        startTask = Task { [weak self] in
            await self?.start()
        }
    }

    private func start() async {
        guard let url = Self.resolveMBTilesURL() else {
            let message = "Missing BC.mbtiles — run bash scripts/build-bc-tiles.sh, then rebuild (bundles Dirt/Resources/BC.mbtiles)."
            statusMessage = message
            isActive = false
            tileURLTemplate = nil
            bump(template: nil, message: message)
            return
        }
        let next = MBTilesVectorProxy(mbtilesURL: url)
        do {
            try await next.start()
            proxy?.stop()
            proxy = next
            tileURLTemplate = next.tileURLTemplate
            statusMessage = nil
            isActive = tileURLTemplate != nil
            bump(template: tileURLTemplate, message: nil)
        } catch {
            next.stop()
            statusMessage = error.localizedDescription
            isActive = false
            tileURLTemplate = nil
            bump(template: nil, message: statusMessage)
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        proxy?.stop()
        proxy = nil
        if isActive || tileURLTemplate != nil || statusMessage != nil {
            isActive = false
            tileURLTemplate = nil
            statusMessage = nil
            bump(template: nil, message: nil)
        }
    }

    private func bump(template: String?, message: String?) {
        generation += 1
        mapState?.updateBCOSMHierarchy(template: template, status: message)
    }
}
