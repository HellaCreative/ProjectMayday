import AuthenticationServices
import SwiftUI

/// First run + signed-out gate. Sign in with Apple is the only path in; the map
/// never loads until we have an account.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var busy = false
    @State private var errorMessage: String?

    private let highlights = [
        ("map.fill", "Every trail, mapped", "Surface-aware routing built for dirt, gravel, and back roads."),
        ("point.topleft.down.to.point.bottomright.curvepath.fill", "Rally-style cues", "Junction and curve callouts with voice guidance."),
        ("person.2.fill", "Ride as a crew", "Live location and status sharing with your group.")
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(dirtHex: 0x0B0C0E), Color(dirtHex: 0x1A1408)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 24)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 0) {
                        Text("DIRT").italic().fontWeight(.black).foregroundStyle(.white)
                        Text(".").italic().fontWeight(.black).foregroundStyle(DirtTheme.orange)
                    }
                    .font(.system(size: 44, weight: .black))
                    Text("MAYDAY")
                        .font(.dirtMono(12, weight: .semibold))
                        .tracking(5)
                        .foregroundStyle(.white.opacity(0.6))
                }

                Text("Off-road navigation for riders who leave the pavement behind.")
                    .font(.dirtUI(16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)

                VStack(alignment: .leading, spacing: 16) {
                    ForEach(highlights, id: \.0) { icon, title, detail in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: icon)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(DirtTheme.orange)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title)
                                    .font(.dirtUI(15, weight: .bold))
                                    .foregroundStyle(.white)
                                Text(detail)
                                    .font(.dirtUI(12))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.top, 32)

                Spacer(minLength: 24)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.dirtUI(12, weight: .semibold))
                        .foregroundStyle(DirtTheme.orange)
                        .padding(.bottom, 8)
                }

                if BuildChannel.showsTesterUnlock {
                    Button {
                        app.unlockAsTester()
                    } label: {
                        Text("Continue as tester")
                            .font(.dirtUI(14, weight: .heavy))
                            .tracking(0.4)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(DirtTheme.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    Text("Pre-release unlock — map + no paywall. Sign in with Apple still preferred when it works.")
                        .font(.dirtUI(10))
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                        .padding(.bottom, 14)
                }

                ZStack {
                    AppleSignInButton(onFinished: handle)
                        .opacity(busy ? 0.4 : 1)
                        .disabled(busy)
                    if busy {
                        ProgressView().tint(.white)
                    }
                }

                Text("We only use your Apple ID to create your DIRT account. No password to remember.")
                    .font(.dirtUI(10.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)

                HStack(spacing: 14) {
                    Link("Terms", destination: LegalLinks.termsOfUse)
                    Link("Privacy", destination: LegalLinks.privacyPolicy)
                }
                .font(.dirtUI(11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity)
                .padding(.top, 10)

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 28)
        }
    }

    private func handle(_ result: Result<AppleCredential, Error>) {
        switch result {
        case let .success(credential):
            Task {
                busy = true
                defer { busy = false }
                do {
                    try await app.supabase.signInWithApple(
                        idToken: credential.idToken,
                        rawNonce: credential.rawNonce,
                        fullName: credential.fullName
                    )
                    errorMessage = nil
                } catch {
                    errorMessage = Self.signInFailureMessage(from: error)
                }
            }
        case let .failure(error):
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return
            }
            errorMessage = Self.signInFailureMessage(from: error)
        }
    }

    /// Prefer the underlying API / Apple message so TestFlight failures are diagnosable.
    private static func signInFailureMessage(from error: Error) -> String {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty || detail == "The operation couldn’t be completed." {
            return "Sign-in couldn't be completed. Please try again."
        }
        return detail
    }
}
