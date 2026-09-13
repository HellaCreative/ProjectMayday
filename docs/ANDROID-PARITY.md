# DIRT Android product parity

**Scope:** Android presentation, accounts, Groups, subscriptions, privacy,
licences and platform release obligations. Routing is defined only in
[ROUTING-SOURCE-OF-TRUTH.md](ROUTING-SOURCE-OF-TRUTH.md).

**Documentation consolidated:** 2026-09-13. This consolidation changes no app
code and establishes no new Android implementation or qualification.

Parity means equivalent rider capability, privacy, entitlement, failure honesty
and recovery. Native presentation and platform APIs may differ. An iOS result,
compilation or screenshot does not prove Android implementation.

## 1. Authority and coordination

Read `AGENTS.md`, the routing source of truth, this product parity document,
[the navigation source](00-NAVIGATION-SOURCE-OF-TRUTH.md),
[the privacy inventory](APP-PRIVACY-DATA-MAP.md) and
[the release checklist](APP-STORE-LAUNCH-CHECKLIST.md) as applicable.

This document contains no separate route-selection, fuel, pack-acquisition,
engine, endpoint, time-budget or routing-release policy. Android routing
implementation and its evidence follow the sole routing source of truth.

For navigation cues, HUD, audio, named-stage presentation and session lifecycle,
use [00-NAVIGATION-SOURCE-OF-TRUTH.md](00-NAVIGATION-SOURCE-OF-TRUTH.md).
Routing/data handoff follows the routing source of truth.

When an iOS change affects shared behavior, record the Android equivalent and
its implementation/test status in the owning document. Apple-only changes must
state why no Android counterpart exists. Documented parity is an open delivery
item until the required Android evidence exists.

## 2. Subscription, paywall, and entitlement parity

Android uses Google Play Billing and Android-secure storage; it does not copy
StoreKit or Keychain code. The rider contract must nevertheless match build
`2 (14)`:

- Launch pricing mirrors the iOS market position: US$9.99 monthly / US$39.99
  yearly and CA$12.99 monthly / CA$49.99 yearly, using Google Play's localized
  storefront prices. The seven-day free trial is attached to the yearly plan
  only; the monthly plan has no introductory trial.

- Saving a route locally is free.
- GPX export requires an active DIRT Pro entitlement.
- A rider receives exactly two free navigation starts. A start is consumed
  only when the ride becomes active—not when Start is tapped, preparation is
  cancelled, preparation fails, or the paywall is viewed.
- The free-start counter survives ordinary relaunch and reinstall-resistant
  account restoration to the extent supported by the approved Android account
  model. It must not live only in volatile view state.
- The paywall displays the localized price, billing period, renewal terms, and
  introductory-offer eligibility supplied by Google Play. Never hard-code a
  price or promise an offer to an ineligible rider.
- The paywall presents the same product story and purchase hierarchy as iOS:
  a fixed DIRT PRO title and value proposition; DIRT-first routing, fuel-aware
  planning, ride navigation, live groups, and GPX tools in the only scrollable
  feature region; then an anchored purchase region containing offer summary,
  yearly/monthly choice, purchase, restore, and legal terms. The feature region
  uses compact, readable icon rows and shows approximately three benefits at
  once on a standard phone, with restrained edge fades so content moves
  smoothly behind the fixed regions. The header must not crowd out the product
  story. At accessibility font sizes the entire surface becomes one scroll so
  enlarged content is never obscured.
- The yearly offer is selected by default. The selected offer must be visually
  unambiguous but visually subordinate to the single solid purchase action; a
  restrained brand tint and border are preferred to a second solid-orange
  block. Trial language appears only when Google Play reports that the rider is
  eligible for the yearly trial. Purchase copy must still state honestly that
  DIRT Pro gates unlimited navigation and GPX export; it must not imply that
  free route planning or local saving requires payment.
- Android should use polished Material-native iconography and controls while
  preserving the content order and visual hierarchy. Do not copy SwiftUI or
  Apple-only presentation APIs merely to create pixel parity.
- Use one top dismiss action; do not repeat it as **Maybe later** in the
  purchase region. Never show a tester-bypass action inside the paywall,
  including development builds. When Play products are unavailable, show one
  compact retry state rather than duplicate failure copy.
