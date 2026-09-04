import SwiftUI
import UIKit

/// Top-level router: splash → intro slides → map. Nothing in front of the map is
/// gated on having an account.
///
/// This used to put Sign in with Apple between the splash and the intro, which meant
/// a fresh install went splash → sign-in and the intro never ran at all. Riders now
/// reach the map and coach tour signed out; sign-in is asked for
/// where it is actually needed — Groups — and offered in Profile.
///
/// The intro replays on every cold launch (Skip is always available) so returning
/// riders keep meeting the pitch. Once through, the coach tour takes over on the map;
/// that one runs once and is remembered.
struct AppGateView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var didBootstrap = false
    @State private var splashFinished = false
    /// Per-launch, deliberately not seeded from `OnboardingPrefs` — see type comment.
    @State private var introDone = false

    /// Hold the splash until the throttle blips finish *and* bootstrap lands, so a
    /// fast launch never cuts the animation and a slow one never dead-ends on it.
    private var showsSplash: Bool {
        !splashFinished || !didBootstrap
    }

    var body: some View {
        Group {
            if showsSplash {
                AnimatedSplashView { splashFinished = true }
            } else if !introDone {
                IntroCarouselView(
                    isReturning: OnboardingPrefs.introComplete,
                    onFinished: finishIntro
                )
                .transition(.opacity)
            } else {
                RootView()
                    .transition(.opacity)
            }
        }
        .animation(gateAnimation, value: showsSplash)
        .animation(gateAnimation, value: introDone)
        .task {
            Task { await app.bootstrapShortbreadTileDelivery() }
            await app.supabase.bootstrap()
            didBootstrap = true
        }
    }

    /// No paywall here. The rider reaches the map before any paid action is gated.
    private func finishIntro() {
        OnboardingPrefs.markIntroComplete()
        introDone = true
    }

    private var gateAnimation: Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.35)
    }
}
