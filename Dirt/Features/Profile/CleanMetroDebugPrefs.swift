import Foundation

/// DEBUG ONLY — Clean urban-core multiplier override for live pin tests.
/// Not rider UI. Default follows Allow major highways (off ×10, on ×2). When enabled, sends
/// `options.cleanMetroMultiplier` clamped 1…20.
enum CleanMetroDebugPrefs {
    static let enabledKey = "dirt.debug.cleanMetroOverride"
    static let valueKey = "dirt.debug.cleanMetroMultiplier"

    static var isOverrideEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Slider value 1…20. Unused until override is enabled.
    static var sliderValue: Double {
        get {
            let raw = UserDefaults.standard.object(forKey: valueKey) as? Double ?? 10
            return min(20, max(1, raw))
        }
        set {
            UserDefaults.standard.set(min(20, max(1, newValue)), forKey: valueKey)
        }
    }

    /// Value to put on `RouteRequestOptions`, or nil when not overriding.
    static var requestMultiplier: Double? {
        guard isOverrideEnabled else { return nil }
        return sliderValue
    }
}