- Pending, cancelled, failed, already-owned, and successful purchases are
  distinct states. A verified, recognized, active purchase unlocks DIRT PRO in
  local UI state before the purchase is acknowledged; acknowledgement and
  later entitlement refresh are idempotent. Disabling renewal does not revoke
  paid/trial access before Google Play reports expiration, refund, or
  revocation.
- Product loading diagnostics identify the active application ID, requested
  product IDs, whether Google Play returned an empty catalogue or an error, and
  the loaded product IDs. Diagnostics must not include purchase tokens or other
  account secrets.
- The Android development run configuration must attach its local Google Play
  Billing test catalogue before app launch, and an automated paywall check must
  fail if the monthly and yearly products are absent. Production must never
  package or activate that local billing catalogue.
- Expose two plainly named Android run/build choices that mirror iOS: **DIRT
  Dev** selects the development application ID, development Supabase/API
  configuration, visible DEV badge, tester tools, and local Play Billing test
  catalogue; **DIRT Production** selects the production application ID and
  services and excludes every development/test fixture. Do not leave an
  ambiguous generic configuration that can silently target either environment.
- **Restore Purchases** has an Android-native equivalent that queries current
  purchases and reports restored, no-entitlement, and store/network failure
  truthfully.
- Debug and tester bypasses must not exist in a public Release artifact.

The entitlement source of truth must be reconciled across devices. If Android
cannot yet share the iOS entitlement backend, launch material must describe
platform purchases accurately rather than implying cross-platform access.

Equivalent Android tests are required for every case in
`DirtTests/SubscriptionGateTests.swift`, plus Google Play pending-purchase,
acknowledgement, reconnect, refund/revocation, and account-switch cases.
The iOS local catalogue contract is automated-tested, but its command-line
paywall UI run did not receive StoreKit products and is not a passed purchase
test. Android must likewise prove real Play test-billing behavior rather than
inheriting status from catalogue fixtures or the iOS result.

## 3. Account, authentication, and deletion parity

Android must use the same Supabase user/profile model and provide the same
account capability: sign in, visible non-cancellation errors, profile update,
sign out, and deletion initiated inside the app.

The identity-provider UI is platform-native. Do not put Sign in with Apple UI
on Android merely to resemble iOS. The approved Android provider must still
produce the same Supabase identity boundary and must support provider-token
revocation where its contract requires it.

Deletion uses the versioned `delete_own_account` backend RPC from
`supabase/migrations/20260904113053_delete_own_account.sql`. The client must
fail closed: a local sign-out is never presented as successful deletion. After
confirmed deletion, remove local profile, Group, entitlement/session, and
sensitive cached state, then expose any provider-side revocation step that
cannot be completed automatically.

An absent or expired Supabase session event must immediately clear Android's
observable account state and run the same complete Groups shutdown: cancel
sharing and polling jobs, release background location, close private Realtime
channels, and remove rider/alert overlays. Do not ignore an expired event while
keeping stale signed-in state. Android must run equivalents of both rollback-
only database regressions in `supabase/tests`: the cross-account/RLS/private-
Realtime authorization matrix and the account-deletion isolation, session-
cleanup, and forced-failure atomicity matrix.

Android uses the same named development and production lanes defined in
[`ENVIRONMENTS-AND-RELEASES.md`](./ENVIRONMENTS-AND-RELEASES.md). Debug and
internal QA builds must use the isolated development Supabase/API/pack
configuration; the production application ID must fail release verification
if any development endpoint or tester bypass is embedded.

The Android build-time selection must mirror iOS exactly: development resolves
Supabase project `xoufaiypnrgukzmdwicz`, production resolves project
`iiiguqknqxoumlmppzfw`, and no runtime preference may switch between them.
Automated tests must reject either project reference in the opposite build.
Routing execution, data selection and release boundaries are governed solely by
[the routing source of truth](ROUTING-SOURCE-OF-TRUTH.md).
Every development screen that shows the DIRT wordmark must also show the
persistent `DEV` badge; production must not contain or render that badge.
Android release automation must inspect the built APK/AAB, not only Gradle
source, and fail if the opposite Supabase project or development marker is
present.

The shared Supabase contract also requires active-group-only authorization:
deleted groups cannot authorize tables or Realtime, profiles are visible only
to self and active group peers, group owners delete rather than leave their
group, and peers may change only `resolved_at` on a rider alert. Android must
use the same RPCs and must not work around these rules with direct table writes.

