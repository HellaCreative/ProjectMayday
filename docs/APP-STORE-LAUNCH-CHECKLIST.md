# DIRT iOS — App Store launch checklist

**Purpose:** one operational source of truth for taking the frozen routing
release candidate through TestFlight and public App Store review.

**Routing baseline:** `routing-rc1-2026-09-03`
(`94b467a11375e3ea3233c127b07af2ef039d0658`). Do not reopen routing to clear a
launch item. See [ROUTING-FREEZE-2026-09-03.md](ROUTING-FREEZE-2026-09-03.md).

**Navigation-preparation candidate:** build `2 (14)` has automated hardening but
still needs the focused White pass in
[NAVIGATION-PREP-REQUALIFICATION-2026-09-04.md](NAVIGATION-PREP-REQUALIFICATION-2026-09-04.md).
The routing/fuel engine remains on the unchanged baseline above.

**Deferred:** CarPlay is parked. Native GPX-to-DIRT conversion and subjective
visual redesign are separate product milestones, not hidden launch work.

**Rider Services candidate:** build `2 (14)`, commit `9808936`, passed the RED
iPhone physical layer test and is frozen in
[RIDER-SERVICES-FREEZE-2026-09-05.md](RIDER-SERVICES-FREEZE-2026-09-05.md).

**Android lockstep:** this checklist is the iOS release record, but every
cross-platform behaviour and backend contract completed here is also tracked in
[ANDROID-PARITY.md](ANDROID-PARITY.md). An iOS launch check does not by itself
prove Android parity.

**Evidence reconciled:** 2026-09-05. Checked items below identify whether the
evidence is implementation, automated testing, or an accepted physical result.
Unsigned builds and simulator tests do not close signing, App Store, real-service,
or physical-device gates.

## Release rule

The public build is ready only when every **Release gate** below is green. A
successful compile alone is not sufficient. Record the build number, Git
commit, TestFlight build, server contract, and test evidence together.

## Release gates

### A. Product and account

- [x] Local route Save works without a subscription (automated gate test).
- [x] GPX Export requires an active DIRT Pro entitlement (automated gate test).
- [x] Start Navigation follows the approved two-free-start/subscription policy
      (automated gate tests; distribution purchase testing remains below).
- [x] Paywall and Profile expose Restore Purchases and distinguish restored,
      no-entitlement, and App Store failure outcomes.
- [ ] Restore Purchases succeeds with a real Sandbox/TestFlight purchase.
- [x] Paywall price, period, renewal language, and introductory-offer language
      come from StoreKit and remain truthful for ineligible customers.
- [x] No tester authentication or subscription bypass exists in a public
      Release executable.
- [x] Sign in with Apple cancellation is harmless and non-cancellation errors
      are visible in Profile and Groups.
- [ ] Sign in with Apple succeeds in a distribution build against production
      Apple/Supabase configuration.
- [x] Account deletion UI and client contract are available in-app and fail
      closed rather than representing a local sign-out as deletion.
- [x] The versioned deletion RPC is deployed; its definition, grants, and live
      foreign-key compatibility are verified.
- [ ] A disposable production test account proves deletion removes Auth and all
      associated app data atomically without touching another account.
- [ ] Sign in with Apple authorization codes are exchanged server-side and the
      resulting Apple token is revoked during deletion, or App Review accepts
      the documented manual-revocation fallback.
- [x] Account deletion explains that an App Store subscription is managed
      separately by Apple.

### B. Navigation safety

- [x] Start is code- and unit-verified to prepare only the first visible route stage and current rider
      region; later stages/regions roll forward during the ride.
- [x] Duplicate Start and Begin Ride transitions are one-shot; cancel/retry and
      fresh-session reroute throttling have automated coverage.
- [ ] Start, cancel, begin ride, end ride, and immediate second ride pass on a
      physical Release device.
- [x] Denied/restricted and Approximate Location have an in-app explanation and
      direct Open Settings recovery action.
- [ ] Precise, approximate, denied, revoked, and background location states pass
      the physical-device permission matrix.
- [ ] Screen lock, background/foreground, phone call, Bluetooth audio, and app
      interruption preserve the ride correctly.
- [x] Cue-mode changes do not replay passed instructions (automated).
- [x] Synthetic loops, self-crossings, parallel roads, stationary off-route
      fixes, natural rejoin, reroute replacement, and long background gaps
      preserve locally believable progress (automated).
