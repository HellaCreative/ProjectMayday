# App Store submission copy — September 9, 2026

Prepared from current Swift behavior and the owner-approved September 9 feature/design pass. **Not yet entered in App Store Connect:** Mac locked. Parent coordinates the final archive and upload. This copy deliberately avoids an unverified blanket national routing-qualification claim.

## Target identity and build

- Existing App Store name: Dirt by Mayday. Preserve; no unrequested rename.
- Bundle: `com.mayday.dirt`; app ID: `6794633890`.
- Target version: **2**, planned build **19** (parent must confirm successful upload/processing).
- Observed stale distribution record: version **1.0**, selected build **1.3 (5)**. Update version/select final build before submission.
- TestFlight build **2 (18)** was observed active before fixes.
- Preserve existing copyright/contact information; no invented contact or business identity.

## Promotional text (134 characters)

Build your next dual-sport ride with dirt and pavement preferences, fuel stops, round-trip loops, saved routes, and live rider groups.

## Description (2461 characters)

DIRT is route planning and navigation for dual-sport motorcycle riders. Find a ride that suits your day, from a pavement connection to a longer adventure through gravel and dirt.

PLAN YOUR KIND OF RIDE
Start from your current location, build a route with your own waypoints, or create a loop that returns to where you started. For loops, choose a direction, distance, and surface preference. Review the resulting legs and tune the ride before you set off.

CHOOSE THE ROAD
Pick Dirt, Balanced, or Clean. Adjust ride wander and your city and highway preferences. See the route’s mapped surface mix and inspect individual legs. Tap the DIRT logo to explore the surface network on the map.

PLAN FOR FUEL
Set your fuel range and reserve. Automatic fuel planning adds mapped fuel stops to your route. Select a planned stop to see nearby alternatives and replace it with a different station.

KEEP YOUR PLANS
Save routes on your iPhone, view them on the map, and continue planning later. Import GPX tracks and export GPX with DIRT PRO.

RIDE WITH GUIDANCE
Follow the route with navigation cues and surface information. Large map controls include zoom buttons for easier use. Prepare maps and regional routing packs before heading away from cell coverage.

RIDE TOGETHER
Create or join a private group. Choose when to share your location and riding status. View a rider on the map or plan a route to them. Stop sharing when you want.

MAPS AND RIDER SERVICES
Switch between Standard and Rich map styles, explore available regional downloads, and show rider services such as fuel, campgrounds, and lodging.

FREE PLANNING, OPTIONAL DIRT PRO
Plan routes and save them locally for free. Two free navigation starts are included on your device. DIRT PRO unlocks unlimited navigation and GPX export with monthly or yearly subscriptions. Current prices and any eligible introductory offer are shown in the app by the App Store.

Subscriptions renew automatically unless cancelled through your Apple subscription settings. Manage or cancel your subscription there, or restore purchases in DIRT.

DIRT uses mapped road, surface, access, and fuel information. Conditions and availability can change. Allow Unknown includes roads whose motor access is not confirmed; it does not grant permission to ride. Review your route and follow local access rules and signs.

Privacy: https://dirtmoto.app/privacy/
Terms: https://dirtmoto.app/terms/
Support: https://dirtmoto.app/support/

## Keywords

motorcycle,dual sport,adventure,gravel,dirt,GPX,navigation,trail,offline,route

## App Review notes

DIRT is a native dual-sport motorcycle route planner and navigation app.

CORE REVIEW FLOW
1. Allow Location When In Use to use From here and Loop. Manual route planning can also use chosen map waypoints.
2. Open Route. From here uses your current location and a long-pressed destination. Plan supports multiple waypoints. Loop takes a direction, target distance, and surface preference and returns to the current starting location.
3. Profiles are Dirt, Balanced, and Clean. Rider settings above the route sheet include wander, city/highway preferences, and access choices. Allow Unknown does not certify public access.
4. Inspect route legs and surface information. Navigation preparation obtains the needed near-term map/routing data. Regional map packs can also be managed in Layers.
5. Save is free. Export GPX requires DIRT PRO. Navigation includes two free starts on the device, then requires DIRT PRO. A start is counted when a ride begins, not when preparation is cancelled. The counter uses Keychain and may survive reinstall.

SUBSCRIPTIONS
Products: com.mayday.dirt.pro.monthly and com.mayday.dirt.pro.yearly, in group DIRT PRO. Monthly and yearly unlock the same navigation/export entitlement. Prices and offer eligibility come from StoreKit. The yearly plan has a seven-day introductory free trial for eligible new subscribers; the monthly plan has no introductory offer. Purchase and Restore Purchases are on the paywall and in Profile. No tester subscription bypass is present in the Release app. TestFlight purchases use Apple’s sandbox and do not charge testers.

ACCOUNTS AND LOCATION
Sign in with Apple is used for Groups and account features; core route planning does not require a DIRT account. Profile includes account deletion. Deleting a DIRT account does not cancel an Apple subscription.

Private Groups support deliberately enabled live location/status sharing, viewing riders on the map, and routing to a rider. Sharing can be stopped. Background location supports active navigation and deliberate group sharing.

