import Foundation
import Testing
@testable import Dirt

@Suite("Subscription contract")
struct StoreKitCatalogueTests {
    @Test
    func localCatalogueDefinesBothPlansAndSevenDayTrial() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appending(path: "Dirt/Dirt.storekit"))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let groups = try #require(root["subscriptionGroups"] as? [[String: Any]])
        let subscriptions = groups.flatMap { $0["subscriptions"] as? [[String: Any]] ?? [] }

        #expect(Set(subscriptions.compactMap { $0["productID"] as? String }) == Set([
            SubscriptionService.Plan.monthly.rawValue,
            SubscriptionService.Plan.yearly.rawValue,
        ]))

        let yearly = try #require(subscriptions.first {
            $0["productID"] as? String == SubscriptionService.Plan.yearly.rawValue
        })
        let introductoryOffer = try #require(yearly["introductoryOffer"] as? [String: Any])
        #expect(introductoryOffer["paymentMode"] as? String == "free")
        #expect(introductoryOffer["subscriptionPeriod"] as? String == "P1W")
    }

    @Test
    func verifiedMonthlyTransactionIsAnActiveEntitlement() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let productID = SubscriptionService.Plan.monthly.rawValue

        #expect(SubscriptionService.entitlementIsActive(
            productID: productID,
            revocationDate: nil,
            isUpgraded: false,
            expirationDate: now.addingTimeInterval(3600),
            now: now
        ), "Cancelling renewal must not remove access before the paid period expires.")
        #expect(!SubscriptionService.entitlementIsActive(
            productID: productID,
            revocationDate: nil,
            isUpgraded: true,
            expirationDate: now.addingTimeInterval(3600),
            now: now
        ))
        #expect(!SubscriptionService.entitlementIsActive(
            productID: productID,
            revocationDate: now,
            isUpgraded: false,
            expirationDate: now.addingTimeInterval(3600),
            now: now
        ))
        #expect(!SubscriptionService.entitlementIsActive(
            productID: productID,
            revocationDate: nil,
            isUpgraded: false,
            expirationDate: now.addingTimeInterval(-1),
            now: now
        ))
    }
}
