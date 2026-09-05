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
                await self?.handleUpdate(verification: update)
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
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        RoutingDebugLog.shared.event(
            "storekit products request begin bundle=\(bundleID) ids=[\(productIDs.joined(separator: ","))]"
        )
        do {
            let loaded = try await Product.products(for: productIDs)
            guard !loaded.isEmpty else {
                products = []
                introOfferStatuses = Dictionary(
                    uniqueKeysWithValues: Plan.allCases.map { ($0, .unavailable) }
                )
                loadError = "Subscription options are unavailable right now. Try again shortly."
                RoutingDebugLog.shared.event(
                    "storekit products response empty bundle=\(bundleID) requested=\(productIDs.count) "
                        + "hint=local_configuration_inactive_or_catalog_products_unavailable"
                )
                return
            }
            products = loaded.sorted { $0.price < $1.price }
            RoutingDebugLog.shared.event(
                "storekit products response loaded bundle=\(bundleID) count=\(loaded.count) "
                    + "ids=[\(loaded.map(\.id).sorted().joined(separator: ","))]"
            )
            await refreshIntroOfferStatuses(for: loaded)
        } catch {
            products = []
            introOfferStatuses = Dictionary(
                uniqueKeysWithValues: Plan.allCases.map { ($0, .unavailable) }
            )
            loadError = "Could not load subscription options. Check your connection and try again."
            let nsError = error as NSError
            RoutingDebugLog.shared.event(
                "storekit products request failed bundle=\(bundleID) domain=\(nsError.domain) "
                    + "code=\(nsError.code) msg=\(error.localizedDescription)"
            )
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
        RoutingDebugLog.shared.event("storekit purchase begin product=\(product.id)")
        do {
            let result = try await product.purchase()
            switch result {
            case let .success(.verified(transaction)):
                // A verified successful purchase is the entitlement handoff.
                // Unlock first, then finish the transaction. Re-querying
                // currentEntitlements before unlocking can briefly return the
                // pre-purchase snapshot in a local StoreKit session.
                let granted = applyVerifiedEntitlement(transaction, source: "purchase")
                await transaction.finish()
                RoutingDebugLog.shared.event(
                    "storekit purchase finished product=\(transaction.productID) granted=\(granted ? 1 : 0)"
                )
                return granted
                    ? .subscribed
                    : .failed(message: "The App Store purchase is not currently active. Check your purchase history, then use Restore Purchases.")
            case let .success(.unverified(_, error)):
                let nsError = error as NSError
                RoutingDebugLog.shared.event(
                    "storekit purchase unverified product=\(product.id) domain=\(nsError.domain) code=\(nsError.code)"
                )
                return .failed(message: "The App Store purchase could not be verified. Check your purchase history, then use Restore Purchases.")
            case .userCancelled:
                RoutingDebugLog.shared.event("storekit purchase cancelled product=\(product.id)")
                return .cancelled
            case .pending:
                RoutingDebugLog.shared.event("storekit purchase pending product=\(product.id)")
                return .pending
            @unknown default:
                RoutingDebugLog.shared.event("storekit purchase unknown product=\(product.id)")
                return .failed(message: "The App Store returned an unknown purchase result. Try again later.")
            }
        } catch {
            let nsError = error as NSError
            RoutingDebugLog.shared.event(
                "storekit purchase failed product=\(product.id) domain=\(nsError.domain) code=\(nsError.code)"
            )
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
        RoutingDebugLog.shared.event("storekit restore begin")
        do {
            try await AppStore.sync()
        } catch {
            let nsError = error as NSError
            RoutingDebugLog.shared.event(
                "storekit restore failed domain=\(nsError.domain) code=\(nsError.code)"
            )
            return .failed(message: "Purchases could not be restored. Check your connection and try again.")
        }
        await refreshEntitlements()
        RoutingDebugLog.shared.event("storekit restore complete active=\(isSubscribed ? 1 : 0)")
        return isSubscribed ? .restored : .noActiveSubscription
    }

    private func refreshEntitlements() async {
        var activeProductIDs: [String] = []
        var unverifiedCount = 0
        for await result in Transaction.currentEntitlements {
            switch result {
            case let .verified(transaction):
                if transactionIsActive(transaction) {
                    activeProductIDs.append(transaction.productID)
                }
            case .unverified:
                unverifiedCount += 1
            }
        }
        isSubscribed = !activeProductIDs.isEmpty
        RoutingDebugLog.shared.event(
            "storekit entitlements refreshed active=\(isSubscribed ? 1 : 0) "
                + "products=[\(activeProductIDs.sorted().joined(separator: ","))] unverified=\(unverifiedCount)"
        )
    }

    private func handleUpdate(verification: VerificationResult<Transaction>) async {
        guard case let .verified(transaction) = verification else {
            RoutingDebugLog.shared.event("storekit transaction update unverified")
            return
        }
        _ = applyVerifiedEntitlement(transaction, source: "update")
        await transaction.finish()
        // Updates also carry expiration, revocation, and upgrade changes. A
        // complete refresh removes access only when no active DIRT PRO
        // entitlement remains.
        await refreshEntitlements()
    }

    @discardableResult
    private func applyVerifiedEntitlement(_ transaction: Transaction, source: String) -> Bool {
        let active = transactionIsActive(transaction)
        if active {
            isSubscribed = true
        }
        RoutingDebugLog.shared.event(
            "storekit transaction verified source=\(source) product=\(transaction.productID) "
                + "recognized=\(productIDs.contains(transaction.productID) ? 1 : 0) "
                + "revoked=\(transaction.revocationDate == nil ? 0 : 1) "
                + "upgraded=\(transaction.isUpgraded ? 1 : 0) active=\(active ? 1 : 0)"
        )
        return active
    }

    private func transactionIsActive(_ transaction: Transaction, now: Date = .now) -> Bool {
        Self.entitlementIsActive(
            productID: transaction.productID,
            revocationDate: transaction.revocationDate,
            isUpgraded: transaction.isUpgraded,
            expirationDate: transaction.expirationDate,
            now: now
        )
    }

    nonisolated static func entitlementIsActive(
        productID: String,
        revocationDate: Date?,
        isUpgraded: Bool,
        expirationDate: Date?,
        now: Date
    ) -> Bool {
        guard Plan(rawValue: productID) != nil,
              revocationDate == nil,
              !isUpgraded else { return false }
        return expirationDate.map { $0 > now } ?? true
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
