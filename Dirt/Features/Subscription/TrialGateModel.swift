import Foundation
import Observation
import Security

private enum TrialGateStorageKey {
    nonisolated static let freeStartsUsed = "dirt.paywall.freeStartsUsed.v1"
}

/// Soft paywall trigger — what the rider was trying to do when the wall came up.
enum PaywallReason: Equatable {
    case export
    case start
}

/// How a paywall should be presented. Soft (dismissible) is the live path —
/// `hard` remains for the full-screen shell in `PaywallView` but is unused by the gate.
enum TrialPresentation: Equatable {
    case soft
    case hard
}

/// Freemium gate for DIRT PRO.
///
/// - **Plan forever** — no clock, no map-time ladder.
/// - **Save locally** — always available.
/// - **Export GPX** — soft paywall on tap until subscribed.
/// - **Start** — two free ride tests on this device, then soft paywall on every Start.
///
/// Free-start count lives in the Keychain so deleting the app does not reset it.
@Observable
@MainActor
final class TrialGateModel {
    /// Full rides a non-subscriber may start before Start itself is gated.
    static let freeStartAllowance = 2

    private(set) var freeStartsUsed: Int
    private let persistFreeStarts: (Int) -> Void
    private(set) var presentation: TrialPresentation?
    /// Why the wall is up — used for toast on dismiss and to resume after subscribe.
    private(set) var pendingReason: PaywallReason?

    var isSubscribed = false {
        didSet {
            if isSubscribed { presentation = nil }
            // `pendingReason` survives until `takePendingReason()` so Export or
            // Start can resume after a successful subscribe.
        }
    }

    var freeStartsRemaining: Int {
        max(0, Self.freeStartAllowance - freeStartsUsed)
    }

    var canStartNavigation: Bool {
        isSubscribed || freeStartsUsed < Self.freeStartAllowance
    }

    init(
        initialFreeStartsUsed: Int? = nil,
        persistFreeStarts: @escaping (Int) -> Void = {
            KeychainInt.save($0, for: TrialGateStorageKey.freeStartsUsed)
        }
    ) {
        freeStartsUsed = max(
            0,
            initialFreeStartsUsed ?? KeychainInt.load(TrialGateStorageKey.freeStartsUsed) ?? 0
        )
        self.persistFreeStarts = persistFreeStarts
        // Scrub the old map-time ladder so leftover defaults don't confuse testers.
        Self.scrubLegacyDefaults()
    }

    // MARK: - Feature checks

    /// Local route saving is part of the free planning experience.
    @discardableResult
    func requestSave() -> Bool {
        true
    }

    /// Returns `true` when Export may proceed. Otherwise presents the soft wall.
    @discardableResult
    func requestExport() -> Bool {
        gate(.export)
    }

    /// Returns `true` when Start may proceed (subscriber, or free tastes left).
    /// Does **not** consume a free start — that happens when the ride actually begins.
    @discardableResult
    func requestStart() -> Bool {
        guard !isSubscribed else { return true }
        if freeStartsUsed < Self.freeStartAllowance { return true }
        presentSoft(for: .start)
        return false
    }

    /// Call once when navigation leaves prep and the live ride begins.
    /// No-op for subscribers and once the allowance is already spent.
    func consumeFreeStartIfNeeded() {
        guard !isSubscribed, freeStartsUsed < Self.freeStartAllowance else { return }
        freeStartsUsed += 1
        persistFreeStarts(freeStartsUsed)
    }

    // MARK: - Presentation

    func dismissSoft() {
        guard presentation == .soft else { return }
        presentation = nil
        // Leave `pendingReason` long enough for the sheet's onDismiss toast, then clear.
    }

    /// Toast copy after the rider closes the wall without subscribing.
    func dismissMessage() -> String? {
        defer { pendingReason = nil }
        switch pendingReason {
        case .export: return "Subscribe to export GPX"
        case .start: return "Subscribe to start navigation"
        case nil: return nil
        }
    }

    /// Action to resume after a successful subscribe, if any.
    func takePendingReason() -> PaywallReason? {
        let reason = pendingReason
        pendingReason = nil
        presentation = nil
        return reason
    }

    func markSubscribed() {
        isSubscribed = true
        presentation = nil
    }

    /// Profile tester control — restores both free Starts and clears any open wall.
    func resetForTesting() {
        freeStartsUsed = 0
        persistFreeStarts(0)
        presentation = nil
        pendingReason = nil
        Self.scrubLegacyDefaults()
    }

    // MARK: - Private

    private func gate(_ reason: PaywallReason) -> Bool {
        guard !isSubscribed else { return true }
        presentSoft(for: reason)
        return false
    }

    private func presentSoft(for reason: PaywallReason) {
        guard presentation == nil else { return }
        pendingReason = reason
        presentation = .soft
    }

    private static func scrubLegacyDefaults() {
        let defaults = UserDefaults.standard
        for key in [
            "dirt_trial_map_seconds_v1",
            "dirt_trial_exposures_v1",
            "dirt_trial_last_exposure_seconds_v1",
            "dirt_trial_tour_held_seconds_v1",
        ] {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - Keychain Int

/// Tiny Keychain wrapper for a single Int. Survives app delete + reinstall on iOS,
/// which is the whole point of parking the free-start counter here instead of
/// UserDefaults.
private enum KeychainInt {
    nonisolated static func load(_ account: String) -> Int? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.mayday.dirt",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let raw = String(data: data, encoding: .utf8),
              let value = Int(raw)
        else { return nil }
        return value
    }

    nonisolated static func save(_ value: Int, for account: String) {
        let data = Data(String(value).utf8)
        let service = Bundle.main.bundleIdentifier ?? "com.mayday.dirt"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
