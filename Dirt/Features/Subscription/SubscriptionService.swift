import Foundation
import Observation
import StoreKit

/// StoreKit 2 wrapper for DIRT PRO. Price and introductory-offer copy must come
/// from StoreKit rather than assumptions baked into the app.
@Observable
@MainActor
final class SubscriptionService {
    enum StoreOperation: Equatable {
        case purchase
        case restore
    }

    enum Plan: String, CaseIterable, Hashable {
        case monthly = "com.mayday.dirt.pro.monthly"
        case yearly = "com.mayday.dirt.pro.yearly"
    }

    enum IntroOfferStatus: Equatable {
        case checking
        case eligible(duration: String)
        case unavailable
    }

    enum PurchaseOutcome: Equatable {
        case subscribed
        case pending
        case cancelled
        case failed(message: String)
    }

    enum RestoreOutcome: Equatable {
        case restored
        case noActiveSubscription
        case failed(message: String)
    }

    private let productIDs = Plan.allCases.map(\.rawValue)

    private(set) var products: [Product] = []
    private(set) var isSubscribed = false
    private(set) var isLoadingProducts = false
    private(set) var operationInFlight: StoreOperation?
    private(set) var loadError: String?
    private(set) var introOfferStatuses: [Plan: IntroOfferStatus] = Dictionary(
        uniqueKeysWithValues: Plan.allCases.map { ($0, .checking) }
    )

    private var updatesTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    var monthly: Product? { product(for: .monthly) }
    var yearly: Product? { product(for: .yearly) }
    var purchaseInFlight: Bool { operationInFlight == .purchase }
    var restoreInFlight: Bool { operationInFlight == .restore }
    var storeOperationInFlight: Bool { operationInFlight != nil }

    /// True once we've reached App Store / a StoreKit config. When false the
    /// paywall shows fallback copy instead of live prices.
    var hasProducts: Bool { !products.isEmpty }

    init() {
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(verification: update)
            }
        }
        Task { await refresh() }
    }

    func product(for plan: Plan) -> Product? {
        products.first { $0.id == plan.rawValue }
    }

    func introOfferStatus(for plan: Plan) -> IntroOfferStatus {
        introOfferStatuses[plan] ?? .checking
    }

    /// Yearly framed as the anchor: cheaper per month than paying monthly.
    var yearlySavingsLabel: String? {
        guard let monthly, let yearly else { return nil }
        let monthlyPrice = NSDecimalNumber(decimal: monthly.price).doubleValue
        let yearlyPrice = NSDecimalNumber(decimal: yearly.price).doubleValue
        let annualized = monthlyPrice * 12
        guard annualized > 0, yearlyPrice < annualized else { return nil }
        let saved = (1 - (yearlyPrice / annualized)) * 100
        return "Save \(Int(saved.rounded()))%"
    }

    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadProducts()
            await self.refreshEntitlements()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    func loadProducts() async {
        isLoadingProducts = true
        loadError = nil
        defer { isLoadingProducts = false }
        do {
            let loaded = try await Product.products(for: productIDs)
            guard !loaded.isEmpty else {
                products = []
                introOfferStatuses = Dictionary(
                    uniqueKeysWithValues: Plan.allCases.map { ($0, .unavailable) }
                )
                loadError = "Subscription options are unavailable right now. Try again shortly."
                return
            }
            products = loaded.sorted { $0.price < $1.price }
            await refreshIntroOfferStatuses(for: loaded)
        } catch {
            products = []
            introOfferStatuses = Dictionary(
                uniqueKeysWithValues: Plan.allCases.map { ($0, .unavailable) }
            )
            loadError = "Could not load subscription options. Check your connection and try again."
        }
    }

    /// Reports each StoreKit outcome distinctly so pending approval is never
    /// presented as a failure and cancellation never produces a false error.
    @discardableResult
    func purchase(_ product: Product) async -> PurchaseOutcome {
        guard operationInFlight == nil else {
            return .failed(message: "Another App Store request is already in progress.")
        }
        operationInFlight = .purchase
        defer { operationInFlight = nil }
        do {
            let result = try await product.purchase()
            switch result {
            case let .success(verification):
                await handle(verification: verification)
                return isSubscribed
                    ? .subscribed
                    : .failed(message: "The App Store purchase could not be verified. Check your purchase history, then use Restore Purchases.")
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed(message: "The App Store returned an unknown purchase result. Try again later.")
            }
        } catch {
            return .failed(message: "The purchase result could not be confirmed. Check your App Store purchase history, then use Restore Purchases.")
        }
    }

    @discardableResult
    func restore() async -> RestoreOutcome {
        guard operationInFlight == nil else {
            return .failed(message: "Another App Store request is already in progress.")
        }
        operationInFlight = .restore
        defer { operationInFlight = nil }
        do {
            try await AppStore.sync()
        } catch {
            return .failed(message: "Purchases could not be restored. Check your connection and try again.")
        }
        await refreshEntitlements()
        return isSubscribed ? .restored : .noActiveSubscription
    }

    private func refreshEntitlements() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result else { continue }
            if productIDs.contains(transaction.productID), transaction.revocationDate == nil {
                active = true
            }
        }
        isSubscribed = active
    }

    private func handle(verification: VerificationResult<Transaction>) async {
        guard case let .verified(transaction) = verification else { return }
        await transaction.finish()
        await refreshEntitlements()
    }

    private func refreshIntroOfferStatuses(for loaded: [Product]) async {
        var resolved = Dictionary(
            uniqueKeysWithValues: Plan.allCases.map { ($0, IntroOfferStatus.unavailable) }
        )
        var eligibilityByGroup: [String: Bool] = [:]

        for product in loaded {
            guard let plan = Plan(rawValue: product.id),
                  let subscription = product.subscription,
                  let offer = subscription.introductoryOffer,
                  offer.paymentMode == .freeTrial
            else { continue }

            let isEligible: Bool
            if let cached = eligibilityByGroup[subscription.subscriptionGroupID] {
                isEligible = cached
            } else {
                isEligible = await subscription.isEligibleForIntroOffer
                eligibilityByGroup[subscription.subscriptionGroupID] = isEligible
            }

            if isEligible {
                resolved[plan] = .eligible(duration: Self.durationText(for: offer.period))
            }
        }

        introOfferStatuses = resolved
    }

    private static func durationText(for period: Product.SubscriptionPeriod) -> String {
        let unit: String
        switch period.unit {
        case .day: unit = period.value == 1 ? "day" : "days"
        case .week: unit = period.value == 1 ? "week" : "weeks"
        case .month: unit = period.value == 1 ? "month" : "months"
        case .year: unit = period.value == 1 ? "year" : "years"
        @unknown default: unit = period.value == 1 ? "period" : "periods"
        }
        return "\(period.value) \(unit)"
    }
}
