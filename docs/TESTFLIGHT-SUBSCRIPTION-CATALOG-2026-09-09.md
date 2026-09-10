# TestFlight subscription catalog repair — September 9, 2026

## Observed cause

The authenticated App Store Connect page for Dirt by Mayday (app 6794633890) had **no subscription group or products**. Local Xcode StoreKit configuration does not populate Apple’s catalog. Production archive bundle identifier is `com.mayday.dirt`; the app requests `com.mayday.dirt.pro.monthly` and `com.mayday.dirt.pro.yearly`.

## Saved in App Store Connect

- DIRT PRO group: `22373005`.
- DIRT PRO Monthly: Apple ID `6810458857`, product ID `com.mayday.dirt.pro.monthly`, duration **1 month**.
- Monthly availability: **Canada and United States only**.
- Monthly price: **USD 9.99 / CAD 12.99**, confirmed in Apple’s price review before saving. Apple calculates prices for other storefronts but availability is restricted to the two selected countries.
- DIRT PRO Yearly: Apple ID `6810462226`, product ID `com.mayday.dirt.pro.yearly`, duration **1 year** with upfront annual billing.
- Yearly availability: **Canada and United States only**.
- Yearly price: **USD 39.99 / CAD 49.99**, verified in Apple’s price review and saved.
- Both products have saved English (U.S.) display names and descriptions: DIRT PRO Monthly / Yearly, and “Full DIRT access, billed monthly.” / “Full DIRT access, billed yearly.”
- Yearly introductory offer saved and visible under Current Introductory Offers: **Free for the first week**, Canada and United States, starts September 9, 2026, no end date. No monthly trial created.
- No review submission, app upload, purchase, tester bypass, or archive change performed.

## Remaining

- Group localization: English (U.S.) selected in open form; group display-name save **not confirmed**.
- Arrange monthly/yearly at same service level since both provide the same entitlement; currently creation order assigned monthly level1/yearly level2.
- Optional explicit English (Canada) product/group localizations (English US exists for both).
- Inspect Paid Apps Agreement/account status. Any legal acceptance must be done by the account holder.
- Test both product loading and an actual TestFlight sandbox subscription on device after Apple propagates the catalog. Catalog creation alone is not a passing purchase test.
- Review screenshot/submission metadata before App Store submission. User subsequently authorized completing and submitting all possible release items; parent coordinates app archive/upload.
- App Store version page observed: **1.0 Prepare for Submission**, old selected build **1.3 (5)**; TestFlight internal group has **2 (18)** active. Must select the new parent-prepared build before app review.
- Existing App Store description/review notes are stale: say Save gated, omit newer Loop/preferences, reference old profile set. Parent has current product contract; replace with truthful current behavior.
- App Store screenshot section observed empty (0/10 iPhone screenshots, 0/3 previews).

**External blocker:** Mac locked during group-localization entry. CUA reported “The Mac is locked and automatic unlock could not unlock it. Ask the user to unlock the Mac manually before continuing.” No further UI actions attempted. User had confirmed earlier that they were not editing Safari. No App Store Connect connector is available; no private API key directory or existing ASC CLI automation found at standard paths. Group localization form remained open when access ended.

The missing products were a confirmed catalog defect; saved catalog work should propagate without a new binary. Actual phone product fetch and purchase remain unverified.

## Apple sources

[TestFlight purchases are free sandbox purchases](https://developer.apple.com/in-app-purchase/).
[Sandbox overview](https://developer.apple.com/help/app-store-connect/test-in-app-purchases/overview-of-testing-in-sandbox).
[Product metadata changes can take up to one hour to propagate](https://developer.apple.com/documentation/storekit/testing-purchases-made-outside-your-app).

Approved pricing source: `docs/APP-STORE-LAUNCH-CHECKLIST.md`, Subscription products section.

## September 10 morning

Owner restored Safari. Confirmed Paid Apps Agreement, banking and tax statuses Active. English(US) DIRT PRO group display name saved and visibly verified. Added both plan review notes. Plan level reordering attempts did not save; monthly1/yearly2 remain. Actual TestFlight purchase and restore verification is pending owner testing. No review screenshot supplied yet.


## September 10 testing disposition
User confirmed purchase worked. The displayed $39.99 versus purchase $49.99 mismatch is assigned to application testing, including storefront/currency and StoreKit configuration. No pricing change is authorized in this preparation pass.

## September 10 service-level reconciliation — completed
Richard stacked Yearly with Monthly using the dashboard drag control. Saved and verified both plans at level 1 in App Store Connect group 22373005. Prices, duration, availability and introductory offers unchanged. Earlier monthly1/yearly2 notes are superseded. Review screenshots and application purchase/restore/expiry tests remain open; final submission stays on hold.