Cancellation remains quiet; network, provider, backend, and policy failures are
visible and recoverable. Test real production-provider authentication and
deletion, not only mocks.

## 4. Groups, location, and safety parity

Android shares the Supabase migrations and row-level-security contract. It
must not create its own incompatible Group tables or client-only ownership
rules.

Supabase is a shared service, not a platform-specific backend. Apply each
checked-in migration exactly once to each named Supabase environment. Android
must consume the already-migrated development or production project selected
by its build variant; it must not rerun migrations at app startup, create an
Android-only Supabase project, duplicate tables, or maintain a separate status
schema. Production receives a migration only through the normal hardened
promotion process after development qualification.

- Group creation calls the transactional `create_group` RPC from
  `supabase/migrations/20260904113100_create_group.sql`.
- Distress and rider-state Realtime broadcasts go only to the selected Group's
  private channel. They are never global or sent to every joined Group.
- The selectable rider statuses, in presentation order, are **Riding**, **Flat
  Tire**, **Dead Battery**, **Unrepairable**, **Injured**, and **Stuck**. Their
  wire/database values are `riding`, `flat_tire`, `dead_battery`,
  `unrepairable`, `injured`, and `stuck`.
- `riding` is the ordinary/default state. The five remaining selectable values
  are distress states and create the same selected-group-only alert behaviour.
  Flat Tire, Dead Battery, Unrepairable, and legacy `breakdown` use the
  mechanical/orange treatment; Injured is red and Stuck is purple.
- During mixed-version rollout, decode legacy `available` as Riding and accept
  legacy `breakdown` as mechanical distress. New Android writes must use the
  current values; do not expose Available or generic Breakdown in the picker.
- Normal Group location cadence is 10 seconds; active distress cadence is 5
  seconds. Background behaviour must follow Android foreground-service and
  permission rules without weakening the in-app privacy boundary.
- A stationary rider remains live from the last trustworthy position while
  sharing is enabled. Fresh heartbeats update presence without making a rider
  flicker offline merely because Android has not delivered a new GPS sample.
  Stop Sharing, sign-out, leaving/deletion, stale heartbeat expiry, and an
  explicit sharing-off event still end visibility honestly.
- If Start Sharing has only an expired cached fix, explicitly request a fresh
  Android location while keeping the rider in a visible waiting state. Emit
  privacy-safe diagnostics for permission/accuracy state, fix freshness and
  accuracy, the first committed online presence, and backend write failures;
  do not log coordinates or account identifiers.
- The sharing button and persisted sharing intent must remain synchronized
  across sheet reopen and process relaunch. Starting, stopping, leaving, and
  rejoining must update both local state and peers without requiring an app
  restart. Membership changes refresh the visible roster immediately, with a
  short polling fallback for missed Realtime events.
- Invite codes are case-insensitive and are presented/copied in lowercase.
- Rider identity/status chips sit above and centered on their location marker.
  Refreshing a marker must preserve its map coordinate and must never jump the
  view to the screen origin.
- Precise, approximate, denied, permanently denied, services-disabled, and
  recovery-through-Settings states receive honest, actionable UI.
- Copy must not promise messaging or push notifications until those systems
  actually exist.
- Owner/member/nonmember authorization, reconnect, leave, delete, invite,
  account switching, and stale-cache isolation require multi-account tests.
- Public Groups remain blocked on both platforms until report, block,
  moderation, abuse-response, and support operations are implemented and
  exercised.

Android must implement equivalents of `GroupSafetyPolicyTests` and verify RLS
against a deployed production-shaped backend. Local Kotlin guards are not a
substitute for backend enforcement.

Required Android tests include current/legacy status decoding, every current
status write, distress alert creation and resolution when returning to Riding,
10-second Riding versus 5-second distress cadence, stationary retained-fix
heartbeats, sharing-intent restoration, immediate stop/leave/join roster
updates, lowercase invite entry, and marker-position preservation.

## 5. Product surface, GPX, and design parity

Android must preserve the DIRT product hierarchy and route-first experience,
not replace it with a generic Material sample. Controls, typography, sheets,
motion, accessibility semantics, and system integrations should feel native to
Android while maintaining the same information priority and rider outcomes.