- [ ] The same progress cases, plus reversal/departure/rejoin, pass with live
      device GPS scatter.
- [ ] Rider waypoints and fuel waypoints announce and reset the intended state.
- [ ] Offline start, interrupted tile download, low storage, pack refusal, and
      provincial handoff have explicit outcomes.
- [ ] Physical-device acceptance is recorded for at least one small-screen and
      one current iPhone, plus iPad if iPad remains supported.

### C. Groups, privacy, and safety

- [x] Supabase schema, migrations, functions, and row-level-security policy are
      versioned and reproducible from production's complete baseline in the
      isolated development project.
- [x] Development's hardening candidate passes a rollback-only
      three-user/two-group authorization matrix across RLS-protected tables and
      actual private Realtime messages, including loss of access after Group
      deletion, with no retained test data.
- [x] Development's deletion matrix proves member/owner cascades, Auth-session
      removal, anonymous denial, cross-account isolation, and atomic rollback on
      a forced foreign-key failure, with no retained test data.
- [ ] Real multi-account development tests prove that private group membership,
      live location, invite codes, alerts, profiles, and Realtime traffic cannot
      leak across groups.
- [x] Group creation uses a versioned transactional RPC in the app and migration.
- [x] The transactional Group creation RPC is deployed and metadata-verified
      against the production schema.
- [x] Live-location cadence distinguishes distress from ordinary sharing and
      remains reasonable for battery and network use.
- [x] Distress Realtime broadcasts use only the same selected group as the
      persisted alert (automated policy test).
- [ ] Multi-account staging proves distress and route alerts reach exactly the
      intended audience under live RLS and private Realtime authorization.
- [x] Sharing/session shutdown is implemented and unit-tested for explicit stop,
      sign-out, confirmed deletion, and absent/expired Supabase sessions; stale
      account, Realtime, polling, background-location, and overlay state is
      cleared together.
- [ ] Real client/device observation confirms those sharing/session shutdown
      paths against hosted Auth and private Realtime.
- [ ] User-generated names/content have an abuse report, block, moderation, and
      support-response path appropriate to the shipped functionality.
- [x] Code-backed data flows, including routing/POI/tile geography and local
      last-location storage, are inventoried for disclosure.
- [ ] Public privacy policy and App Privacy answers are reconciled with the
      bundled privacy manifest and the final archive privacy report.

### C2. Map Rider Services

- [x] Fuel, Campgrounds, Lodging, and Liquor pass the focused DIRT Dev physical
      test on RED at build `2 (14)`, commit `9808936`.
- [x] Fuel is complete for all 63 advertised regions and remains the canonical
      routing sidecar; the accepted road and geometry bytes were not rebuilt.
- [x] Campground, lodging, and liquor are complete for all 63 advertised
      regions in a separate verified catalog that cannot block routing.
- [x] Development and production `/api/poi` read DIRT-owned R2 data; neither the
      mobile app nor either deployed endpoint contacts Overpass at runtime.
- [x] Live catalog/object verification, Porters Lake fixtures, failure handling,
      request coalescing, offline caching, and Android handoff are recorded in
      the Rider Services freeze document.

### D. Production package

- [x] Routing release candidate is tagged and documented.
- [x] Development-only `BC.mbtiles` is excluded from Release.
- [x] Local `Dirt.storekit` configuration is excluded from Release.
- [x] App privacy manifest declares precise/coarse location and the code-backed
      required-reason API usage (`CA92.1`, `C617.1`).
- [x] The clean unsigned Release bundle passed app-owned identity, resource,
      privacy, minimum-OS, size, and development-content hygiene checks (31 MiB
      apparent size versus 222 MB before development-resource removal), as
      recorded in
      [IOS-RELEASE-HYGIENE-AUDIT-2026-09-05.md](IOS-RELEASE-HYGIENE-AUDIT-2026-09-05.md).
- [x] Minimum supported iOS version is deliberately fixed at iOS 26.0. The
      Release verifier rejects any archive whose `MinimumOSVersion` differs.
- [x] `ThirdPartyNotices.txt` is bundled and the Release verifier rejects a
      missing or empty notice; dependency and asset evidence is recorded in
      [OPEN-SOURCE-NOTICE-AUDIT-2026-09-05.md](OPEN-SOURCE-NOTICE-AUDIT-2026-09-05.md).
