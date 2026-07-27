import Foundation

/// External links surfaced in Profile + the paywall.
///
/// NOTE: `dirtmoto.app` is a placeholder domain. Swap these for the real DIRT
/// marketing site, privacy policy, and terms once the domain is registered —
/// the App Store subscription review requires reachable privacy + terms URLs.
enum LegalLinks {
    static let website = URL(string: "https://dirtmoto.app")!
    static let privacyPolicy = URL(string: "https://dirtmoto.app/privacy")!
    static let termsOfUse = URL(string: "https://dirtmoto.app/terms")!

    /// Apple's standard hosted EULA. Acceptable for App Store review when you
    /// have not published your own terms yet.
    static let appleStandardEULA = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}
