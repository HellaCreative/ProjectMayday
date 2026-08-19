import Foundation
import UIKit

/// Profile preference: keep the screen on while Dirt is in the foreground.
///
/// Idle-timer policy:
/// - Preference default is **off** (opt-in).
/// - While the scene is **active**, disable the idle timer if the preference
///   is on **or** turn-by-turn navigation is running (nav always keeps awake).
/// - When entering background / inactive, always clear `isIdleTimerDisabled`
///   so we don’t leave the system locked awake after Dirt leaves the screen.
enum KeepAwakePrefs {
    static let key = "dirt.keepAwakeWhileUsing"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Apply `UIApplication.shared.isIdleTimerDisabled` for the current state.
    @MainActor
    static func sync(sceneActive: Bool, navigating: Bool) {
        let shouldKeepAwake = sceneActive && (isEnabled || navigating)
        UIApplication.shared.isIdleTimerDisabled = shouldKeepAwake
    }
}