- [ ] Establish ownership/license provenance for the bundled SVWD03 map style
      and sprites, and decide whether notices also need an in-app/legal-site view.
- [ ] iPhone-only versus universal iPhone/iPad support is deliberately selected.
- [x] Final unsigned Release build and Xcode Release static analysis pass.
- [ ] Replace the current MapLibre device artifact with an official corrected or
      reproducibly reviewed build whose platform metadata is iPhoneOS and whose
      executable has a matched dSYM; rerun map regression/device qualification.
      See
      [IOS-RELEASE-PACKAGE-AUDIT-2026-09-05.md](IOS-RELEASE-PACKAGE-AUDIT-2026-09-05.md).
- [ ] Signed archive, App Store validation, and export pass.
- [ ] App size and every bundled resource are reviewed after archive thinning.
- [ ] Export-compliance answers match the final HTTPS/cryptography usage.
- [ ] Third-party SDK privacy manifests/signatures pass Xcode validation.

### E. Operations

- [x] Read-only production health verification, dependency identity checks,
      launch-watch defaults, incident handling, and immutable rollback rules are
      documented in [LAUNCH-OPERATIONS-RUNBOOK.md](LAUNCH-OPERATIONS-RUNBOOK.md).
- [ ] Run and retain strict/deep production preflight evidence for the exact
      candidate, and assign named release, incident, backend, pack/data, and
      support owners with backups.
- [ ] Production Supabase quota/backup facts, alert ownership, and an isolated
      restore drill are recorded and tested.
- [x] A privacy-conscious support triage baseline covers billing, deletion,
      unsafe/private routing, fuel/Rider Services data, Groups privacy, Auth, and
      basemap reports in [SUPPORT-TRIAGE-RUNBOOK.md](SUPPORT-TRIAGE-RUNBOOK.md).
- [ ] Decide whether the inaccessible in-memory Release diagnostic buffer stays,
      and whether public builds need a consent/redaction-aware export path; no
      automatic diagnostic upload exists today.
- [ ] Internal TestFlight, external TestFlight, release-candidate soak, phased
      release, and rollback thresholds are accepted by the named launch owners.

## App Store Connect — Richard

These items require the account holder, legal representative, or a deliberate
product decision and cannot be completed safely by an engineering agent.

### Business and compliance

- [ ] Confirm the App Store Connect record for bundle ID `com.mayday.dirt` and
      SKU `MAYDAY-DIRT-IOS-001`.
- [ ] Accept the Paid Apps Agreement.
- [ ] Complete banking and tax information.
- [ ] Declare EU Digital Services Act trader status and provide any required
      public contact information.
- [ ] Complete export-compliance questions.
- [ ] Confirm the privacy-policy URL and App Privacy questionnaire.

### Subscription products

- Launch pricing decision: US$9.99 monthly / US$39.99 yearly; CA$12.99
  monthly / CA$49.99 yearly. The seven-day free trial applies to the yearly
  product only. App Store Connect remains the production source of truth.
- [ ] Confirm product IDs `com.mayday.dirt.pro.monthly` and
      `com.mayday.dirt.pro.yearly`.
- [ ] Confirm price, duration, territories, subscription group, localization,
      display names, descriptions, and review screenshots.
- [x] The checked-in local StoreKit catalogue contains the two approved product
      IDs and yearly-only seven-day trial, its catalogue contract tests pass,
      and `DIRT Production` excludes it.
- [ ] The paywall visibly resolves both products in Sandbox/TestFlight. The
      current local command-line UI run did not receive StoreKit products and is
      not recorded as a passing paywall test.
- [ ] Configure the seven-day introductory trial on the yearly product only
      in each launch territory; the monthly product has no introductory offer.
- [ ] Submit the first subscription products with the app version.

### Product-page material

- [ ] Final app name, subtitle, primary/secondary category, age rating, content
      rights, description, keywords, promotional text, copyright, support URL,
      and marketing URL.
- [ ] One to ten truthful screenshots for every retained device class.
- [ ] Optional preview video.
- [ ] App Review contact details, working reviewer account, and instructions for
      Sign in with Apple, Groups, subscriptions, offline packs, and navigation.
- [ ] Release method: manual, automatic, or phased.

## Required TestFlight matrix

Run on the exact Release candidate, not a tester-bypass build.