Rider Services use the same environment-selected DIRT backend contract on both
platforms. Campground, lodging, and liquor viewport
requests go through `/api/poi`, which reads checksum-verified regional files
owned by DIRT on R2. Android must never contact public Overpass or another OSM
data server at runtime. It must debounce camera changes, request all three
non-fuel categories together when any is enabled, filter locally to the enabled
switches, retain checksum-valid whole-region sidecars for offline display,
preserve the last successful viewport result during temporary DIRT-service
failure, and emit privacy-safe request/source/failure diagnostics. Rider
Services storage and activation remain separate from graph/geometry/fuel so a
missing optional sidecar cannot block Start Navigation. No account identifier
accompanies visible bounds.

**Evidence status:** the shared `/api/poi` and R2 publication are deployed and
tested, and iOS build `2 (14)` passed physical layer testing on RED. This is an
implementation-ready Android contract only. No Android source, emulator test,
or physical-device result in this repository proves Android implementation.

Profile is a focused full-screen destination, not a partial map overlay. It must
hide the map and map controls, provide an explicit accessible close/back action,
scroll vertically, and cap the content width on larger Android devices. Account,
subscription, ride preferences, destructive account deletion, tester-only tools,
and legal links retain the same ordering and release-channel rules as iOS.

For imported GPX display, saving and later route conversion, use the sole
[routing source of truth](ROUTING-SOURCE-OF-TRUTH.md); this document adds no
separate routing or fuel rules.

CarPlay and Android Auto require separate platform eligibility, template,
distraction and physical-head-unit work. Neither is advertised as implemented.

## 6. Privacy, release, and operational parity

`docs/APP-PRIVACY-DATA-MAP.md` is the current behaviour inventory, not an
Apple-only truth. Android must reconcile every collected, transmitted, stored,
and deleted data category against its actual implementation, then use that
inventory for Google Play Data safety and the public privacy policy.

The iOS package/hygiene audits and launch/support runbooks record implemented
verification and operating baselines, not Android completion. Android needs its
own signed-AAB inspection, dependency notices/provenance, production health
evidence, named launch owners, backup/restore proof, and Play Console/device
qualification. iOS artifact/signing evidence does not clear or replace Android's separate
release-package work.

Before public Android release, record at minimum:

- production application ID, signing/app-integrity setup, version name/code,
  target API, device/form-factor support, and Release-only configuration;
- permissions and purpose strings for precise/approximate/background location,
  notifications if introduced, network, files/document import, and foreground
  navigation/location services;
- Google Play Billing products, test accounts, purchase acknowledgement,
  entitlement restoration, refund/revocation, and offline behaviour;
- privacy policy, Data safety answers, account-deletion URL/flow, content
  rating, store listing, screenshots, support contact, and review instructions;
- production Supabase/Vercel/R2 configuration, RLS verification, migrations,
  monitoring, backups, incident ownership, and rollback plan; and
- signed bundle inspection proving local fixtures, development tiles, test
  billing configuration, credentials, and bypass copy are absent.

The iOS launch minimum is deliberately fixed at iOS 26.0. That platform choice
does not set Android's `minSdk`; Android device reach and minimum API level
remain a separate deliberate Play-release decision.

Android diagnostics must use the same privacy principle as iOS: enough context
to reproduce source, pack, route, fuel, Group, entitlement, and navigation
state without silently adding advertising identifiers or account-linked raw
location telemetry.

## 7. Full-product parity ledger

The Android agent must keep a checked evidence ledger against this table. A row
is complete only when implementation, automated tests, and the required real
service/device proof exist.

| iOS reference | Android-required outcome | Evidence gate |
| --- | --- | --- |
| `ROUTING-SOURCE-OF-TRUTH.md` | Routing and route-data behavior defined only there | Current candidate evidence required there; no inherited routing qualification |
| `00-NAVIGATION-SOURCE-OF-TRUTH.md` | Cue, HUD, audio and navigation-session parity | Automated session tests + physical ride |
| `SubscriptionGateTests.swift` | Free Save, gated export, exactly two consumed ride starts | Unit/UI + Google Play test purchase/restore |
| Account/Profile + deletion RPC | Same lifecycle, expired-session shutdown, and fail-closed deletion | Rollback deletion/session/atomicity matrix + real provider + deployed RPC + data-removal audit |
| Groups safety policies + shared migrations/RPCs | Same selected-group privacy, current rider statuses, retained stationary presence, synchronized sharing state, and authorization | Rollback RLS/private-Realtime matrix + hosted multi-account/background tests + marker stability + physical devices |
| `APP-PRIVACY-DATA-MAP.md` | Implementation-matched Play Data safety disclosure | Release bundle and network/storage audit |
| `ROUTING-SOURCE-OF-TRUTH.md` GPX scope | Equivalent imported-route behavior and explicit implementation status | Shared fixtures + platform UX/device tests |
| Release verifier/checklist | Android signed-bundle and Play Console equivalent | Clean production AAB + closed-track proof |

