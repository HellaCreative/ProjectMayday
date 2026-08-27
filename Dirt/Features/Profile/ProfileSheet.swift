import AuthenticationServices
import StoreKit
import SwiftUI
import UIKit

/// Account, Pro, ride prefs, and legal — hosted in `DockSheetPanel`.
struct ProfileSheet: View {
    @Environment(AppEnvironment.self) private var app
    @State private var displayName = ""
    @State private var busy = false
    @State private var message: String?
    @State private var showManageSubscriptions = false
    @State private var showPaywall = false
    @State private var testerToolsOpen = false
    @State private var routeDebugBusy = false
    @State private var routeDebugStatus: String?
    @State private var routeDebugReportURL: URL?
    @State private var showRouteDebugShare = false
    @AppStorage(FuelRangePrefs.key) private var fuelRangeKm = 0.0
    @AppStorage(FuelRangePrefs.reservePercentKey) private var fuelReservePercent = FuelRangePrefs.suggestedReservePercent
    @AppStorage(FuelRangePrefs.automaticPlanningKey) private var automaticFuelPlanning = true
    @AppStorage(KeepAwakePrefs.key) private var keepAwakeWhileUsing = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var profileFuelDebounce: Task<Void, Never>?

    private var supabase: SupabaseService { app.supabase }
    private var subscription: SubscriptionService { app.subscription }
    private var displayedFuelRangeKm: Double {
        fuelRangeKm > 0 ? fuelRangeKm : FuelRangePrefs.kilometers
    }

