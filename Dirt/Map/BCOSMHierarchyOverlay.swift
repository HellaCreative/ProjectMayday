import Foundation
import Observation

/// Retired BC OSM mbtiles experiment. The class stays in the target so
/// `project.pbxproj` does not need a delete; it never starts a tile proxy.
@MainActor
@Observable
final class BCOSMHierarchyOverlay {
    static let prefsKey = "dirt.layers.bc.osmHierarchy"

    private(set) var tileURLTemplate: String?
    private(set) var generation = 0
    private(set) var statusMessage: String?
    private(set) var isActive = false

    init(mapState: MapState) {
        _ = mapState
        UserDefaults.standard.set(false, forKey: Self.prefsKey)
    }

    func applyPrefs() {
        UserDefaults.standard.set(false, forKey: Self.prefsKey)
        isActive = false
        tileURLTemplate = nil
        statusMessage = nil
    }
}