Whenever the iOS reference changes, update the commit/build identifier above,
reconcile this table, and identify which Android evidence became stale. Do not
mark parity from screenshots or successful compilation alone.

## 8. Preserved presentation and platform launch deltas

The dated entries below retain non-routing changes. Later entries supersede
earlier visual/audio details where they differ. They are not routing policies
or a claim that Android implementation has passed.

### Shared visual consistency — September 9, 2026

The approved planner icon/title tabs remain the visual reference. Selected tabs and light-surface text actions use deep orange (#B85C00; dark appearance #FFB35C), with neutral native glass surfaces. Bright orange filled actions retain dark text. Shared CTA type is sentence case and semibold; headers reserve separate 44-point back/close targets and allow wrapping. Pack actions sit below pack details on neutral cards; Profile subscription management uses the shared glass/secondary-action treatment; Group Create/Join stack at accessibility text sizes. Ride wander now also displays its existing percentage. Port this hierarchy and spacing using native Android equivalents. Routing, fuel replacement, navigation and account operations are unchanged. Native visual acceptance on White remains pending; no simulator was launched for this pass.

### Environment and subscription badge — September 9, 2026

The existing DIRT wordmark size is preserved. Development builds show DEV regardless of sign-in or subscription. Production shows PRO only when the subscription service reports an active subscription, and FREE otherwise. Signing in alone does not grant PRO. The badge is presentation only; entitlement enforcement and tester bypass logic are unchanged. Accessibility names include the edition. Android must expose the same environment/entitlement distinction. The expanded Open Terrain HTML screens are design previews, not a native UI or navigation behavior change.

### Open Terrain native UI — September 9, 2026

The approved cross-platform visual and interaction contract is now
[OPEN-TERRAIN-NATIVE-AND-ANDROID.md](OPEN-TERRAIN-NATIVE-AND-ANDROID.md).
It records the HTML authority, tokens, navigation/sheet motion, per-screen
states, Groups expansion, Saved preview boundaries, map zoom controls and
Android icon/acceptance mappings. Preserve existing routing, fuel replacement,
privacy and navigation semantics while applying it. Android delivery and
physical visual acceptance are still open.

### Open Terrain contrast revision — build 25

Dropdown fields use opaque white with a 1pt/dp light-grey (#D8DADD) border.
Sheets use a more opaque system material (iOS regularMaterial; HTML white tint
92%) to improve map-backed contrast. Preserve overlay dropdown behavior and
all existing actions. Apply the same contrast revision on Android.

### Routing sheet space — build 26

Hide routing scroll indicators while preserving vertical scrolling and leg
swipe actions. The portrait routing sheet can grow until the top of the zoom
stack aligns with the logo top (6pt below safe-area top). Reserve the 360pt
control stack plus 10pt sheet gap; short content continues to hug its contents.
Android should derive equivalent geometry from control sizes and safe insets.

### Dark primary navigation and route progress — build 27

Approved HTML dark navigation is now native: #202820 surface, white idle
icons/titles, orange active background with white content; existing closed-route
orange outline remains. All active build messages use the indeterminate orange
thumper card, including loop-candidate status and previously unrecognized
status text. Known statuses retain their specific explanatory detail. Do not
present the pulse as percentage complete. Reduce Motion keeps a static bar.

### Open Terrain refinement — build 28

Profile uses the enclosing glass sheet without an additional opaque white backing. Zoom +/− buttons retain white fill and black icons, with a 40% black neutral-grey border (#999999). From Here’s initial Surface picker uses the same menu field as Loop (white fill, #D8DADD border, 8pt radius); selecting a surface does not expand the sheet. Route leg disclosure fields share that visual treatment while preserving their existing detail expansion and controls.

### Full-height Layers containment — build 30

While the full-height Layers or Profile sheet is open, suppress the floating map-control stack, rather than trying to place it above the full-height panel. Keep the sheet header/X within the safe viewport and the primary navigation fixed at the bottom. The list scrolls inside the sheet. This avoids control-stack padding increasing the parent layout beyond the screen.

### iOS archive packaging repair

MapLibre6.28.0 device binary is unchanged. The archive action corrects its
incorrect iPhoneSimulator plist label to iPhoneOS only after validating the
actual arm64 IOS Mach-O, then re-signs the framework and enclosing app. Official
matching UUID symbols are included. This has no Android runtime counterpart.
Archive signing may be Development; App Store export must prove Distribution
signing separately. No routing or navigation behavior changes.

### September 10 — licence visibility

Profile must expose Licences & credits offline using bundled full third-party notices, with map data/artwork/audio credits. iOS adds this in ProfileSheet and ThirdPartyNotices.txt; Android must provide an equivalent accessible screen and retain platform-appropriate dependency notices. Apple SF Symbols are iOS system assets, not assets to copy into Android. SVWD03 artwork distribution/source obligations remain unresolved; a notice alone does not close that gate.

### September 10 launch preparation
Production group access hardening and expanded rider status values now match DEV; see LAUNCH-PREPARATION-2026-09-10.md. Android must retain matching status values and group authorization expectations. CarPlay groundwork is separate from Android Auto; neither is advertised as implemented.

### Map font notice — September 10
If Android uses the same demotiles Noto Sans Regular glyphs, include the adjacent SIL OFL 1.1 notice as recorded in MAP-FONT-PROVENANCE-2026-09-10.md. iOS notice now includes it; this does not change the font or routing contract. Android notice delivery remains to verify.

### Apple credential revocation — September 10 working tree
iOS now checks Apple credential state on startup, foreground, sign-in and revocation notification. Confirmed revoked/not-found for the same session clears authentication and disables persisted group sharing. Errors or stale lookup results do not sign out a new session. Android needs equivalent provider-session revocation behavior for its supported identity flow; AuthenticationServices itself is iOS-only. Automatic Apple server token revocation remains separate and unimplemented. Physical Apple revocation remains a release test; policy assertions alone do not prove it.

### Owner-recorded startup audio
Startup audio now uses the owner-recorded MyKTM.m4a (AAC, 48 kHz stereo, 3.305 seconds), replacing firtbike.mp3. Android should use the same owner recording and owner attribution. iOS keeps its accepted animation, mute/mixing behavior and Reduce Motion behavior. No routing changes.

### Planner and map presentation

Layers uses Profile-height glass presentation with a top-right X and the
existing Layers navigation toggle. Active route-tool tabs use the dark
navigation surface, white labels/icons and rounded corners. All surface
controls use orange selected content; native menu surface icons retain their
orange rendering over opaque white controls. Waypoint editing behavior belongs
to the routing source of truth.

Route paint uses one opaque 8-point-equivalent stroke with round joins and caps.
Unknown motorized access paints purple (#54208F) instead of a wider halo behind
a surface stroke. Per-segment white casings and translucent overlaps are absent.
Retain the accepted surface colours, ferry presentation and hit-testing.
Painting never changes routing eligibility or reported surface statistics.

The production logo remains tappable to toggle the viewport surface network.
The technical graph-inspection HUD is development-only. Data execution and
fallback decisions belong to the routing source of truth, not this display
control. Public Release excludes tester links and subscription bypasses.

### Onboarding

Keep the approved logo size, rev/zoom timing, orange/white sparks and skippable
six-page carousel: brand, surface/preferences, Loop, fuel planning, downloaded
maps and Groups. The current recording is the owner-provided MyKTM.m4a, not the
retired synthetic sound or firtbike.mp3. Preserve mute/mixing, Reduce Motion and
cancellation behavior; delayed splash work cannot play or finish after cancel.
Offline copy must match currently verified capability.

## 9. Platform boundaries

Do not copy Apple-only authentication, StoreKit, Keychain, SF Symbols or App
Store APIs into Android. Use native equivalents with the same product and
privacy outcomes. Do not replace the approved DIRT information hierarchy with
a generic sample UI. Routing changes and qualification are governed only by
the routing source of truth.
