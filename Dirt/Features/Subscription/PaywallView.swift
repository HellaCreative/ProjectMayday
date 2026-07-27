import StoreKit
import SwiftUI

/// The 7-day free trial offer. Presented softly (with an X) after light map use
/// and as a hard gate (no X) once the escalation ceiling is hit.
struct PaywallView: View {
    @Environment(AppEnvironment.self) private var app
    let presentation: TrialPresentation
    var onClose: () -> Void
    var onSubscribed: () -> Void

    @State private var selectedPlan: SubscriptionService.Plan = .yearly
    @State private var errorMessage: String?

    private var subscription: SubscriptionService { app.subscription }

    private let perks = [
        ("map.fill", "Full off-road basemap", "3D terrain, surface layers, and the whole DIRT map."),
        ("point.topleft.down.to.point.bottomright.curvepath.fill", "Turn-by-turn rally cues", "Junction + rally curve cues with voice guidance."),
        ("person.2.fill", "Live group ride sharing", "See your crew and broadcast your status in real time."),
        ("square.and.arrow.down.fill", "Offline-ready routes", "Save and export rides for when the signal drops.")
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 12)
                card
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 18)
        }
        .task { await subscription.refresh() }
        .onChange(of: subscription.isSubscribed) { _, subscribed in
            if subscribed { onSubscribed() }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            perkList
            planPicker
            cta
            legalFootnote
        }
        .padding(22)
        .background(DirtTheme.chrome)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(DirtTheme.chromeBorder, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if presentation == .soft {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .padding(14)
                .accessibilityLabel("Close")
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("DIRT")
                    .italic()
                    .font(.dirtUI(22, weight: .black))
                    .foregroundStyle(.white)
                Text("PRO")
                    .font(.dirtMono(11, weight: .bold))
                    .tracking(3)
                    .foregroundStyle(DirtTheme.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(Capsule().stroke(DirtTheme.orange.opacity(0.6), lineWidth: 1))
            }
            Text("Start your 7-day free trial")
                .font(.dirtUI(24, weight: .heavy))
                .foregroundStyle(.white)
            Text("Ride with everything unlocked. Cancel anytime before the trial ends and you won't be charged.")
                .font(.dirtUI(13))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var perkList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(perks, id: \.0) { icon, title, detail in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DirtTheme.orange)
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.dirtUI(13, weight: .bold))
                            .foregroundStyle(.white)
                        Text(detail)
                            .font(.dirtUI(11))
                            .foregroundStyle(.white.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var planPicker: some View {
        HStack(spacing: 10) {
            planCard(.yearly, title: "Yearly", price: priceText(for: .yearly), sub: "billed annually", badge: subscription.yearlySavingsLabel ?? "Best value")
            planCard(.monthly, title: "Monthly", price: priceText(for: .monthly), sub: "billed monthly", badge: nil)
        }
    }

    private func planCard(_ plan: SubscriptionService.Plan, title: String, price: String, sub: String, badge: String?) -> some View {
        let selected = selectedPlan == plan
        return Button {
            selectedPlan = plan
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.dirtUI(13, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    if let badge {
                        Text(badge)
                            .font(.dirtMono(8, weight: .bold))
                            .tracking(0.4)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(DirtTheme.orange)
                            .clipShape(Capsule())
                    }
                }
                Text(price)
                    .font(.dirtMono(16, weight: .bold))
                    .foregroundStyle(.white)
                Text(sub)
                    .font(.dirtUI(10))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(selected ? DirtTheme.orange.opacity(0.16) : .white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? DirtTheme.orange : .white.opacity(0.14), lineWidth: selected ? 2 : 1)
            )
        }
        .accessibilityLabel("\(title) plan, \(price)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var cta: some View {
        VStack(spacing: 10) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.dirtUI(11, weight: .semibold))
                    .foregroundStyle(DirtTheme.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { await startTrial() }
            } label: {
                if subscription.purchaseInFlight {
                    ProgressView().tint(.white).frame(maxWidth: .infinity)
                } else {
                    Text("Start free trial").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(DirtCTAStyle(fill: DirtTheme.orange))
            .disabled(subscription.purchaseInFlight || (!subscription.hasProducts && !BuildChannel.showsTesterUnlock))

            HStack {
                Button("Restore purchases") {
                    Task { await subscription.restore() }
                }
                .font(.dirtUI(11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))

                if presentation == .soft {
                    Spacer()
                    Button("Maybe later", action: onClose)
                        .font(.dirtUI(11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            if BuildChannel.showsTesterUnlock {
                Button("Skip paywall (tester)") {
                    app.debugBypassSubscription = true
                    app.trial.markSubscribed()
                    onSubscribed()
                }
                .font(.dirtUI(11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
        }
    }

    private var legalFootnote: some View {
        VStack(spacing: 6) {
            Text(footnoteText)
                .font(.dirtUI(9.5))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Link("Terms", destination: LegalLinks.termsOfUse)
                Link("Privacy", destination: LegalLinks.privacyPolicy)
            }
            .font(.dirtUI(10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity)
    }

    private var footnoteText: String {
        let price = priceText(for: selectedPlan)
        return "7 days free, then \(price). Renews automatically until cancelled. Manage or cancel in Settings."
    }

    private func priceText(for plan: SubscriptionService.Plan) -> String {
        if let product = subscription.product(for: plan) {
            return "\(product.displayPrice)/\(plan == .yearly ? "yr" : "mo")"
        }
        return plan == .yearly ? "$45/yr" : "$10/mo"
    }

    private func startTrial() async {
        errorMessage = nil
        guard let product = subscription.product(for: selectedPlan) else {
            if BuildChannel.showsTesterUnlock {
                // No StoreKit products — let the gate flow be exercised.
                app.trial.markSubscribed()
                onSubscribed()
            } else {
                errorMessage = "Subscriptions are unavailable right now. Try again shortly."
            }
            return
        }
        let success = await subscription.purchase(product)
        if success {
            onSubscribed()
        } else if let loadError = subscription.loadError {
            errorMessage = loadError
        }
    }
}