    var body: some View {
        VStack(spacing: 0) {
            DirtSheetHeader(title: "Profile")

            ScrollView {
                VStack(spacing: DirtSpace.group) {
                    accountSection
                    proCard
                    ridePrefsSection
                    aboutRows

                    if supabase.isSignedIn {
                        Button {
                            Task {
                                guard !busy else { return }
                                busy = true
                                await app.groups.prepareForSignOut()
                                do {
                                    try await supabase.signOut()
                                } catch {
                                    message = "You could not sign out right now."
                                    await app.groups.refreshGroups()
                                }
                                busy = false
                            }
                        } label: {
                            Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .buttonStyle(DirtCTAStyle(fill: DirtTheme.chrome))
                        .disabled(busy)
                    }

                    if let message {
                        Text(message)
                            .font(DirtType.helper)
                            .fontWeight(.semibold)
                            .foregroundStyle(DirtTheme.danger)
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
                .padding(.horizontal, DirtSpace.group)
                .padding(.top, DirtSpace.tight)
                .padding(.bottom, DirtSpace.section)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
        }
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

    // MARK: - Account

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: DirtSpace.inner) {
            Text(signedInLine)
                .font(DirtType.sectionLabel)
                .tracking(1.1)
                .foregroundStyle(DirtTheme.muted)
                .textCase(.uppercase)
                .frame(maxWidth: .infinity)

            if supabase.isSignedIn {
                TextField("Screen name", text: $displayName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(DirtType.rowTitle)
                    .foregroundStyle(DirtTheme.ink)
                    .padding(.horizontal, DirtSpace.row)
                    .frame(minHeight: DirtHit.control)
                    .background(DirtTheme.rowFill, in: RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
                            .stroke(DirtTheme.hairline, lineWidth: 1)
                    )

                Button {
                    Task {
                        busy = true
                        defer { busy = false }
                        do {
                            try await supabase.updateDisplayName(displayName)
                            message = nil
                            app.planner.toast = "Profile updated"
                        } catch {
                            message = "Couldn’t update your name. Try again."
                        }
                    }
                } label: {
                    Label("Save name", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(DirtCTAStyle.brand(isLoading: busy))
                .disabled(busy || displayName.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
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
        }
    }

    private var signedInLine: String {
        guard supabase.isSignedIn else { return "Signed out" }
        if let email = supabase.email, !email.isEmpty {
            return "Signed in · \(email)"
        }
        return "Signed in with Apple"
    }

    // MARK: - DIRT PRO

    private var proCard: some View {
        VStack(alignment: .leading, spacing: DirtSpace.inner) {
            HStack {
                Text("DIRT PRO")
                    .font(DirtType.sectionLabel)
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text(subscription.isSubscribed ? "Active" : "Not subscribed")
                    .font(DirtType.chip)
                    .fontWeight(.bold)
                    .foregroundStyle(subscription.isSubscribed ? .white : .white.opacity(0.85))
                    .padding(.horizontal, DirtSpace.inner)
                    .padding(.vertical, DirtSpace.tight)
                    .background(subscription.isSubscribed ? DirtTheme.navGreen : .white.opacity(0.12))
                    .clipShape(Capsule())
            }

            if subscription.isSubscribed {
                Button {
                    showManageSubscriptions = true
                } label: {
                    Text("Manage")
                        .font(DirtType.cta)
                        .tracking(0.6)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: DirtHit.min)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: DirtRadius.chip, style: .continuous))
                }
            } else {
                Button {
                    showPaywall = true
                } label: {
                    Text("Start free trial")
                        .font(DirtType.cta)
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(DirtTheme.onOrange)
                        .frame(maxWidth: .infinity, minHeight: DirtHit.min)
                        .background(DirtTheme.orange, in: RoundedRectangle(cornerRadius: DirtRadius.chip, style: .continuous))
                }
            }

            Button("Restore purchases") {
                Task {
                    await subscription.restore()
                    app.planner.toast = subscription.isSubscribed ? "Subscription restored" : "No purchases found"
                }
            }
            .font(DirtType.helper)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.65))
            .frame(maxWidth: .infinity, minHeight: DirtHit.min)
            .contentShape(Rectangle())
        }
        .padding(DirtSpace.row)
        .background(DirtTheme.chrome, in: RoundedRectangle(cornerRadius: DirtRadius.sheet - 6, style: .continuous))
    }

    // MARK: - Ride prefs

    private var ridePrefsSection: some View {
        VStack(spacing: DirtSpace.inner) {
            fuelRangeCard
            displayPrefsCard
        }
    }

    private var fuelRangeCard: some View {
        VStack(alignment: .leading, spacing: DirtSpace.inner) {
            DirtSectionLabel(title: "Fuel range")
            Toggle("Automatic fuel planning", isOn: $automaticFuelPlanning)
                .font(DirtType.rowTitle)
                .tint(DirtTheme.orange)
            Text(automaticFuelPlanning
                ? "Dirt adds only the fuel stops needed to finish safely."
                : "Off — Dirt will not add fuel stops or check whether this route has enough fuel.")
                .font(DirtType.helper)
                .foregroundStyle(automaticFuelPlanning ? DirtTheme.muted : DirtTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DirtSpace.inner) {
                Text("\(Int(displayedFuelRangeKm)) km")
                    .font(DirtType.metricInline)
                    .foregroundStyle(DirtTheme.ink)
                    .frame(minWidth: 56, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { displayedFuelRangeKm },
                        set: { fuelRangeKm = $0 }
                    ),
                    in: FuelRangePrefs.minimumKm...FuelRangePrefs.maximumKm,
                    step: 10
                ) { editing in
                    if editing {
                        profileFuelDebounce?.cancel()
                        app.planner.cancelFuelAssistForRangeEdit()
                    } else {
                        let selected = displayedFuelRangeKm
                        FuelRangePrefs.kilometers = selected
                        FuelRangePrefs.lastEnabledKilometers = selected
                        app.planner.reapplyFuelAssist(rangeKm: selected)
                    }
                }
                .tint(DirtTheme.orange)
                .accessibilityLabel("Kilometers per tank")
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Safety reserve")
                        .font(DirtType.rowTitle)
                        .foregroundStyle(DirtTheme.ink)
                    Text("\(Int(FuelRangePrefs.usableKilometers(for: displayedFuelRangeKm, reservePercent: fuelReservePercent).rounded())) km usable")
                        .font(DirtType.helper)
                        .foregroundStyle(DirtTheme.muted)
                }
                Spacer(minLength: 0)
                Menu("\(Int(fuelReservePercent))%") {
                    ForEach([0, 5, 10, 15, 20, 25, 30], id: \.self) { percent in
                        Button("\(percent)%") { fuelReservePercent = Double(percent) }
                    }
                }
                .font(DirtType.chip)
                .fontWeight(.bold)
                .foregroundStyle(DirtTheme.orange)
            }
        }
        .padding(DirtSpace.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DirtTheme.rowFill, in: RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
                .stroke(DirtTheme.hairline, lineWidth: 1)
        )
        .onChange(of: fuelReservePercent) { _, newValue in
            FuelRangePrefs.reservePercent = newValue
            profileFuelDebounce?.cancel()
            app.planner.reapplyFuelAssist(rangeKm: displayedFuelRangeKm)
        }
        .onChange(of: automaticFuelPlanning) { _, enabled in
            FuelRangePrefs.automaticPlanningEnabled = enabled
            RoutingDebugLog.shared.event(
                "profile automatic fuel planning=\(enabled ? 1 : 0) recalc=1"
            )
            app.planner.reapplyFuelAssist(rangeKm: displayedFuelRangeKm)
        }
    }

    private var displayPrefsCard: some View {
        VStack(alignment: .leading, spacing: DirtSpace.inner) {
            DirtSectionLabel(title: "Display")
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
            Text("After End navigation, optionally upload road segment ids (not GPS) to improve packs.")
                .font(DirtType.helper)
                .foregroundStyle(DirtTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DirtSpace.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DirtTheme.rowFill, in: RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
                .stroke(DirtTheme.hairline, lineWidth: 1)
        )
        .onChange(of: keepAwakeWhileUsing) { _, _ in
            KeepAwakePrefs.sync(
                sceneActive: scenePhase == .active,
                navigating: app.navigation.phase != .idle
            )
        }
    }

    // MARK: - About / legal

    private var aboutRows: some View {
        VStack(spacing: DirtSpace.tight) {
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
    }

    private func linkRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: DirtSpace.inner) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DirtTheme.orange)
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
        .background(DirtTheme.rowFill, in: RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
                .stroke(DirtTheme.hairline, lineWidth: 1)
        )
    }

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
                .textCase(.uppercase)

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
            .foregroundStyle(DirtTheme.orange)
            .disabled(routeDebugBusy)

            Button("Copy app log") {
                RoutingDebugLog.shared.copyToPasteboard()
                app.planner.toast = "App log copied"
            }
            .font(.dirtUI(13, weight: .semibold))
            .foregroundStyle(DirtTheme.orange)
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
        .background(DirtTheme.rowFill, in: RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DirtRadius.control, style: .continuous)
                .stroke(DirtTheme.hairline, lineWidth: 1)
        )
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

/// Share sheet for diagnostic report files (AirDrop / Messages / Files).
private struct ProfileShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
