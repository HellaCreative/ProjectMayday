import StoreKit
import SwiftUI

/// StoreKit-backed DIRT PRO purchase surface.
/// Soft: dismissible system sheet. Hard: full-screen gate (Subscribe / Restore only).
struct PaywallView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let presentation: TrialPresentation
    var onClose: () -> Void
    var onSubscribed: () -> Void

    @State private var selectedPlan: SubscriptionService.Plan = .yearly
    @State private var errorMessage: String?

    private var subscription: SubscriptionService { app.subscription }
    private var isHard: Bool { presentation == .hard }

    private struct Feature: Identifiable {
        let id: String
        let icon: String
        let title: String
        let detail: String
    }

    private let features = [
        Feature(
            id: "dirt-routing",
            icon: "point.topleft.down.to.point.bottomright.curvepath.fill",
            title: "Dirt-first routes",
            detail: "Build rides for the most rewarding dirt—not simply the shortest way there."
        ),
        Feature(
            id: "fuel",
            icon: "fuelpump.fill",
            title: "Fuel-aware planning",
            detail: "Place sensible fuel stops into long rides using your bike’s usable range."
        ),
        Feature(
            id: "navigation",
            icon: "location.north.line.fill",
            title: "Ride-focused navigation",
            detail: "Follow junction, rally, and voice cues with near-term maps prepared for the trail."
        ),
        Feature(
            id: "groups",
            icon: "person.2.wave.2.fill",
            title: "Live rider groups",
            detail: "Keep your crew visible and share clear riding or assistance status."
        ),
        Feature(
            id: "gpx",
            icon: "doc.badge.arrow.up.fill",
            title: "GPX route tools",
            detail: "Bring rides into DIRT, refine them, and export them to compatible riding devices."
        )
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
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView {
                    VStack(spacing: 0) {
                        fixedHeader
                        featureStory
                        purchasePanel
                    }
                }
            } else {
                VStack(spacing: 0) {
                    fixedHeader
                    featureScroller
                    purchasePanel
                }
            }
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            if presentation == .soft {
                softCloseBar
            }
        }
    }

    private var fixedHeader: some View {
        header
            .padding(.horizontal, DirtSpace.section)
            .padding(.top, DirtSpace.hairGap)
            .padding(.bottom, DirtSpace.row)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var featureStory: some View {
        VStack(alignment: .leading, spacing: 0) {
            featureList
        }
        .padding(.horizontal, DirtSpace.section)
        .padding(.vertical, DirtSpace.tight)
        .accessibilityIdentifier("paywall-feature-story")
    }

    private var featureScroller: some View {
        ZStack {
            ScrollView {
                featureStory
            }
            .scrollIndicators(.hidden)

            VStack(spacing: 0) {
                scrollFade(edge: .top)
                Spacer(minLength: 0)
                scrollFade(edge: .bottom)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .clipped()
    }

    private enum ScrollFadeEdge {
        case top
        case bottom
    }

    private func scrollFade(edge: ScrollFadeEdge) -> some View {
        Rectangle()
            .fill(isHard ? .ultraThinMaterial : DirtTheme.sheetMaterial)
            .mask(
                LinearGradient(
                    colors: edge == .top ? [.black, .clear] : [.clear, .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(height: 24)
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
                    .font(.dirtUI(19, weight: .black))
                    .foregroundStyle(isHard ? .white : DirtTheme.ink)
                Text("PRO")
                    .font(.dirtMono(10, weight: .bold))
                    .tracking(2.4)
                    .foregroundStyle(DirtTheme.onOrange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(DirtTheme.orange, in: Capsule())
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("DIRT PRO")

            Text(headerTitle)
                .font(.system(.title2, design: .default, weight: .bold))
                .foregroundStyle(isHard ? .white : DirtTheme.ink)
                .tracking(-0.35)
                .fixedSize(horizontal: false, vertical: true)

            Text(headerDetail)
                .font(.system(.subheadline, design: .default, weight: .regular))
                .foregroundStyle(isHard ? .white.opacity(0.7) : DirtTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: DirtSpace.tight) {
            ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                HStack(alignment: .center, spacing: 12) {
                    featureIcon(feature.icon, index: index)

                    VStack(alignment: .leading, spacing: DirtSpace.hairGap) {
                        Text(feature.title)
                            .font(.system(.subheadline, design: .default, weight: .semibold))
                            .foregroundStyle(isHard ? .white : DirtTheme.ink)
                        Text(feature.detail)
                            .font(.system(.footnote, design: .default, weight: .regular))
                            .foregroundStyle(isHard ? .white.opacity(0.62) : DirtTheme.muted)
                            .lineSpacing(1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(minHeight: 68)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func featureIcon(_ symbol: String, index: Int) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(isHard ? .white.opacity(0.07) : DirtTheme.wash)
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(DirtTheme.orange.opacity(isHard ? 0.7 : 0.34), lineWidth: 1)
            Circle()
                .fill(DirtTheme.orange.opacity(0.14))
                .frame(width: 36, height: 36)
                .offset(x: index.isMultiple(of: 2) ? 8 : -8, y: -7)
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DirtTheme.orange)
        }
        .frame(width: 56, height: 56)
        .accessibilityHidden(true)
    }

    private var purchasePanel: some View {
        VStack(alignment: .leading, spacing: DirtSpace.tight) {
            if subscription.hasProducts {
                purchaseSummary
            }
            planPicker
            cta
            legalFootnote
        }
        .padding(.horizontal, DirtSpace.section)
        .padding(.top, DirtSpace.inner)
        .padding(.bottom, DirtSpace.tight)
        .background {
            Rectangle()
                .fill(isHard ? Color(dirtHex: 0x16181C) : DirtTheme.sheet)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(isHard ? Color.white.opacity(0.12) : DirtTheme.hairline)
                        .frame(height: 1)
                }
                .shadow(color: .black.opacity(isHard ? 0.18 : 0.10), radius: 18, y: -5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("paywall-purchase-panel")
    }

    private var purchaseSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(purchaseHeadline)
                .font(.system(.subheadline, design: .default, weight: .semibold))
                .foregroundStyle(isHard ? .white : DirtTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(purchaseDetail)
                .font(.system(.caption, design: .default, weight: .regular))
                .foregroundStyle(isHard ? .white.opacity(0.66) : DirtTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
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
            HStack(spacing: DirtSpace.inner) {
                Text("Plans unavailable")
                    .font(.dirtUI(14, weight: .bold))
                    .foregroundStyle(isHard ? .white : DirtTheme.ink)
                Spacer(minLength: 0)
                Button("Retry") {
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
            .accessibilityElement(children: .contain)
            .accessibilityHint(subscription.loadError ?? "Subscription options could not be loaded right now.")
        } else {
            HStack(spacing: DirtSpace.tight) {
                ForEach(availablePlans, id: \.rawValue) { plan in
                    planCard(
                        plan,
                        title: plan == .yearly ? "12 months" : "1 month",
                        price: displayPrice(for: plan),
                        sub: plan == .yearly ? "Billed yearly" : "Billed monthly",
                        badge: plan == .yearly ? (subscription.yearlySavingsLabel ?? "Best value") : "Flexible"
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
            VStack(alignment: .center, spacing: DirtSpace.hairGap) {
                if let badge {
                    Text(badge)
                        .font(.system(.caption2, design: .default, weight: .bold))
                        .foregroundStyle(DirtTheme.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Text(title)
                    .font(.system(.footnote, design: .default, weight: .semibold))
                    .foregroundStyle(planTitleColor)
                    .lineLimit(1)
                Text(price)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(planTitleColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(sub)
                    .font(.system(.caption2, design: .default, weight: .medium))
                    .foregroundStyle(planSubColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .center)
            .padding(.horizontal, DirtSpace.tight)
            .padding(.vertical, 4)
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
        .accessibilityIdentifier("paywall-plan-\(plan.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var planTitleColor: Color {
        isHard ? .white : DirtTheme.ink
    }

    private var planSubColor: Color {
        isHard ? .white.opacity(0.55) : DirtTheme.muted
    }

    private func planFill(selected: Bool) -> Color {
        if selected { return DirtTheme.orange.opacity(isHard ? 0.16 : 0.11) }
        if isHard {
            return .white.opacity(0.05)
        }
        return DirtTheme.rowFill
    }

    private func planStroke(selected: Bool) -> Color {
        if selected { return DirtTheme.orange }
        return isHard ? .white.opacity(0.14) : DirtTheme.hairline
    }

    private var cta: some View {
        VStack(spacing: DirtSpace.hairGap) {
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
            .accessibilityIdentifier("paywall-primary-action")
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

        }
    }

    private var legalFootnote: some View {
        VStack(spacing: DirtSpace.hairGap) {
            Text(footnoteText)
                .font(.system(.caption2, design: .default, weight: .regular))
                .foregroundStyle(isHard ? .white.opacity(0.5) : DirtTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Link("Terms", destination: LegalLinks.termsOfUse)
                Link("Privacy", destination: LegalLinks.privacyPolicy)
                Link("EULA", destination: LegalLinks.eula)
            }
            .font(.system(.caption2, design: .default, weight: .semibold))
            .foregroundStyle(isHard ? .white.opacity(0.65) : DirtTheme.orange)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DirtSpace.hairGap)
    }

    private var footnoteText: String {
        guard subscription.hasProducts else {
            return "Prices and trial eligibility are supplied by the App Store."
        }
        let price = priceText(for: selectedPlan)
        if let duration = eligibleTrialDuration {
            return "\(duration) free, then \(price). Renews automatically until cancelled. Manage or cancel in Settings → Apple ID → Subscriptions."
        }
        return "\(price). Renews automatically until cancelled. Manage or cancel in Settings → Apple ID → Subscriptions."
    }

    private var purchaseHeadline: String {
        let price = priceText(for: selectedPlan)
        if let duration = eligibleTrialDuration {
            return "Try \(duration) free, then \(price)"
        }
        return price
    }

    private var purchaseDetail: String {
        selectedPlan == .yearly
            ? "Unlimited navigation and GPX export. Best value for a full riding season."
            : "Unlimited navigation and GPX export with monthly flexibility."
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
