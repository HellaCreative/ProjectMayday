import Foundation
import Observation
import StoreKit

/// StoreKit 2 wrapper for the DIRT PRO subscription (7-day free trial, then
/// $10/month or $45/year). Products must be created in App Store Connect with
/// these IDs; for local testing, attach `Dirt.storekit` in the run scheme.
@Observable
@MainActor
final class SubscriptionService {
    enum Plan: String, CaseIterable {
        case monthly = "com.mayday.dirt.pro.monthly"
        case yearly = "com.mayday.dirt.pro.yearly"
    }

    private let productIDs = Plan.allCases.map(\.rawValue)

    private(set) var products: [Product] = []
    private(set) var isSubscribed = false
    private(set) var isLoadingProducts = false
    private(set) var purchaseInFlight = false
    private(set) var loadError: String?

    private var updatesTask: Task<Void, Never>?

    var monthly: Product? { product(for: .monthly) }
    var yearly: Product? { product(for: .yearly) }

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
        await loadProducts()
        await refreshEntitlements()
    }

    func loadProducts() async {
        isLoadingProducts = true
        loadError = nil
        defer { isLoadingProducts = false }
        do {
            let loaded = try await Product.products(for: productIDs)
            products = loaded.sorted { $0.price < $1.price }
        } catch {
            loadError = "Could not load subscription options. Check your connection and try again."
        }
    }

    /// Returns true if the purchase resulted in an active subscription.
    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            let result = try await product.purchase()
            switch result {
            case let .success(verification):
                await handle(verification: verification)
                return isSubscribed
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            loadError = "The purchase could not be completed. You were not charged."
            return false
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlements()
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
}
