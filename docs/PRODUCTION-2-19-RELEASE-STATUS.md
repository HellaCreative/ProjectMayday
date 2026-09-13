# Production 2 (19) — release status

Historical release receipts, September 9–10, 2026. These entries record actions and do not authorize a new build, upload, or submission. Final submission was subsequently deferred; see the latest launch-preparation record. No simulator was started.

## App artifact

Archive: `.build/archives/DIRT-Production-2-19-Final.xcarchive`.
Bundle `com.mayday.dirt`, version2, build19; DEV source build34.
Source release-target commit582fcb1, app fixes51353d2/6b42d63/72e87d6.
The working tree also contains pre-existing development changes; it was not reset or represented as a clean release checkout.

Archive completed. `verify-ios-archive.sh` passed bundle resources/privacy manifest, signatures, app and MapLibre dSYM matching. Executable contains release02 and not release01. MapLibre device-platform metadata finalizer passed. Distribution export/upload has NOT completed.

## Tests

Physical white iPhone: prior planner/V4 suites32 passed, subscription gates5 passed, national budget/watchdog5 passed, latest planner suite22 passed including same-endpoint profile geometry replacement. Some planner tests overlap the earlier run; these are suite results, not a unique-test total. No visual acceptance is inferred from model tests.

Logs: `/tmp/dirt-production19-archive.log`, `/tmp/dirt-production19-verify.log`, `/tmp/dirt-production19-export.log`.
Latest planner result: `.build/release-validation/Logs/Test/Test-DIRT Dev-2026.09.09_22-28-43--0300.xcresult`.

## Routing qualification

See [ROUTING-SOURCE-OF-TRUTH.md](ROUTING-SOURCE-OF-TRUTH.md). Archive upload is not routing acceptance. Historical publication receipts remain at `scripts/pack-fabric/routing/candidates/fabric-v4-20260909-02/publication/handoff.json`.

## Current external blockers

Export failed with Xcode `No Accounts` and `No signing certificate "iOS Distribution" found`. Read-only identity check finds only Apple Development signing. Mac locked; App Store Connect UI inaccessible. User has been asked to unlock. No password bypass, certificate revocation or account removal attempted.

App Store group localization, same subscription service level, current build selection, screenshots and review metadata still require App Store Connect access. Catalog products are saved; purchase/restore in TestFlight has not yet been verified. See `TESTFLIGHT-SUBSCRIPTION-CATALOG-2026-09-09.md` and prepared `APP-STORE-SUBMISSION-COPY-2026-09-09.md`.

Website factual corrections prepared but not published (SiteGround publishing access not configured); see `WEBSITE-FACTUAL-REPAIR-2026-09-09.md`.

## September 10 morning — App Store Connect access restored

Safari access restored by owner. Confirmed Paid Apps Agreement, banking, tax forms and listed compliance statuses Active. DIRT PRO English (US) group localization now saved. Both existing product IDs/names/durations/availability still present; added monthly/yearly review notes. Same-service-level drag edit could not be completed through Safari controls; remains monthly1/yearly2. No price change, real purchase or entitlement test performed.

Saved App Store version2, current promotional text, description and review notes in English(Canada); added subtitle “Dual-sport route planning” and Navigation category. Privacy policy URL saved. All six code-backed privacy categories configured: Name, Email, Precise/Coarse Location, Other User Content, User ID; each app functionality, linked, not tracking. Final Publish legal-attestation confirmation requested from owner; label is saved as draft until approved. Age-rating questionnaire completed with UGC/group communication and infrequent alcohol references (optional liquor POIs), resulting calculated13+; save visibly confirmed (13+ in172 regions, regional variations). No content-rights attestation or final app review submission performed.

Owner testing Production on Red; do not operate or install onto Red. Await actual TestFlight product fetch/purchase/unlock/restore result. Final app/subscription review screenshots remain missing, old build selection needs replacement after final upload. No upload performed this morning.

### Morning purchase report and distribution retry

Owner reports subscription purchase worked. Paywall showed $39.99 and purchase sheet $49.99; these match configured US39.99/CA49.99 yearly prices, but the mismatch is not conclusively diagnosed. PaywallView reads StoreKit Product.displayPrice, not a hardcoded price. Owner explicitly requested no pricing change. Restore/navigation acceptance not inferred from purchase success.

Morning command-line export again failed No Accounts / missing distribution certificate. Xcode GUI account is present for Hella Creative Solutions; Organizer successfully progressed through creation of the IPA and into upload/Apple analysis for production2(19). Await final upload result before claiming completion.

**Upload confirmed September10 morning:** Xcode Organizer now explicitly displays “App upload complete” and “Dirt 2 (19) uploaded”. Used App Store Connect distribution (testing and release), not TestFlight Internal Only. Upload succeeded via GUI despite command-line credential failure. Apple processing/build selection and review submission remain separate pending steps; do not report submitted for review yet.

### Launch preparation after user reported regional-crossing failures

App Store Connect shows build2(19) Testing in the NSDS External group. Replaced obsolete version1.3 build5 association in the version2 launch draft with build19 and saved. Changed version release to Manual, visibly verified; no review submission or public launch initiated. User wants regional-crossing fixes/testing before launch.

App download pricing had been unset: configured USD0.00 with equivalent free prices, confirmed and saved. Subscription prices unchanged. App availability had been unset: saved Canada and United States only, both visibly Available on App Release; other countries Not Available and automatic future-country inclusion off. Public distribution remains selected.

Remaining: current production App Store screenshots and subscription review screenshots; subscription same-service-level alignment; privacy label publish awaits owner confirmation; content-rights declaration asks owner to confirm necessary rights to third-party content (maps and supplied motorcycle audio), left unanswered. Metadata/review notes, age rating13+, privacy URL and data-category draft already prepared. Website factual corrections remain unpublished. Do not claim all launch preparation complete or regional-crossing failures resolved.


## September 10 preparation update
See LAUNCH-PREPARATION-2026-09-10.md for live privacy, website, device availability, DNS and group-security updates. These service/dashboard changes do not constitute a new app archive. User has explicitly deferred final submission.
