import Foundation

/// First-run progress. Separate from auth and from the tester unlock: a tester
/// skipping Sign in with Apple must still see onboarding, because on TestFlight
/// the testers *are* the audience reviewing it.
enum OnboardingPrefs {
    private enum Key {
        static let intro = "dirt.onboarding.introDone.v2"
        static let coach = "dirt.onboarding.coachDone.v2"
    }

    static var introComplete: Bool {
        UserDefaults.standard.bool(forKey: Key.intro)
    }

    static var coachComplete: Bool {
        UserDefaults.standard.bool(forKey: Key.coach)
    }

    static func markIntroComplete() {
        UserDefaults.standard.set(true, forKey: Key.intro)
    }

    static func markCoachComplete() {
        UserDefaults.standard.set(true, forKey: Key.coach)
    }

    /// Profile tester control — replay the whole first run on next launch.
    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: Key.intro)
        UserDefaults.standard.removeObject(forKey: Key.coach)
    }
}
