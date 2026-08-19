import Foundation

/// External links surfaced in Profile + the paywall.
/// Canonical marketing + legal host: https://dirtmoto.app
/// Trailing slashes match the live Astro routes (non-slash 301s to slash).
enum LegalLinks {
    static let website = URL(string: "https://dirtmoto.app/")!
    static let privacyPolicy = URL(string: "https://dirtmoto.app/privacy/")!
    static let termsOfUse = URL(string: "https://dirtmoto.app/terms/")!
    static let eula = URL(string: "https://dirtmoto.app/eula/")!
    static let dataUse = URL(string: "https://dirtmoto.app/data/")!
    static let gdpr = URL(string: "https://dirtmoto.app/gdpr/")!
    static let support = URL(string: "https://dirtmoto.app/support/")!
    static let subscriptions = URL(string: "https://dirtmoto.app/subscriptions/")!

    /// Apple's standard hosted EULA — fallback only. Prefer `eula` (hosted on dirtmoto.app).
    static let appleStandardEULA = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}
