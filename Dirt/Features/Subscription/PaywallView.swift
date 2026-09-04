import StoreKit
import SwiftUI

/// StoreKit-backed DIRT PRO purchase surface.
/// Soft: dismissible system sheet. Hard: full-screen gate (Subscribe / Restore only).
struct PaywallView: View {
    @Environment(AppEnvironment.self) private var app
    let presentation: TrialPresentation
    var onClose: () -> Void
    var onSubscribed: () -> Void

    @State private var selectedPlan: SubscriptionService.Plan = .yearly
    @State private var errorMessage: String?

    private var subscription: SubscriptionService { app.subscription }
    private var isHard: Bool { presentation == .hard }

    private let perks = [
        ("point.topleft.down.to.point.bottomright.curvepath.fill", "Unlimited ride navigation", "Ride beyond the two free starts with junction, rally, and voice cues."),
        ("doc.badge.arrow.up", "GPX export", "Take a route into compatible devices and riding tools.")
    ]

    var body: some View {
        Group {
            if isHard {
                hardShell { paywallBody }
            } else {
                softShell { paywallBody }
            }
        }
        .task {
            await subscription.refresh()
            selectAvailablePlanIfNeeded()
        }
        .onChange(of: subscription.isSubscribed) { _, subscribed in
            if subscribed { onSubscribed() }
        }
        .onChange(of: subscription.products.map(\.id)) { _, _ in
            selectAvailablePlanIfNeeded()
        }
        .interactiveDismissDisabled(isHard)
    }