Map data and Allow Unknown do not grant legal riding permission. No CarPlay or Apple Watch functionality is claimed.

Privacy: https://dirtmoto.app/privacy/
Terms: https://dirtmoto.app/terms/
Support: https://dirtmoto.app/support/

## Submission actions and unresolved fields

1. Save promotional text, description, and review notes above. Do not copy this preparation/checklist prose into customer fields.
2. Set version 2 and select the actual final processed build. Do not leave old build 1.3 (5) selected.
3. Finish DIRT PRO group localization and align both products to the same service level. Both product names/descriptions, prices, CA/US availability, and yearly trial are already saved; see `TESTFLIGHT-SUBSCRIPTION-CATALOG-2026-09-09.md`.
4. Add actual final Release screenshots and subscription review screenshot. The observed iPhone screenshot section had zero screenshots. User screenshots in the conversation often have DEV badges/old layouts; do not present them as final Release. Do not fabricate navigation/screenshots. Downloads folder enumeration was denied during this pass, so no screenshot artifact has been selected or uploaded.
5. Submit initial subscriptions together with the matching app version when Apple requirements are satisfied. User has authorized submission; no submission has been performed yet.
6. Inspect the Paid Apps Agreement and tax/bank state. Do not accept agreements or invent business declarations. Any required signature/attestation is an account-holder step.
7. Inspect age rating, export compliance, and device-support fields. Answer only from verified app facts or existing owner decisions; preserve prior decisions where applicable.
8. Reconcile App Privacy with code-backed `APP-PRIVACY-DATA-MAP.md`, final bundled privacy manifest, and current website policy. Known inventory: account name/email/user ID; account-linked precise/coarse location and other user content for Groups/reports; no advertising/cross-company tracking purpose. Routing/fuel endpoints receive coordinates; tiles/POI services receive geographic requests. StoreKit entitlement is checked on device. These are engineering facts, not a substitute for missing retention/legal declarations.
9. Do not claim physical subscription purchase/restore success until a TestFlight transaction has actually been exercised. Catalog metadata can take time to propagate.

## Copy corrections compared with the existing App Store draft

- Three current profiles, not four; removed Direct.
- Save remains free; GPX export is subscriber-gated. Two starts apply to navigation.
- Added Loop, rider preferences, fuel replacement, and updated Groups behavior.
- Removed inaccurate blanket trial eligibility and national coverage guarantees.
- No DEV/tester controls or guaranteed fuel/access claims.

## Public link and privacy reconciliation — verified 2026-09-10 01:10 UTC

All three public links return **HTTP 200 with a normal browser user-agent**: privacy, terms, and support. A default Python client received HTTP 403, and the web tool could not open them, so automated link probes alone can misreport availability. TLS verification remained enabled. Pages identify DIRT/Hella Creative and carry August 6, 2026 update dates. Contact details are present; actual mailbox delivery/support staffing was not tested.

Concrete corrections before public submission:

- **Terms freemium text is wrong:** it includes Save among paywalled actions. Current `TrialGateModel.requestSave()` always succeeds. Replace that paragraph with: “Route planning and local saving are free. Two navigation starts are included on your device. DIRT PRO unlocks further navigation and GPX export. The free-start count is retained in Keychain and may survive reinstall.” Keep existing legal terms unchanged otherwise.
- **Support account-deletion instructions are stale:** they describe email-only deletion and characterize in-app deletion as a future possibility. Current Profile exposes account deletion. Replace the operational instructions with: “Open Profile to delete your DIRT account. If you cannot access the app, contact info@dirtmoto.app for help. Deleting your DIRT account does not cancel your Apple subscription; manage that separately in Apple subscription settings.” Do not promise a deletion timeline or retention policy not verified with the owner.
- **Privacy disclosure is incomplete for current data flows:** it mentions precise location/account data generally but does not explicitly describe Approximate Location, group membership/invites/status and alerts, opted-in road contributions/incidents, or geographic routing/POI/tile requests. Add these engineering facts from `APP-PRIVACY-DATA-MAP.md`; do not invent new retention periods or provider-location guarantees.
- **Privacy deletion text** should reference the shipped in-app flow as well as support, and distinguish account deletion from Apple subscription cancellation.
- **Provider wording** on privacy is broad; the engineering map identifies Supabase, Vercel routing/fuel services, and DIRT-hosted R2 map/service files. Confirm the final production configuration before replacing broad statements with a precise processor list.

Manifest cross-check: `Dirt/PrivacyInfo.xcprivacy` matches the engineering inventory’s six categories exactly (Name, Email Address, User ID, Precise Location, Coarse Location, Other User Content), all linked, not tracking, app functionality. Tracking is false and tracking domains are empty. UserDefaults reason CA92.1 and file timestamps C617.1 are declared. No concrete category contradiction between these two local sources was found. This does not verify the separate App Store Connect privacy questionnaire, third-party SDK manifests, website retention promises, or the final archive report.

No public website changes or privacy/legal attestations were made in this read-only pass.
