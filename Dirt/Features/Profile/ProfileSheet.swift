import StoreKit
import SwiftUI
import UIKit

/// Account, Pro, ride settings, and legal. Primary glance stays on this panel;
/// secondary and tertiary open as sheets over Profile.
struct ProfileSheet: View {
    let onClose: () -> Void
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var busy = false
    @State private var notice: ProfileNotice?
    @State private var showManageSubscriptions = false
    @State private var showPaywall = false
    @State private var showLicences = false
    @State private var showDeleteAccountConfirmation = false
    @State private var showRideSettings = false
    @State private var showLegalAccount = false
    @State private var showEditName = false
    @State private var testerToolsOpen = false
    @State private var routeDebugBusy = false
    @State private var routeDebugStatus: String?
    @State private var routeDebugReportURL: URL?
    @State private var showRouteDebugShare = false
    @AppStorage(KeepAwakePrefs.key) private var keepAwakeWhileUsing = false
    @Environment(\.scenePhase) private var scenePhase

    private var supabase: SupabaseService { app.supabase }
    private var subscription: SubscriptionService { app.subscription }

    var body: some View {
        VStack(spacing: 0) {
            DirtSheetHeader(
                title: "Profile",
                titleFont: .system(.title2, design: .default, weight: .bold),
                onClose: closeProfile
            )

            ScrollView {
                VStack(spacing: DirtSpace.group) {
                    heroCard

                    VStack(spacing: DirtSpace.tight) {
                        Button { showRideSettings = true } label: {
                            navigationRow("Keep-awake & contribute", systemImage: "moon.zzz.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens keep-awake and ride contribution settings")

                        Button { showLegalAccount = true } label: {
                            navigationRow("Legal & account", systemImage: "doc.text.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens legal links, restore, sign out, and delete account")
                    }

                    if let notice {
                        Text(notice.text)
                            .font(DirtType.helper)
                            .fontWeight(.semibold)
                            .foregroundStyle(notice.kind == .problem ? DirtTheme.danger : DirtTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let bootstrapError = supabase.bootstrapError {
                        Text(bootstrapError)
                            .font(DirtType.helper)
                            .foregroundStyle(DirtTheme.danger)
                    }

                    if BuildChannel.showsTesterUnlock {
                        testerFooter
                    }
                }
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, DirtSpace.group)
                .padding(.top, DirtSpace.tight)
                .padding(.bottom, DirtSpace.section)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: DockSheetContentHeightKey.self, value: geo.size.height)
                    }
                )
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
        }
        .frame(maxWidth: .infinity)
        .onAppear { displayName = supabase.displayName }
        .onChange(of: supabase.displayName) { _, name in
            if !showEditName {
                displayName = name
            }
        }
        .sheet(isPresented: $showRideSettings) {
            rideSettingsSheet
        }
        .sheet(isPresented: $showLegalAccount) {
            legalAccountSheet
        }
        .sheet(isPresented: $showEditName) {
            editNameSheet
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(
                presentation: .soft,
                onClose: { showPaywall = false },
                onSubscribed: {
                    app.trial.markSubscribed()
                    showPaywall = false
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(DirtTheme.sheetMaterial)
        }
        .task { await subscription.refresh() }
        .sheet(isPresented: $showRouteDebugShare) {
            if let url = routeDebugReportURL {
                ProfileShareSheet(items: [url])
            }
        }
    }

    private func closeProfile() {
        onClose()
        dismiss()
    }

    // MARK: - Primary

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: DirtSpace.inner) {
            if supabase.isSignedIn {
                signedInHero
            } else {
                signedOutHero
            }
        }
        .padding(DirtSpace.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dirtGroupingSurface(radius: DirtRadius.card)
    }

    private var signedOutHero: some View {
        VStack(alignment: .leading, spacing: DirtSpace.inner) {
            Text("Signed out")
                .font(.system(.subheadline, design: .default, weight: .bold))
                .foregroundStyle(DirtTheme.muted)
                .frame(maxWidth: .infinity)

            Text("Create and join groups, share your ride status with your crew, and keep your DIRT profile connected.")
                .font(DirtType.helper)
                .foregroundStyle(DirtTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            AppleSignInButton { result in
                handleSignIn(result)
            }
            .disabled(busy)
            .opacity(busy ? 0.65 : 1)
        }
    }

    @ViewBuilder
    private var signedInHero: some View {
        if subscription.isSubscribed {
            HStack {
                Text("DIRT PRO")
                    .font(DirtType.sectionLabel)
                    .foregroundStyle(DirtTheme.muted)
                Spacer()
                Text("Active")
                    .font(DirtType.chip)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, DirtSpace.inner)
                    .padding(.vertical, DirtSpace.tight)
                    .background(DirtTheme.navGreen)
                    .clipShape(Capsule())
            }
            identityBlock
        } else {
            identityBlock
            HStack {
                Text("DIRT PRO")
                    .font(DirtType.sectionLabel)
                    .foregroundStyle(DirtTheme.muted)
                Spacer()
                Text("Not subscribed")
                    .font(DirtType.chip)
                    .fontWeight(.bold)
                    .foregroundStyle(DirtTheme.muted)
                    .padding(.horizontal, DirtSpace.inner)
                    .padding(.vertical, DirtSpace.tight)
                    .background(DirtTheme.wash)
                    .clipShape(Capsule())
            }
            Button {
                showPaywall = true
            } label: {
                Text("View DIRT PRO")
            }
            .buttonStyle(DirtCTAStyle.brand())
        }
    }

    private var identityBlock: some View {
        VStack(alignment: .leading, spacing: DirtSpace.tight) {
            Text(identityTitle)
                .font(.system(.subheadline, design: .default, weight: .bold))
                .foregroundStyle(DirtTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let identityDetail {
                Text(identityDetail)
                    .font(DirtType.helper)
                    .foregroundStyle(DirtTheme.muted)
            }
            Button("Edit name") {
                displayName = supabase.displayName
                showEditName = true
            }
            .buttonStyle(.plain)
            .font(DirtType.helper)
            .fontWeight(.semibold)
            .foregroundStyle(DirtTheme.action)
            .frame(maxWidth: .infinity, minHeight: DirtHit.min, alignment: .leading)
            .contentShape(Rectangle())
            .disabled(busy)
        }
    }

    private var identityTitle: String {
        let name = supabase.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return signedInLine
    }

    private var identityDetail: String? {
        let name = supabase.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return nil }
        return signedInLine
    }

    private var signedInLine: String {
        guard supabase.isSignedIn else { return "Signed out" }
        if let email = supabase.email, !email.isEmpty {
            return "Signed in · \(email)"
        }
        return "Signed in with Apple"
    }

    private func handleSignIn(_ result: Result<AppleCredential, Error>) {
        switch result {
        case let .success(credential):
            guard !busy else { return }
            busy = true
            notice = nil
            Task {
                defer { busy = false }
                do {
                    try await supabase.signInWithApple(
                        idToken: credential.idToken,
                        rawNonce: credential.rawNonce,
                        fullName: credential.fullName
                    )
                } catch {
                    if let text = AppleSignInFailure.message(from: error) {
                        notice = ProfileNotice(kind: .problem, text: text)
                    }
                }
            }
        case let .failure(error):
            if let text = AppleSignInFailure.message(from: error) {
                notice = ProfileNotice(kind: .problem, text: text)
            }
        }
    }

    // MARK: - Secondary

    private var rideSettingsSheet: some View {
        VStack(spacing: 0) {
            DirtSheetHeader(
                title: "Keep-awake & contribute",
                titleFont: .system(.title2, design: .default, weight: .bold),
                onClose: { showRideSettings = false }
            )
            ScrollView {
                VStack(alignment: .leading, spacing: DirtSpace.inner) {
                    Toggle("Keep device awake while using this app", isOn: $keepAwakeWhileUsing)
                        .font(DirtType.rowTitle)
                        .tint(DirtTheme.orange)
                    Text("Stops auto-lock while Dirt is open. Navigation keeps the screen on either way.")
                        .font(DirtType.helper)
                        .foregroundStyle(DirtTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(
                        "Ask to contribute rides",
                        isOn: Binding(
                            get: { TrackContributePrefs.isEnabled },
                            set: {
                                TrackContributePrefs.isEnabled = $0
                                TrackContributePrefs.hasBeenAsked = true
                            }
                        )
                    )
                    .font(DirtType.rowTitle)
                    .tint(DirtTheme.orange)
                    Text("After End navigation, optionally share the roads you rode — not a GPS trail — so packs stay better.")
                        .font(DirtType.helper)
                        .foregroundStyle(DirtTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("How DIRT uses ride data", destination: LegalLinks.dataUse)
                        .font(DirtType.helper)
                        .fontWeight(.semibold)
                        .foregroundStyle(DirtTheme.action)
                        .frame(maxWidth: .infinity, minHeight: DirtHit.min, alignment: .leading)
                }
                .padding(DirtSpace.row)
                .dirtGroupingSurface()
                .padding(.horizontal, DirtSpace.group)
                .padding(.top, DirtSpace.tight)
                .padding(.bottom, DirtSpace.section)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
        }
        .padding(.top, DirtSpace.group)
        .background(DirtTheme.sheetMaterial)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(DirtTheme.sheetMaterial)
        .onChange(of: keepAwakeWhileUsing) { _, _ in
            KeepAwakePrefs.sync(
                sceneActive: scenePhase == .active,
                navigating: app.navigation.phase != .idle
            )
        }
    }

    // MARK: - Tertiary

    private var legalAccountSheet: some View {
        VStack(spacing: 0) {
            DirtSheetHeader(
                title: "Legal & account",
                titleFont: .system(.title2, design: .default, weight: .bold),
                onClose: { showLegalAccount = false }
            )
            ScrollView {
                VStack(spacing: DirtSpace.group) {
                    VStack(spacing: DirtSpace.tight) {
                        if subscription.isSubscribed {
                            Button {
                                showManageSubscriptions = true
                            } label: {
                                navigationRow("Manage subscription", systemImage: "creditcard.fill")
                            }
                            .buttonStyle(.plain)
                        }
                        Button {
                            Task { await restorePurchases() }
                        } label: {
                            navigationRow("Restore purchases", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .disabled(subscription.storeOperationInFlight)
                    }

                    VStack(spacing: DirtSpace.tight) {
                        Button { showLicences = true } label: {
                            linkRow("Licences & credits", systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.plain)
                        Link(destination: LegalLinks.website) {
                            linkRow("Visit dirtmoto.app", systemImage: "globe")
                        }
                        Link(destination: LegalLinks.privacyPolicy) {
                            linkRow("Privacy policy", systemImage: "hand.raised.fill")
                        }
                        Link(destination: LegalLinks.termsOfUse) {
                            linkRow("Terms of use", systemImage: "doc.text.fill")
                        }
                        Link(destination: LegalLinks.eula) {
                            linkRow("EULA", systemImage: "signature")
                        }
                        Link(destination: LegalLinks.subscriptions) {
                            linkRow("Subscriptions", systemImage: "creditcard.fill")
                        }
                        Link(destination: LegalLinks.support) {
                            linkRow("Support", systemImage: "questionmark.circle.fill")
                        }
                    }

                    if supabase.isSignedIn {
                        VStack(spacing: 0) {
                            Button {
                                Task { await signOut() }
                            } label: {
                                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                            .buttonStyle(DirtCTAStyle(fill: DirtTheme.chrome))

                            Button(role: .destructive) {
                                showDeleteAccountConfirmation = true
                            } label: {
                                Label("Delete account", systemImage: "person.crop.circle.badge.minus")
                                    .font(DirtType.helper)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(DirtTheme.danger)
                                    .frame(minHeight: DirtHit.min)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, DirtSpace.section)
                            .accessibilityHint("Permanently deletes your DIRT account after confirmation")
                        }
                        .disabled(busy)
                    }
                }
                .padding(.horizontal, DirtSpace.group)
                .padding(.top, DirtSpace.tight)
                .padding(.bottom, DirtSpace.section)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
        }
        .padding(.top, DirtSpace.group)
        .background(DirtTheme.sheetMaterial)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(DirtTheme.sheetMaterial)
        .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        .sheet(isPresented: $showLicences) {
            licencesSheet
        }
        .alert("Delete your DIRT account?", isPresented: $showDeleteAccountConfirmation) {
            Button("Delete account", role: .destructive) {
                deleteAccount()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your DIRT profile, group memberships, live sharing, alerts, and contributed ride data. It does not cancel an App Store subscription; manage that separately first.")
        }
    }

    private var licencesSheet: some View {
        NavigationStack {
            ScrollView {
                Text(Self.thirdPartyNotices)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Licences & credits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showLicences = false }
                }
            }
        }
    }

    private var editNameSheet: some View {
        VStack(spacing: 0) {
            DirtSheetHeader(title: "Screen name", onClose: { showEditName = false })
            VStack(alignment: .leading, spacing: DirtSpace.inner) {
                TextField("Screen name", text: $displayName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(DirtType.rowTitle)
                    .foregroundStyle(DirtTheme.ink)
                    .padding(.horizontal, DirtSpace.row)
                    .frame(minHeight: DirtHit.control)
                    .dirtGroupingSurface()

                Button {
                    Task { await saveDisplayName() }
                } label: {
                    Label("Save name", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(DirtSecondaryButtonStyle())
                .disabled(busy || displayName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, DirtSpace.group)
            .padding(.top, DirtSpace.tight)
            .padding(.bottom, DirtSpace.section)
            Spacer(minLength: 0)
        }
        .background(DirtTheme.sheetMaterial)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(DirtTheme.sheetMaterial)
    }

    private func saveDisplayName() async {
        busy = true
        defer { busy = false }
        do {
            try await supabase.updateDisplayName(displayName)
            notice = nil
            app.planner.toast = "Profile updated"
            showEditName = false
        } catch {
            notice = ProfileNotice(kind: .problem, text: "Couldn’t update your name. Try again.")
        }
    }

    private func restorePurchases() async {
        switch await subscription.restore() {
        case .restored:
            app.planner.toast = "Subscription restored"
        case .noActiveSubscription:
            app.planner.toast = "No purchases found"
        case .failed(let message):
            app.planner.toast = message
        }
    }

    private func signOut() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await app.groups.prepareForSignOut()
        do {
            try await supabase.signOut()
            notice = nil
            showLegalAccount = false
        } catch {
            notice = ProfileNotice(kind: .problem, text: "You could not sign out right now.")
            await app.groups.refreshGroups()
        }
    }

    private func deleteAccount() {
        guard !busy else { return }
        busy = true
        notice = nil
        Task {
            await app.groups.prepareForSignOut()
            do {
                try await supabase.deleteAccount()
                notice = ProfileNotice(
                    kind: .info,
                    text: "Your DIRT account was deleted. To also revoke DIRT’s Sign in with Apple access, open Settings → your name → Sign-In & Security → Sign in with Apple."
                )
                showLegalAccount = false
            } catch {
                notice = ProfileNotice(kind: .problem, text: error.localizedDescription)
                // A response can be lost after the server commits. Keep sharing
                // stopped and avoid claiming either success or rollback until
                // the rider's account state is confirmed on a fresh session.
            }
            busy = false
        }
    }

    // MARK: - Rows

    private func navigationRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: DirtSpace.inner) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DirtTheme.action)
                .frame(width: 24)
            Text(title)
                .font(DirtType.rowTitle)
                .foregroundStyle(DirtTheme.ink)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(DirtTheme.muted)
        }
        .padding(.horizontal, DirtSpace.row)
        .frame(minHeight: DirtHit.min)
        .dirtGroupingSurface()
    }

    private func linkRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: DirtSpace.inner) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DirtTheme.action)
                .frame(width: 24)
            Text(title)
                .font(DirtType.rowTitle)
                .foregroundStyle(DirtTheme.ink)
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(DirtTheme.muted)
        }
        .padding(.horizontal, DirtSpace.row)
        .frame(minHeight: DirtHit.min)
        .dirtGroupingSurface()
    }

    // MARK: - About / legal

    private static let thirdPartyNotices: String = {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Licence notices could not be loaded. Please contact support at dirtmoto.app/support/."
        }
        return text
    }()

    // MARK: - Tester

    /// Collapsed and de-emphasised at the very bottom of Profile: on a tester build
    /// everything above this line should look exactly like production.
    private var testerFooter: some View {
        VStack(spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { testerToolsOpen.toggle() }
            } label: {
                Text("Tester")
                    .font(.dirtUI(11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(DirtTheme.muted.opacity(testerToolsOpen ? 0.9 : 0.45))
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tester tools")
            .accessibilityHint(testerToolsOpen ? "Hides tester tools" : "Shows tester tools")

            if testerToolsOpen {
                testerTools
                    .transition(.opacity)
            }
        }
        .padding(.top, DirtSpace.section)
    }

    private var testerTools: some View {
        VStack(alignment: .leading, spacing: DirtSpace.tight) {
            VStack(alignment: .leading, spacing: 0) {
                testerRow(
                    app.debugBypassSubscription ? "Paywall skipped — turn back on" : "Skip as tester",
                    tint: app.debugBypassSubscription ? DirtTheme.orange : DirtTheme.muted
                ) {
                    app.debugBypassSubscription.toggle()
                    app.planner.toast = app.debugBypassSubscription
                        ? "Paywall skipped until reinstall"
                        : "Paywall armed"
                }

                testerRow("Replay first run", tint: DirtTheme.muted) {
                    OnboardingPrefs.resetAll()
                    TrackContributePrefs.reset()
                    app.trial.resetForTesting()
                    app.debugBypassSubscription = false
                    app.planner.toast = "Relaunch to replay the tour"
                }

                testerRow("Reset free Starts", tint: DirtTheme.muted) {
                    app.trial.resetForTesting()
                    app.planner.toast = "Two free Starts restored"
                }
            }

            routeSessionDiagnosticsCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var routeSessionDiagnosticsCard: some View {
        VStack(alignment: .leading, spacing: DirtSpace.inner) {
            Text("App debug")
                .font(DirtType.sectionLabel)
                .tracking(1.1)
                .foregroundStyle(DirtTheme.muted)

            Text("Share the current app session: network changes, map loading, fuel controls, routing, navigation, and other field-test failures.")
                .font(DirtType.helper)
                .foregroundStyle(DirtTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                shareRouteDebug()
            } label: {
                Text(routeDebugBusy ? "Preparing…" : "Share app session…")
                    .font(.dirtUI(13, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: DirtHit.min, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(DirtTheme.action)
            .disabled(routeDebugBusy)

            Button("Copy app log") {
                RoutingDebugLog.shared.copyToPasteboard()
                app.planner.toast = "App log copied"
            }
            .font(.dirtUI(13, weight: .semibold))
            .foregroundStyle(DirtTheme.action)
            .frame(maxWidth: .infinity, minHeight: DirtHit.min, alignment: .leading)
            .contentShape(Rectangle())
            .buttonStyle(.plain)

            if let routeDebugStatus {
                Text(routeDebugStatus)
                    .font(DirtType.helper)
                    .foregroundStyle(DirtTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(DirtSpace.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dirtGroupingSurface()
    }

    private func shareRouteDebug() {
        routeDebugBusy = true
        routeDebugStatus = nil
        do {
            let url = try RoutingDebugLog.shared.writeShareFile()
            routeDebugReportURL = url
            routeDebugStatus = url.lastPathComponent
            showRouteDebugShare = true
            app.planner.toast = "App debug ready to share"
        } catch {
            routeDebugStatus = error.localizedDescription
            app.planner.toast = "Couldn’t write app debug"
        }
        routeDebugBusy = false
    }

    private func testerRow(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.dirtUI(13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: DirtHit.min, alignment: .leading)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
    }
}

private struct ProfileNotice: Equatable {
    enum Kind: Equatable {
        case info
        case problem
    }

    let kind: Kind
    let text: String
}

/// Share sheet for diagnostic report files (AirDrop / Messages / Files).
private struct ProfileShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
