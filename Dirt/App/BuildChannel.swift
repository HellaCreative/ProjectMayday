import Foundation

/// Build / distribution channel helpers.
///
/// Tester unlock ships in **every** configuration (Debug + Release/TestFlight)
/// until Sign in with Apple works. Flip `allowPreReleaseTesterUnlock` to
/// `false` before public App Store freeze.
enum BuildChannel {
    /// Temporary. Set `false` when Apple Sign-In + trial are verified for store.
    static let allowPreReleaseTesterUnlock = true

    /// Whether onboarding / Profile / paywall tester controls should appear.
    /// Not behind `#if DEBUG` — Release archives must include this for TestFlight.
    static var showsTesterUnlock: Bool { allowPreReleaseTesterUnlock }
}