| Area | Minimum evidence |
| --- | --- |
| Clean install | onboarding, permissions, signed-out planning, local save |
| Subscription | eligible/ineligible, monthly/yearly, buy, cancel, pending, restore, expire, revoke, offline |
| Account | Apple sign-in, cancel, bad network, profile update, sign-out, delete |
| Groups | owner/member/nonmember, join/leave/delete, reconnect, background, privacy boundaries, alerts |
| Navigation | online/offline, first-stage prep, cues, fuel stops, reroute/rejoin, loop, interruption, end/restart |
| GPX | malformed file, large track, open track, closed loop, export entitlement |
| Resilience | airplane mode, constrained network, server 4xx/5xx, low storage, interrupted downloads |
| Accessibility | VoiceOver, Dynamic Type, contrast, Reduce Motion, 44-point controls |
| Devices | smallest supported iPhone, current iPhone, orientation matrix, iPad if retained |

## Automated release verification

### Build 2 (14) engineering record

- iOS unit/integration target: **268 passed, 0 failed, 0 skipped** on iPhone 17 /
  iOS 26.5 Simulator in two serial runs (131.81 seconds fresh wall time; 36.40
  seconds rerun wall time).
- Non-paywall UI coverage: **9 logical tests passed across 12 executions, 0
  failed, 0 skipped** in a 295.54-second serial wall-time run. The launch test
  accounts for four device/orientation executions. Simulator state stabilization
  is recorded at commit `95f1e83`.
- The local StoreKit paywall UI test is **not passed**: the deterministic runner
  reached the paywall but the local command-line run supplied no products. Real
  Sandbox/TestFlight purchase, restore, expiry, and revocation remain open.
- Shared routing/pack tests: **249 passed, 0 failed, 4 intentionally skipped**.
- Unsigned Release build: passed for `generic/platform=iOS`.
- Xcode Release static analysis: passed.
- Release bundle hygiene: app-owned checks passed at 31 MiB apparent size;
  privacy manifest and third-party notice are present, while development map
  tiles, local StoreKit configuration, and tester-bypass copy are absent. The
  full package is not upload-ready because MapLibre metadata/dSYM and distribution
  signing remain unresolved.
- The no-debugger test runner repair is recorded at commit `f3e9950`; the
  session-shutdown and database security/deletion evidence is at `d8f345c`.

This record is automated evidence, not a substitute for the unchecked signed,
production-backend, StoreKit, or physical-device gates above.

### Development environment delta — commit `ac383bd`

- Debug and Release generic-device builds passed after compile-time Supabase
  isolation; binary inspection found only the development project in Debug and
  only the production project in Release.
- The focused iPhone 17 / iOS 26.5 simulator run passed the navigation
  reliability, subscription gate, group safety, and core integration suites.
- Development Supabase replay plus the rollback-only authorization/private-
  Realtime and deletion/session/atomicity matrices passed with zero residue.
  RLS init-plan warnings are cleared; five intentional authenticated
  transaction-RPC notices remain documented.
- None of the three development-only migrations (rider-status expansion plus
  two authorization hardening migrations) has been promoted to production.

### Reproduce the bundle audit

Build the public configuration, then audit the produced bundle:

```bash
xcodebuild -project Dirt.xcodeproj -scheme 'DIRT Production' \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build

scripts/verify-ios-release.sh \
  /path/to/DerivedData/Build/Products/Release-iphoneos/Dirt.app
```

The verifier intentionally fails if development map tiles, the local StoreKit
configuration, tester-bypass copy, privacy manifest, third-party notice,
framework platform metadata, or signing requirements are wrong. The current
unsigned bundle is expected to remain red on the documented MapLibre artifact
blocker until that dependency is corrected.

## Official Apple references

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Offering account deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/)
- [Auto-renewable subscriptions](https://developer.apple.com/help/app-store-connect/manage-subscriptions/offer-auto-renewable-subscriptions/)
- [Introductory offers](https://developer.apple.com/help/app-store-connect/manage-subscriptions/set-up-introductory-offers-for-auto-renewable-subscriptions)
- [App Privacy details](https://developer.apple.com/app-store/app-privacy-details/)
- [Privacy manifests](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [Required App Store properties](https://developer.apple.com/help/app-store-connect/reference/app-information/required-localizable-and-editable-properties)
- [Screenshots](https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots)
- [Submit an app](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app)
