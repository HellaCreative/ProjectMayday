import Foundation

/// Build / distribution channel helpers.
///
enum BuildChannel {
    /// Whether onboarding / Profile / paywall tester controls should appear.
    ///
    /// Public Release archives have no tester escape hatch. A deliberately
    /// configured pre-release build may opt in with the
    /// `DIRT_PRE_RELEASE_TESTER_UNLOCK` compilation condition.
    static var showsTesterUnlock: Bool {
        #if DEBUG || DIRT_PRE_RELEASE_TESTER_UNLOCK
        true
        #else
        false
        #endif
    }

    /// Pure policy used by focused tests so the public-release invariant cannot
    /// regress behind a forgotten runtime flag.
    static func testerUnlockAllowed(debugBuild: Bool, preReleaseOptIn: Bool) -> Bool {
        debugBuild || preReleaseOptIn
    }

    /// Routing-graph debug overlay. Debug builds only — not TestFlight/App Store.
    static var debugRoutingGraphOverlay: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
