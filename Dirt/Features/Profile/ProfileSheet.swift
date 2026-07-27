import AuthenticationServices
import StoreKit
import SwiftUI

/// Profile, redesigned to the Figma screens page: centered title, tracked
/// signed-in line, name field with orange SAVE NAME, then the pieces the mock
/// left implicit but the Apple-account flow requires — DIRT PRO subscription
/// management, legal links, and a black SIGN OUT.
struct ProfileSheet: View {
    @Environment(AppEnvironment.self) private var app
    @State private var displayName = ""
    @State private var busy = false
    @State private var message: String?
    @State private var showManageSubscriptions = false
    @State private var showPaywall = false

    private var supabase: SupabaseService { app.supabase }
    private var subscription: SubscriptionService { app.subscription }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header

                if supabase.isSignedIn {
                    nameField
                    saveNameButton
                } else {
                    signInBlock
                }

                proCard
                aboutRows

                if supabase.isSignedIn {
                    signOutButton
                }

                if let message {
                    Text(message)
                        .font(.dirtUI(12, weight: .semibold))
                        .foregroundStyle(DirtTheme.danger)
                }
                if let bootstrapError = supabase.bootstrapError {
                    Text(bootstrapError)
                        .font(.dirtUI(11))
                        .foregroundStyle(DirtTheme.danger)
                }

                if BuildChannel.showsTesterUnlock {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("TESTER")
                            .font(.dirtMono(10, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(DirtTheme.muted)
                        Toggle("Bypass Apple sign-in", isOn: Binding(
                            get: { app.debugBypassAuth },
                            set: { app.debugBypassAuth = $0 }
                        ))
                        .font(.dirtUI(13, weight: .semibold))
                        Toggle("Bypass trial / subscription", isOn: Binding(
                            get: { app.debugBypassSubscription },
                            set: { app.debugBypassSubscription = $0 }
                        ))
                        .font(.dirtUI(13, weight: .semibold))
                        .tint(DirtTheme.orange)
                        Button("Reset trial usage clock") {
                            app.trial.resetForTesting()
                            app.planner.toast = "Trial clock reset"
                        }
                        .font(.dirtUI(12, weight: .semibold))
                        .foregroundStyle(DirtTheme.muted)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DirtTheme.wash)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.top, 6)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .background(DirtTheme.sheet)
        .onAppear { displayName = supabase.displayName }
        .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        .sheet(isPresented: $showPaywall) {
            PaywallView(
                presentation: .soft,
                onClose: { showPaywall = false },
                onSubscribed: {
                    app.trial.markSubscribed()
                    showPaywall = false
                }
            )
            .presentationBackground(.clear)
        }
        .task { await subscription.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("Profile")
                .font(.dirtUI(20, weight: .heavy))
                .foregroundStyle(DirtTheme.ink)
            Text(signedInLine)
                .font(.dirtMono(10, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(DirtTheme.muted)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private var signedInLine: String {
        guard supabase.isSignedIn else { return "Signed out" }
        if let email = supabase.email, !email.isEmpty {
            return "Signed in · \(email)"
        }
        return "Signed in with Apple"
    }

    // MARK: - Screen name

    private var nameField: some View {
        TextField("Screen name", text: $displayName)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.dirtUI(15, weight: .semibold))
            .foregroundStyle(DirtTheme.ink)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(DirtTheme.wash)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var saveNameButton: some View {
        Button {
            Task {
                busy = true
                defer { busy = false }
                do {
                    try await supabase.updateDisplayName(displayName)
                    message = nil
                    app.planner.toast = "Profile updated"
                } catch {
                    message = "Your profile could not be updated."
                }
            }
        } label: {
            bigCTALabel("SAVE NAME", icon: "square.and.arrow.down", fill: DirtTheme.orange)
        }
        .disabled(busy || displayName.trimmingCharacters(in: .whitespaces).isEmpty)
        .opacity(busy ? 0.6 : 1)
    }

    private var signOutButton: some View {
        Button {
            Task { try? await supabase.signOut() }
        } label: {
            bigCTALabel("SIGN OUT", icon: "rectangle.portrait.and.arrow.right", fill: DirtTheme.chrome)
        }
    }

    // MARK: - Sign in fallback (map already gates on auth)

    private var signInBlock: some View {
        AppleSignInButton { result in
            if case let .success(credential) = result {
                Task {
                    try? await supabase.signInWithApple(
                        idToken: credential.idToken,
                        rawNonce: credential.rawNonce,
                        fullName: credential.fullName
                    )
                }
            }
        }
    }

    // MARK: - DIRT PRO

    private var proCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DIRT PRO")
                    .font(.dirtMono(11, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(subscription.isSubscribed ? "ACTIVE" : "NOT SUBSCRIBED")
                    .font(.dirtMono(9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(subscription.isSubscribed ? .white : .white.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(subscription.isSubscribed ? DirtTheme.navGreen : .white.opacity(0.12))
                    .clipShape(Capsule())
            }

            if subscription.isSubscribed {
                Button {
                    showManageSubscriptions = true
                } label: {
                    Text("MANAGE SUBSCRIPTION")
                        .font(.dirtUI(12, weight: .heavy))
                        .tracking(0.6)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            } else {
                Button {
                    showPaywall = true
                } label: {
                    Text("START 7-DAY FREE TRIAL")
                        .font(.dirtUI(12, weight: .heavy))
                        .tracking(0.6)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(DirtTheme.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            Button("Restore purchases") {
                Task {
                    await subscription.restore()
                    app.planner.toast = subscription.isSubscribed ? "Subscription restored" : "No purchases found"
                }
            }
            .font(.dirtUI(11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(DirtTheme.chrome)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - About / legal

    private var aboutRows: some View {
        VStack(spacing: 6) {
            Link(destination: LegalLinks.website) {
                linkRow("Visit dirtmoto.app", systemImage: "globe")
            }
            Link(destination: LegalLinks.privacyPolicy) {
                linkRow("Privacy policy", systemImage: "hand.raised.fill")
            }
            Link(destination: LegalLinks.termsOfUse) {
                linkRow("Terms of use", systemImage: "doc.text.fill")
            }
        }
    }

    private func linkRow(_ title: String, systemImage: String) -> some View {
        HStack {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DirtTheme.orange)
                .frame(width: 24)
            Text(title)
                .font(.dirtUI(14, weight: .semibold))
                .foregroundStyle(DirtTheme.ink)
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(DirtTheme.muted)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.black.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: - Pieces

    private func bigCTALabel(_ title: String, icon: String, fill: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
            Text(title)
                .font(.dirtUI(13, weight: .heavy))
                .tracking(0.8)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .background(fill)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
