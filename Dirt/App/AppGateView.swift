import SwiftUI

/// Top-level router: bootstrap → Sign in with Apple → screen name → map.
/// The map (`RootView`) is never shown until there is an authenticated account
/// with a screen name.
struct AppGateView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var didBootstrap = false

    private var authed: Bool {
        (BuildChannel.showsTesterUnlock && app.debugBypassAuth) || app.supabase.isSignedIn
    }

    private var needsName: Bool {
        if BuildChannel.showsTesterUnlock, app.debugBypassAuth { return false }
        return app.supabase.needsDisplayName
    }

    var body: some View {
        Group {
            if !didBootstrap {
                SplashView()
            } else if !authed {
                OnboardingView()
                    .transition(.opacity)
            } else if needsName {
                DisplayNameSetupView()
                    .transition(.opacity)
            } else {
                RootView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: didBootstrap)
        .animation(.easeInOut(duration: 0.35), value: authed)
        .animation(.easeInOut(duration: 0.35), value: needsName)
        .task {
            await app.supabase.bootstrap()
            didBootstrap = true
        }
    }
}

private struct SplashView: View {
    var body: some View {
        ZStack {
            Color(dirtHex: 0x0B0C0E).ignoresSafeArea()
            VStack(spacing: 18) {
                HStack(spacing: 0) {
                    Text("DIRT").italic().fontWeight(.black).foregroundStyle(.white)
                    Text(".").italic().fontWeight(.black).foregroundStyle(DirtTheme.orange)
                }
                .font(.system(size: 40, weight: .black))
                ProgressView().tint(.white.opacity(0.7))
            }
        }
    }
}