    private func softShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .dirtSheetContent()
            .background(DirtTheme.sheetMaterial)
    }

    private func hardShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(dirtHex: 0x0B0C0E), Color(dirtHex: 0x1A1408)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            content()
        }
    }

    private var paywallBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DirtSpace.row) {
                header
                perkList
                planPicker
                cta
                legalFootnote
            }
            .padding(DirtSpace.section)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if presentation == .soft {
                softCloseBar
            }
        }
    }

    private var softCloseBar: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isHard ? .white.opacity(0.9) : DirtTheme.muted)
                    .frame(width: DirtHit.min, height: DirtHit.min)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .padding(.trailing, DirtSpace.inner)
        }
        .padding(.top, DirtSpace.tight)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DirtSpace.tight) {
            HStack(spacing: 8) {
                Text("DIRT")
                    .italic()
                    .font(.dirtUI(22, weight: .black))
                    .foregroundStyle(isHard ? .white : DirtTheme.ink)
                Text("PRO")
                    .font(.dirtMono(11, weight: .bold))
                    .tracking(3)
                    .foregroundStyle(DirtTheme.onOrange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(DirtTheme.orange, in: Capsule())
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("DIRT PRO")

            Text(headerTitle)
                .font(.dirtUI(24, weight: .heavy))
                .foregroundStyle(isHard ? .white : DirtTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                headerDetail
            )
            .font(.dirtUI(14))
            .foregroundStyle(isHard ? .white.opacity(0.7) : DirtTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var perkList: some View {
        VStack(alignment: .leading, spacing: DirtSpace.inner) {
            ForEach(perks, id: \.0) { icon, title, detail in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DirtTheme.orange)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.dirtUI(14, weight: .bold))
                            .foregroundStyle(isHard ? .white : DirtTheme.ink)
                        Text(detail)
                            .font(.dirtUI(13))
                            .foregroundStyle(isHard ? .white.opacity(0.62) : DirtTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private var planPicker: some View {
        if subscription.isLoadingProducts && !subscription.hasProducts {
            HStack(spacing: DirtSpace.inner) {
                ProgressView()
                Text("Loading plans…")
                    .font(.dirtUI(13, weight: .semibold))
                    .foregroundStyle(isHard ? .white.opacity(0.7) : DirtTheme.muted)
            }
            .frame(maxWidth: .infinity, minHeight: DirtHit.control)
            .accessibilityLabel("Loading subscription plans")
        } else if availablePlans.isEmpty {
            VStack(alignment: .leading, spacing: DirtSpace.tight) {
                Text("Plans unavailable")
                    .font(.dirtUI(14, weight: .bold))
                    .foregroundStyle(isHard ? .white : DirtTheme.ink)
                Text(subscription.loadError ?? "Subscription options could not be loaded right now.")
                    .font(.dirtUI(13))
                    .foregroundStyle(isHard ? .white.opacity(0.7) : DirtTheme.muted)
                Button("Try again") {
                    Task {
                        await subscription.loadProducts()
                        selectAvailablePlanIfNeeded()
                    }
                }
                .font(.dirtUI(13, weight: .bold))
                .foregroundStyle(DirtTheme.orange)
                .frame(minHeight: DirtHit.min)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: DirtSpace.inner) {
                ForEach(availablePlans, id: \.rawValue) { plan in
                    planCard(
                        plan,
                        title: plan == .yearly ? "Yearly" : "Monthly",
                        price: displayPrice(for: plan),
                        sub: plan == .yearly ? "per year" : "per month",
                        badge: plan == .yearly ? subscription.yearlySavingsLabel : nil
                    )
                }
            }
        }
    }

    private func planCard(
        _ plan: SubscriptionService.Plan,
        title: String,
        price: String,
        sub: String,
        badge: String?
    ) -> some View {
        let selected = selectedPlan == plan
        return Button {
            selectedPlan = plan
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.dirtUI(13, weight: .bold))
                        .foregroundStyle(planTitleColor)
                    Spacer(minLength: 0)
                    if let badge {
                        Text(badge)
                            .font(.dirtMono(10, weight: .bold))
                            .tracking(0.3)
                            .foregroundStyle(DirtTheme.onOrange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(DirtTheme.orange, in: Capsule())
                    }
                }
                Text(price)
                    .font(.dirtMono(16, weight: .bold))
                    .foregroundStyle(planTitleColor)
                Text(sub)
                    .font(.dirtUI(12))
                    .foregroundStyle(planSubColor)
            }
            .frame(maxWidth: .infinity, minHeight: DirtHit.control, alignment: .leading)
            .padding(DirtSpace.inner)
            .background(planFill(selected: selected))
            .clipShape(RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous)
                    .stroke(planStroke(selected: selected), lineWidth: selected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DirtRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) plan, \(price)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var planTitleColor: Color {
        isHard ? .white : DirtTheme.ink
    }

    private var planSubColor: Color {
        isHard ? .white.opacity(0.55) : DirtTheme.muted
    }

    private func planFill(selected: Bool) -> Color {
        if isHard {
            return selected ? DirtTheme.orange.opacity(0.16) : .white.opacity(0.05)
        }
        return selected ? DirtTheme.orange.opacity(0.12) : DirtTheme.rowFill
    }

    private func planStroke(selected: Bool) -> Color {
        if selected { return DirtTheme.orange }
        return isHard ? .white.opacity(0.14) : DirtTheme.hairline
    }

    private var cta: some View {
        VStack(spacing: DirtSpace.tight) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.dirtUI(13, weight: .semibold))
                    .foregroundStyle(DirtTheme.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Purchase error: \(errorMessage)")
            }

            Button {
                Task { await subscribe() }
            } label: {
                Text(primaryActionTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DirtCTAStyle.brand(isLoading: subscription.purchaseInFlight))
            .disabled(subscription.storeOperationInFlight || (!subscription.hasProducts && !BuildChannel.showsTesterUnlock))
            .accessibilityHint(primaryActionHint)

            Button {
                Task {
                    switch await subscription.restore() {
                    case .restored:
                        break // The entitlement change callback completes the pending action once.
                    case .noActiveSubscription:
                        errorMessage = "No purchases found for this Apple ID."
                    case .failed(let message):
                        errorMessage = message
                    }
                }
            } label: {
                Text("Restore purchases")
                    .font(.dirtUI(13, weight: .semibold))
                    .foregroundStyle(isHard ? .white.opacity(0.75) : DirtTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: DirtHit.min)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(subscription.storeOperationInFlight)

            if presentation == .soft {
                Button(action: onClose) {
                    Text("Maybe later")
                        .font(.dirtUI(13, weight: .semibold))
                        .foregroundStyle(DirtTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: DirtHit.min)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if BuildChannel.showsTesterUnlock {
                Button {
                    // Persists until uninstall (UserDefaults). Testers use the app
                    // freely without exercising Export / Start gates.
                    app.debugBypassSubscription = true
                    onSubscribed()
                    app.planner.toast = "Paywall skipped until reinstall"
                } label: {
                    Text("Skip as tester")
                        .font(.dirtUI(12, weight: .semibold))
                        .foregroundStyle(isHard ? .white.opacity(0.4) : DirtTheme.muted.opacity(0.8))
                        .frame(maxWidth: .infinity, minHeight: DirtHit.min)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Hides the paywall until you delete and reinstall the app")
            }
        }
    }

    private var legalFootnote: some View {
        VStack(spacing: DirtSpace.tight) {
            Text(footnoteText)
                .font(.dirtUI(12))
                .foregroundStyle(isHard ? .white.opacity(0.5) : DirtTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Link("Terms", destination: LegalLinks.termsOfUse)
                Link("Privacy", destination: LegalLinks.privacyPolicy)
                Link("EULA", destination: LegalLinks.eula)
            }
            .font(.dirtUI(12, weight: .semibold))
            .foregroundStyle(isHard ? .white.opacity(0.65) : DirtTheme.orange)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DirtSpace.tight)
    }

    private var footnoteText: String {
        let price = priceText(for: selectedPlan)
        if let duration = eligibleTrialDuration {
            return "\(duration) free, then \(price). Renews automatically until cancelled. Manage or cancel in Settings → Apple ID → Subscriptions."
        }
        return "\(price). Renews automatically until cancelled. Manage or cancel in Settings → Apple ID → Subscriptions."
    }

    private func priceText(for plan: SubscriptionService.Plan) -> String {
        guard let product = subscription.product(for: plan) else { return "Price unavailable" }
        return "\(product.displayPrice) per \(plan == .yearly ? "year" : "month")"
    }

    private func displayPrice(for plan: SubscriptionService.Plan) -> String {
        subscription.product(for: plan)?.displayPrice ?? "Price unavailable"
    }

    private func subscribe() async {
        errorMessage = nil
        guard let product = subscription.product(for: selectedPlan) else {
            if BuildChannel.showsTesterUnlock {
                app.trial.markSubscribed()
                onSubscribed()
            } else {
                errorMessage = "Subscriptions are unavailable right now. Try again shortly."
            }
            return
        }
        switch await subscription.purchase(product) {
        case .subscribed:
            break // The entitlement change callback completes the pending action once.
        case .pending:
            errorMessage = "Your purchase is waiting for approval. DIRT PRO will unlock when the App Store completes it."
        case .cancelled:
            break
        case .failed(let message):
            errorMessage = message
        }
    }

    private var availablePlans: [SubscriptionService.Plan] {
        [.yearly, .monthly].filter { subscription.product(for: $0) != nil }
    }

    private var eligibleTrialDuration: String? {
        guard case let .eligible(duration) = subscription.introOfferStatus(for: selectedPlan) else {
            return nil
        }
        return duration
    }

    private var headerTitle: String {
        if isHard { return "Continue with DIRT PRO" }
        if let duration = eligibleTrialDuration { return "Try DIRT PRO free for \(duration)" }
        return "Unlock DIRT PRO"
    }

    private var headerDetail: String {
        if let duration = eligibleTrialDuration {
            return "Ride with everything unlocked. Cancel anytime before your \(duration) trial ends and you won’t be charged."
        }
        return "Get unlimited navigation and GPX export. Cancel anytime in your Apple subscription settings."
    }

    private var primaryActionTitle: String {
        eligibleTrialDuration == nil ? "Subscribe" : "Start free trial"
    }

    private var primaryActionHint: String {
        if let duration = eligibleTrialDuration {
            return "Starts the \(duration) free trial for the selected plan"
        }
        return "Subscribes to the selected DIRT PRO plan"
    }

    private func selectAvailablePlanIfNeeded() {
        guard subscription.product(for: selectedPlan) == nil,
              let first = availablePlans.first
        else { return }
        selectedPlan = first
    }
}
