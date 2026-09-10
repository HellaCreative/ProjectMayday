# DIRT Android parity contract

**Status:** active full-product Android parity authority

**Reconciled:** 2026-09-05

**Frozen iOS/shared-routing implementation:**
`94b467a11375e3ea3233c127b07af2ef039d0658`
(`routing-rc1-2026-09-03`)

**Accepted frozen-routing iOS build:** `2 (13)` on White

**Current iOS engineering reference:** build `2 (14)`; Rider Services acceptance
at `9808936`, account/session behaviour through `d8f345c`, and simulator-test
infrastructure through `95f1e83`.

**Latest lockstep deltas:** September 4 Groups presence hardening and rider
status vocabulary, followed by the September 5 Rider Services packed-data
contract frozen in `docs/RIDER-SERVICES-FREEZE-2026-09-05.md`, then fail-closed
expired-session shutdown plus rollback-only database authorization/private-
Realtime and deletion/atomicity matrices. These are implemented and
automated-tested on iOS/shared development infrastructure; Rider Services
additionally passed iOS physical testing. Android implementation, automation,
and physical-device evidence remain open for every applicable delta.

The New Hampshire V3 object recorded at `d9445ed` remains a Cursor-owned pack
candidate. This evidence reconciliation does not accept, promote, rebuild, or
otherwise change that candidate or the frozen routing baseline.

Build `2 (14)` still requires the focused physical-device navigation pass in
`docs/NAVIGATION-PREP-REQUALIFICATION-2026-09-04.md`. Android must port its
contract, but must not treat uncompleted iOS physical qualification as proof.

**LIVE endpoint:** `https://dirt-mayday.vercel.app/api/route`

**Required service contract:** `dirt-routing.r0.v1`

This document replaces both dated Android catch-up documents. It defines the
complete behaviour Android must match; it is not an instruction to copy Swift
syntax, Apple-only APIs, or fork the shared online router into Kotlin.

Parity means the rider receives the same capability, safety rule, entitlement,
privacy boundary, failure honesty, and recovery path on both platforms. Native
presentation and store/authentication APIs may differ. A feature is not
finished cross-platform until the Android implementation and its equivalent
tests are recorded here.

## 1. Authority and implementation boundary

Read in this order:

1. `AGENTS.md`
2. `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`
3. `docs/ROUTING-FREEZE-2026-09-03.md`
4. this document
5. `docs/00-NAVIGATION-SOURCE-OF-TRUTH.md`
6. `docs/APP-STORE-LAUNCH-CHECKLIST.md`
7. `docs/APP-PRIVACY-DATA-MAP.md`
8. `docs/GPX-IMPORT-TO-DIRT-PLAN.md`
9. current Swift, shared JavaScript, fixtures, and tests

Android uses the shared LIVE route service whenever it is online. Server
search, regional seams, fuel-chain selection, and current production pack bytes
are therefore already shared. Do not create a second online routing algorithm
in Android. Kotlin must implement the same contracts for client state,
presentation, edits, diagnostics, and offline routing/rerouting.

`serviceBuild` is diagnostic and changes with legitimate server or pack-release
commits. Record it on every response; do not hard-code it. A
`serviceContract` mismatch is fatal.

Every iOS change affecting rider-visible behaviour, stored state, backend
contracts, entitlements, privacy, diagnostics, or acceptance tests must do one
of two things in the same commit:

1. update this contract and identify the Android equivalent; or
2. explicitly record that the change is Apple-only and why no behavioural
   Android counterpart exists.

“Android later” is not a parity decision. It is an open delivery item.

## 2. Routing profiles and access

- Dirt maximizes meaningful known unpaved riding within the frozen
  forward-progress, total-journey, backtrack, and urban-core protections. It is
  not shortest route and must not collapse to Balanced merely because the
  endpoints connect.
- Balanced targets the closest feasible ride to 50% known dirt / 50% paved. A
  miss is labelled honestly.
- Clean stays on pavement except for necessary endpoint/connectivity access. It
  never hunts dirt and always forces Allow Unknown off.
- Unknown surface and unknown access are independent. Unknown surface is not
  counted as dirt. Allow Unknown permits only motorized access whose legality is
  unproven; it is acknowledgement, not permission.
- A discretionary dirt diversion must earn at least 1 km of continuous,
  explicitly known unpaved riding. Necessary connectors and endpoint access
  remain routable.
- Major urban cores are a strong wall and relax only as a clearly labelled
  last resort. Smaller settlements are a cost, not an absolute wall.
- Immediate predecessor-edge U-turns, arbitrary backward travel, down-and-back
  tourism, free-space joins, and synthetic connectors are forbidden.
- Ferry distance/time is real. Ferry distance is excluded from dirt/paved/
  unknown surface percentages and is presented as a ferry crossing.

Port the profile tables and decision helpers from
`Dirt/Routing/OnDevice/OnDeviceProfileCosts.swift` and their shared twin in
`scripts/pack-fabric/routing/lib/profile-costs.js` as named data. Do not
re-enter approximate values from an old parity memo. Offline search must match
the behavioural invariants and typed failures in
`Dirt/Routing/OnDevice/OnDeviceRouter.swift` and the current JS tests.

## 3. Canonical itinerary and visible stages

`RiderItinerary` is the durable routing intent. Generated fuel anchors and
route geometry are derived output.

For `Point 1 → F1 → F2 → Point 2`, Android shows exactly three peer stages:

1. Point 1 → F1
2. F1 → F2
3. F2 → Point 2

There is no hidden Point 1 → Point 2 parent row. Rider points remain numbered;
automatic fuel points remain F1, F2, and so on.

Each visible stage owns its departure-keyed profile and Allow Unknown policy.
Editing one stage follows this exact rule:

- preserve every completed stage before the selected departure;
- apply the new profile/access policy only to the selected stage;
- rebuild the selected stage and its fuel-dependent suffix only to the owning
  primary rider waypoint, because changed distance may move the next pump;
- apply each later stage's stored policy or the primary rider-leg default—the
  selected policy never leaks forward;
- preserve every earlier and later primary rider leg exactly; and
- meet or improve the former safe fuel-arrival ceiling at the owning rider
  waypoint before reusing the untouched suffix.

Waypoint topology or global fuel-range/reserve changes may revalidate forward
from the earliest affected rider leg. A generated pump replacement rebuilds
from the preceding anchor while preserving valid upstream geometry and pump
identity. Stale automatic pumps are never retained only because their
coordinates happen to match.

These rules are implemented by the current iOS itinerary reducer/builder/model
under `Dirt/Features/RoutePlanning/Itinerary/` and are covered by the current
itinerary tests. Android must add equivalent reducer-level tests before parity
is claimed.

## 4. Fuel planning

- Automatic fuel planning defaults on; manual/off adds no pumps and makes no
  fuel-sufficiency claim.
- Point 1 starts with a full tank. Usable range is tank range after reserve.
- A rider waypoint within 150 m of a packed station is a refuelling reset.
  Ordinary rider waypoints are not.
- For each departure, the first three quarters of usable range serve the
  selected ride objective. Once fuel is needed, choose the first sensible,
  forward, route-connected pump after 75% rather than exploring the province.
- Retain only a bounded useful alternative set (maximum six) for **Choose
  another pump**.
- Prefer zero generated stops only when the rider waypoint is safely reachable
  and post-arrival fuel escape is proved, unless the destination itself resets
  fuel.
- Otherwise rank complete chains by minimum stop count, forward/directional
  coherence, and sensible journey distance. Profile quality is a final
  tiebreaker, never permission for a random detour.
- Reuse and partition the proved profile foundation when a safe on-route pump
  exists. Do not reroute the profile repeatedly merely because fuel is enabled.
- Every rider or committed fuel anchor receives a fresh planning window. The
  prior waypoint's elapsed time never consumes the next waypoint's allowance.
- A pump is committed only after its profile approach is proved in time. If a
  later continuation reaches the window deadline, return the proved pump prefix
  and resume from that pump with a full tank and a fresh window.
- A completed exhaustive no-chain proof is `gap`. Timeout, cancellation,
  transport failure, missing/unreadable fuel, or incomplete proof is `unknown`.
  Never turn one into the other.
- Fuel is advisory to geometry. If fuel proof fails, finish the road route,
  preserve prior pumps, and attach the warning to the exact affected rider leg.
  Start and export remain available with the existing acknowledgement rules.

Planning fuel comes from the promoted `fuel.v1.json` sidecars, not viewport POI
markers or Overpass. Android consumes the LIVE fuel result online and the
installed sidecar offline.

## 5. Pack contract and source selection

The public catalog is
`https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/manifest.json`.
Validate every advertised byte count and SHA-256 before atomically activating a
download. An incomplete or mismatched download never replaces a working pack.

The current V3 registry is `ns`, `nb`, `pe`, `nl`, `qc`, `on`, `mb`, `sk`,
`ab`, `bc`, `yt`, `nt`, `nu`, `me`, `nh`, `vt`, `ny`, `mi`, `mn`, `nd`, `wa`, and `id`. For those regions select
`graph.v3.bin` with an advertised V2 fallback. Other published regions remain
V2 until Pack Factory promotes their V3 bytes and the registry changes.
Geometry is `geometry.v1.bin`; planning fuel is `fuel.v1.json` when advertised.
The exact V3 byte contract is in
`docs/PACK-DATA-V3-AUTHORITY.md`.

Source selection is simple:

- online planning uses LIVE, even when the same region's pack is installed;
- offline planning/rerouting uses a checksum-valid installed pack; and
- no successful LIVE route triggers a pack download merely to “make it match.”

LIVE and PACKS still refer to the same promoted R2 fabric. Delivery path is not
a second road network.

Packed travel direction is independent of Dirt/Balanced/Clean. OSM `oneway`,
roundabouts, and implied motorway/motorway-link arcs are encoded in `graph.v3`
CSR; missing or ambiguous direction stays two-way. **V4 legal-topology packs**
(`graph.v4.bin`, capability `legal-topology.v1`) additionally encode turn
restrictions, barrier nodes, per-direction motorcycle access, and
conditional/seasonal fail-closed rules. Android online planning uses the shared
LIVE router. Offline Kotlin must **search** `graph.v4.bin` with the same
turn-aware, access, heading-safe, and connectivity-aware snap law as Swift
`OnDeviceRouter` / `GraphV2Pack` and JS `find-path-v4` / `legal-topology/snap`
— decoding identity is not enough. V4 tap radius is zoom-aware and capped at
2000 m; V4 scores stay on directed candidates through pair selection. Do not
mix V3 and V4 packs in one search. ATV tags must not override `motorcycle=no`
on V4. DIRT Dev installs the Nova Scotia V4 candidate; production stays on
public V1/V3.

## 6. Start Navigation and rolling offline preparation

Start Navigation must not download every province/state touched by a long
itinerary.

Before **Begin Ride**, prepare only:

- basemap tiles for the first visible Point/F stage corridor; and
- the routing pack for the rider's current province/state.

After navigation begins:

- queue the next basemap stage quietly and advance one stage at a time; and
- acquire or activate a later routing pack only when the rider's actual location
  enters that region.

Preserve the current blocking progress, cancel/retry, and explicit degraded
choices (**Ride with live maps only** and **Ride without offline rerouting**).
Do not reinterpret rolling navigation safety prep as planning auto-download.

## 7. Navigation parity

- Graph-decision maneuvers are authoritative. Geometry cues are fallback and
  Rally enrichment only.
- There are two cue modes: **Junction — Essential** and **Rally — Everything**.
  Audio is independent; surface is visual and is never announced as TTS.
- Stage IDs remain stable. The countdown targets the next named Point/F
  waypoint. Passed cues do not replay after a rebase.
- Off-route rerouting replaces only the active stage and preserves later
  stages. Offline is attempted first during navigation, then LIVE when
  available.
- Active foreground navigation keeps the screen awake. Ferry styling,
  notification, route statistics, and cues retain their current semantics.
- The route-build progress panel remains persistent until route creation
  completes. Planner content scrolls within its bounded sheet; primary
  navigation remains fixed on screen.

Use `docs/00-NAVIGATION-SOURCE-OF-TRUTH.md` and current iOS code for exact cue
distances, thresholds, copy, and layout. Match hierarchy and touch geometry;
do not substitute a generic Material navigation screen.

## 8. Diagnostics

Android must record enough evidence to distinguish a data, server, client,
cancellation, timeout, or route-quality issue:

- requested/effective profile and Allow Unknown state;
- LIVE/offline source, request ID, service contract/build, and pack identities;
- route distance, surface shares, corridor/shape/backtrack data, fallbacks,
  search time, and work/cap outcome;
- fuel range/reserve/usable range, window anchor and attempt, candidate count,
  selected reason, alternatives, stops, preserved prefix, and gap/unknown scope;
- foundation reuse and whole-chain distance/dirt metrics;
- edit type, selected visible stage, earliest rebuilt stage, and reused prefix/
  suffix counts;
- start-navigation blocking stage count, current routing region, tile count,
  downloads, and degraded choice; and
- explicit cancellation and stale-result disposition for every superseded
  generation.

Every fuel timer must be attributable to its departure anchor so logs prove that
the window reset at each Point/F waypoint.

## 9. Routing and navigation acceptance gate

Android is aligned only when all of these pass:

- online/no-pack, online/installed-pack, offline/eligible-pack, and
  offline/missing-pack source-selection tests;
- profile, unknown-access, urban-core, ferry, topology, timeout-honesty, and
  no-free-space-join tests;
- automatic fuel off, zero-stop, one-stop, multi-stop, sparse proved-gap,
  interrupted unknown, candidate replacement, and long incremental-window tests;
- stage-local Dirt/Balanced/Clean and Allow Unknown edits with a moving pump,
  proving that policy does not leak into later stages or rider legs;
- Start Navigation on a cross-country itinerary proving only the current region
  and first stage block Begin Ride, followed by a simulated region transition;
- Junction/Rally cues, named-waypoint countdown, active-stage reroute, ferry,
  sleep, and degraded-start tests;
- shared LIVE regression probes plus Android offline equivalents against the
  same promoted pack hashes; and
- the required Pixel 7 emulator pass before a physical Android build.

Exact geometry may vary only when a different promoted pack identity explains
it. Route character, stop count, edit ownership, warnings, and safety laws are
the parity gates.

## 10. Subscription, paywall, and entitlement parity

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

## 11. Account, authentication, and deletion parity

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
Routing selection is equally strict: development resolves
`https://pack-fabric.vercel.app`, while production resolves
`https://dirt-mayday.vercel.app`. The APK/AAB verifier must reject the opposite
host. Promoted immutable public packs may be shared read-only; candidate pack
prefixes must only be configured on the development routing deployment.
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

## 12. Groups, location, and safety parity

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

## 13. Product surface, GPX, and design parity

Android must preserve the DIRT product hierarchy and route-first experience,
not replace it with a generic Material sample. Controls, typography, sheets,
motion, accessibility semantics, and system integrations should feel native to
Android while maintaining the same information priority and rider outcomes.

Rider Services use the same environment-selected DIRT backend contract on both
platforms. Fuel remains packed. Campground, lodging, and liquor viewport
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

For imported GPX files, current parity is faithful trace display and local save.
The future GPX-to-DIRT conversion in `docs/GPX-IMPORT-TO-DIRT-PLAN.md` is one
cross-platform milestone: original preservation, reachable entry selection,
open/loop detection, clockwise/counter-clockwise choice, bounded graph
alignment, fuel planning, warnings, cancellation, and recovery must be designed
and tested for both platforms before either is called complete.

Apple CarPlay is parked and has no automatic Android Auto implication. CarPlay
and Android Auto require separate entitlement, safety, template, distraction,
and physical-head-unit projects. Neither is a simple compatibility flag.

## 14. Privacy, release, and operational parity

`docs/APP-PRIVACY-DATA-MAP.md` is the current behaviour inventory, not an
Apple-only truth. Android must reconcile every collected, transmitted, stored,
and deleted data category against its actual implementation, then use that
inventory for Google Play Data safety and the public privacy policy.

The iOS package/hygiene audits and launch/support runbooks record implemented
verification and operating baselines, not Android completion. Android needs its
own signed-AAB inspection, dependency notices/provenance, production health
evidence, named launch owners, backup/restore proof, and Play Console/device
qualification. The unresolved iOS MapLibre artifact/signing gates do not clear
or replace Android's separate release-package work.

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

## 15. Full-product parity ledger

The Android agent must keep a checked evidence ledger against this table. A row
is complete only when implementation, automated tests, and the required real
service/device proof exist.

| iOS reference | Android-required outcome | Evidence gate |
| --- | --- | --- |
| Routing freeze `routing-rc1-2026-09-03` | Same LIVE contract and equivalent offline rules | Shared fixtures + Pixel emulator + physical ride |
| Build `2 (14)` Start Navigation | First stage/current region block; rolling next-stage/region prep | Long-route transition tests + physical device |
| `SubscriptionGateTests.swift` | Free Save, gated export, exactly two consumed ride starts | Unit/UI + Google Play test purchase/restore |
| Account/Profile + deletion RPC | Same lifecycle, expired-session shutdown, and fail-closed deletion | Rollback deletion/session/atomicity matrix + real provider + deployed RPC + data-removal audit |
| Groups safety policies + shared migrations/RPCs | Same selected-group privacy, current rider statuses, retained stationary presence, synchronized sharing state, and authorization | Rollback RLS/private-Realtime matrix + hosted multi-account/background tests + marker stability + physical devices |
| `APP-PRIVACY-DATA-MAP.md` | Implementation-matched Play Data safety disclosure | Release bundle and network/storage audit |
| `GPX-IMPORT-TO-DIRT-PLAN.md` | One cross-platform conversion contract | Shared fixtures + platform UX/device tests |
| Release verifier/checklist | Android signed-bundle and Play Console equivalent | Clean production AAB + closed-track proof |

Whenever the iOS reference changes, update the commit/build identifier above,
reconcile this table, and identify which Android evidence became stale. Do not
mark parity from screenshots or successful compilation alone.

## 16. Non-goals

- Do not change the frozen shared routing engine during Android parity work.
- Do not fork LIVE search into Kotlin.
- Do not rebuild or publish packs from the Android repository.
- Do not add Direct, FTEN, longhaul, free-space joins, Overpass fuel proof,
  Network Lens, surface TTS, or silent planning downloads.
- Do not copy Apple-only authentication, StoreKit, Keychain, or App Store APIs
  into Android. Implement the Android-native equivalent of the same rider
  contract.
- Do not replace the DIRT interface with default Material composition.

If Android reveals a genuine shared-contract defect, stop and report the fixed
reproduction against the frozen baseline. Reopening the iOS/shared routing
candidate is a separate, explicit decision.


## September 8 owner-directed rollback candidate

Routing behavior is restored to 71aa7fd (September 6 legal directions/Highway 104 work). Current sealed V4 road/fuel files and connection revision 03 are unchanged. Compatibility overlay retains compact V4 readers, streamed/lazy loading, catalog URLs, V4 regional topology selection and installed multi-region loader integration. The later-only native customer endpoint assignments are omitted because the restored router has no such interface. SavedRoute.routeSeedsData remains present solely for installed-store schema continuity. No new route costs, search rules, fuel ranking or compass work is included. This candidate is for physical comparison, not qualification; Android must use the restored behavior before parity is claimed.


## September 8 build 20 — regional ownership and V4 access

Owner requested these two repairs without profile tuning or pack rebuilds. Route and fuel middle hops select the unique region shared by their bordering seam pairs, instead of the administrative owner of a border coordinate. The native multi-region loader already follows its ordered region list. JS route search, reverse distances and fuel reachability now use directional V4 permission instead of aggregate legacy classification; Swift route/fuel search and reverse distances do likewise. Verified is admitted, unknown follows the toggle (Clean remains off), denied/conditional stay blocked; existing endpoint and turn checks remain. Android must mirror these rules. Dirt still seeks the highest achievable known-dirt share.

46 focused JS tests passed; device build succeeded. Exact NS→Maine replay advances past the formerly wrong NS graph in hop 2; it now fails hop 3 because all 128 supplied ME/NB seam anchors lie at latitude 44.8108–44.8952, on the island network, with no connected candidate to the Maine destination. No stored pack objects or seam metadata changed. This remaining coverage issue is not declared fixed. Build 20 is a bounded progress test, not complete cross-border qualification.

The existing unloaded-pack cache identity fix (3da6de4) is retained: a cached spatial index must belong to the same live pack instance. This prevents stale road indexes and crashes after pack switches. Native one-way fixture exposed the missing rollback compatibility fix.

## Atlantic DEV canary build 21

The four Atlantic regions use fabric-v4-20260908-01 for roads, fuel, services and
connections. Factory corrections 2fb1b7b and ae8aa94 preserve OSM toll passage.
Routing reader behavior remains build 20. Android must consume the same corrected
permissions; no Android implementation or physical acceptance is claimed.


## Pending live acceptance: ATL-03 fuel arrival selection

A shared weak road component does not prove a directed arrival is reachable.
Fuel planning must consider already-eligible nearby arrival candidates using
the completed directed reachability search before claiming a fuel gap. Keep
the snap radius, access permissions and carried fuel unchanged. Live JS is
under test; Swift/Android implementation and device acceptance are deferred.


## Deferred parity after live acceptance: ATL-04/05

Preserve V4 searched edge sequences: proximity-based or coordinate-based loop
cutting cannot prove a legal junction or turn. Arrival snapping must score the
direction of travel into the destination, not its opposite. Live JS is under
verification; Swift/Android changes are deferred under the live-only direction.
# Adventure routing replacement — September 8, 2026

An isolated live-JavaScript replacement is in development; see
`ROUTING-REBUILD-SPEC.md` and `ROUTING-REBUILD-PROGRESS.md`. No Android or
offline implementation is claimed by the current experimental core. Accepted
mode/anchor ownership, known-surface statistics, fuel proof states, route
persistence, variety and recovery outcomes must be ported and verified after
live acceptance. The new code is not wired to the deployed API or app yet.

The replacement experiment now distinguishes urban exposure from surface cost,
counts exposure on exact directed partial road geometry, and retains fuel-state
alternatives when an urban pump is necessary. Small settlement records are not
blanket exclusions. The strict ordering around required urban anchors remains
under evaluation; do not port the experimental tuning as an accepted policy.
No iOS/Android implementation or device qualification is claimed in this step.

Reusable graph preparation is now an experimental JS optimization. It is keyed
by exact loaded data/revision and urban bounds, retains completed data only, and
preserves route geometry in local comparisons. No new rider-facing contract is
introduced; native caching implementation and memory qualification remain
platform-specific work after live routing acceptance.

Pending replacement acceptance: fuel search, destination escape and final proof
must use consistent floating-point boundary handling without spending protected
reserve. Cancelled/deadline-expired searches cannot be labelled no-path even when
no forward labels remain. These JS corrections have regression coverage; native
implementation and rider acceptance remain deferred under the live-first scope.

Fuel proof now reports destination arrival fuel separately from planned departure
fuel after a station refill, including unverified onward escape. Future native
consumers must preserve that distinction and must not treat a planned refill as
confirmation of fuel actually obtained. No mobile implementation is claimed.

Replacement request validation now distinguishes absent starting fuel from
malformed/nonfinite fuel and rejects missing waypoint/leg entries or invalid
identities. Future platform adapters must present input errors separately from
incomplete search or geographic infeasibility. Completed road geometry remains
available when fuel proof is interrupted. No native implementation is claimed.

The single-region From Here experiment now integrates canonical station matching,
fuel-state search, geometry and destination escape. Provisional road projections
must remain distinguishable from verified station entrance/exit evidence. Fixed
fuel anchors remain non-movable; generated fuel stops carry separate ownership.
Equivalent route costs prefer fewer refills, empty matched station sets report a
data/matching limitation promptly, and fuel-label limits retain advisory geometry
with an incomplete fuel result. No native implementation or live acceptance is
claimed; the full checkpoint is `ROUTING-FROM-HERE-INTEGRATION.md`.

The experimental JS reverse search now uses bounded compact storage and exposes
preparation reusable only for an unchanged graph/cost identity. Storage exhaustion
is an incomplete computation, never proof that no route exists. Native parity
must preserve that outcome and exact directed-distance semantics; the storage
layout can differ. No Swift/Android implementation or live qualification is claimed.

From Here reverse preparation reuse is now integrated in the JS experiment.
Equivalent road topology may reuse costs, but fuel state and turn history remain
request-owned. Pin, access-policy, pack revision or cost changes must invalidate
incompatible preparation. Capacity exhaustion stays an incomplete computation.
Native implementations remain deferred under the live-JS-first direction.

The experimental JS station-match cache may reuse only completed evidence for
unchanged source identity/coordinates, graph revision and matching policy. Cached
road projections remain provisional, current station metadata remains current,
and fuel estimates never come from cache. Capacity bypass must still consider
all stations; cancellation/partial matching cannot become geographic scarcity.
Native implementation remains deferred; only the JS experiment is tested here.

The JS experiment now supports admissible capped reverse guidance: stopping
reverse expansion at the start must never label unexplored roads unreachable or
impose a geographic corridor. Platform equivalents must preserve fuel/turn/urban
outcomes. An explicit cold-preparation allowance shares the request deadline and
reports its work separately; it cannot silently reset the clock. Native parity
implementation and device qualification remain deferred.

From Here now reports optional ride-shape diagnostics: repeated source-road
intervals, revisited nodes and continuous known-dirt runs. They do not introduce
new routing penalties or bans. Fuel/rider-waypoint spurs require context and
unknown surface cannot extend known dirt. This is JS diagnostic instrumentation;
no new native UI, routing behavior or qualification is claimed.

A DEV-only NS candidate02 canary can now return the replacement's complete
route/fuel hops through the existing route/fuel-chain contract. It labels the
engine and provisional station access, preserves reserve-adjusted client fuel,
and keeps unsupported requests on the existing engine. All platforms must use
the same shared candidate pool and preserve unknown-surface/access reporting.
No native implementation or device acceptance is claimed by the service adapter.

### NS/NB DEV integrated fuel preview — September 8, 2026

The iOS DEV client requests up to 12 combined fuel/geometry legs for NS↔NB primary legs with no individual fuel-hop overrides, disabling the legacy graph-only forwardFeeler hint. Other regions and production retain existing behavior. Android must consume the same complete route/fuel geometry and validate every hop against remaining usable fuel; a province boundary never refills the tank. This is a DEV route-building contract, not offline navigation qualification. No Android implementation is claimed.

### Atlantic DEV phone feedback correction — September8 evening

Live canary must honor ordinary Clean avoidMotorways preference rather than
silently route through legacy. Avoidance exposure includes motorway/ramp and
reviewed city boxes; legal unavoidable connections remain possible. The NB
source-locked city/town>=20k classification supplement is a versioned DEV review,
not a mutation of sealed02 packs or proof of complete urban coverage.

Generated fuel stop alternatives must preserve full range/escape/turn legality,
fixed anchors and the existing deadline. Substantial fuel-linked retracing may
trigger one alternative for the worst circuit in the shared pool; replacing it requires less
retracing, shorter actual travel, at least as good avoidance exposure and more
fresh known dirt per actual kilometre. Physical surface totals still count all
travel. A necessary pump is never banned just because its access retraces.
This is currently live JavaScript DEV work; offline/native parity unqualified.

### Onward fuel search supersedes pump replacement — September8 late evening

Experimental shared search orders urban/motorway exposure, traced out-and-back
travel, style cost, then equal-cost refill count. A reversal follows the stored
approach, including passing a pump then turning back. Charge both directions of
that return in the retrace priority. Necessary fuel access remains legal; fuel
range, endpoint escape, and turn history remain independent hard constraints.
The earlier one-station exclusion/percentage-veto pass is removed. No special
station IDs or geographic direction cones implement this rule. The same policy
applies to each region enabled in the DEV adapter. Full approach histories before
a reversal may still be pruned: bounded candidate generation, not a global
optimal simple-path proof. The search retains its20s deadline and30M work cap;
Atlantic fuel-label allowance400k is empirically checked against the2GiB host.
Physical percentages include all ridden distance. Offline/native parity awaits
live acceptance; this entry defines the behavior Android must ultimately match.

Candidate-pool completeness must be false if any fuel candidate remains
unverified, including a label limit. A valid selected route does not prove all
style alternatives were evaluated. Label ceilings are implementation resource
budgets; native runtimes must reproduce these diagnostics and rider outcomes
within their own measured memory limits, not blindly copy server allocations.

## September8 continuity candidate (not yet published)

Shared live JS adds a nonnegative charge once per continuous dirt run during
candidate search, scaled by objective savings over1000m. Include onDirt in search
state/dominance and preserve it through refills and projected edge splits. Fuel
range, legal turns, fixed anchors and destination escape remain hard constraints.
Paved objective has no dirt-entry charge; raw surface totals stay unchanged.
Single-region fuel guidance1.5, joined-region2; no new label/time cap. Swift and
Android implementations remain deferred under the live-first authorization.
This local qualification is not device or offline parity acceptance.

Continuity candidate published to stable DEV9c15324 after hosted/public checks.
Physical acceptance and Swift/Android parity remain pending. This supersedes the
publication status (not the behavior description) in the candidate entry above.

Continuity live behavior received rider visual acceptance at22:36UTC on app2(23),
NS-only Dirt/unknownOFF/fuelON, destination46.980210,-60.472582. This accepts that
live route build; Swift/offline/Android implementation and verification remain
outstanding, and Clean refinement remains the next live repair priority.

Clean back-road candidate: paved objective uses positive road-class factors
primary/link4,trunk/link8,motorway/link/freeway32,service6,otherwise1, multiplied
by100fornonpaved/unknown. No access prohibition; fuel/turn/escape constraints
unchanged. Shared pool Dirt/Balanced objectives unchanged. Localonly at this
entry; live publication/physical acceptance recorded in routingprogress. Swift
andAndroid replication remain deferred under live-first authorization.

Clean qualification update: paved candidate alone uses explicitfuelheuristic3
(otherobjectives retain priorweights). Same label/deadline/work bounds; no retry.
A complete response with a dirt-heavy fallback is not a qualified Clean result;
NSCapeClean regression verifies paved selection, surface and completepool.
Shared live-first/physical/offline qualification boundaries remain unchanged.

Clean cost/guidance revision published to stableDEV8be23e95 after hosted/public
qualification. PhysicalClean acceptance, Swift/offline/Android implementation
andverification remain pending under live-first authorization.

## Pending live qualification: Clean station exit/rejoin, September 9 UTC

A legal fuel exit can rejoin a previously ridden approach beyond the immediate reversal cursor. Clean candidate refinement must detect that repetition in either direction, re-search with fuel and legal turn state intact, and preserve fixed rider anchors. Generated pumps can change. The live-only prototype conditionally re-searches repeated paved candidates and exposes refinement failure; histories are bounded, not a global optimality guarantee. Dirt/Balanced history refinement and native parity are not qualified. No Android implementation or device acceptance is claimed. See ROUTING-REBUILD-PROGRESS.md for the exact fixture and local results.

## September 9 UTC — final fuel correction live on DEV

Stable `https://pack-fabric.vercel.app` now points to exact `pack-fabric-3wcw1w2vh-goricksmith-7678s-projects.vercel.app`, source `edc55fdb42af4bb3c4dd6972ecdaabf8e4ba88c5` (stable8be23 + local fa08b4e). BOTH02 and ns-nb-v1 unchanged. Public exact replay returned HTTP200 in 11.246s, server10.339s: 586.973km, three pumps, zero repeated road, complete candidate pool, all fuel intervals/destination escape/geometry joins pass. Diagnostics explicitly show refinement22,703m→0. Third pump is Esso,11107 Rue Principale,Rogersville (`osm:n5301512825`).

Private hosted exact request passed twice: first18.975s server, repeat10.983s. NSClean10.486s/757.037km/0repeat; three earlier NB Dirt references7.737–9.128s; prior NBClean6.916s/955.802km/0repeat. All hosted candidate and fuel checks pass. Evidence `/tmp/dirt-final-fuel-public.json`, `/tmp/dirt-final-fuel-hosted`, `/tmp/dirt-final-fuel-hosted-repeat`, `/tmp/dirt-fuel-refine-hosted-ns`, `/tmp/dirt-fuel-refine-hosted-nb`.

Physical retest: build a fresh From Here route to the same pin47.047134,-64.891699, Clean, automaticfuelON,250km/10%. No reinstall or pack download. Saved route geometry remains stable. Device acceptance remains pending; 19s first-request latency and broader Dirt history qualification remain open. No production/GitHub/phone-pack/Swift changes.

## September 9 — waypoint arrival integration, local qualification

User explicitly approved replacing legacy routing throughout the multi-waypoint flow. Local implementation now resolves prior source-road IDs across regional/joined packs, reconstructs a continuous directed history suffix, seeds node/via-way restrictions conservatively, and preserves direction through interior projections. Unknown/ambiguous context returns incomplete. Covered Atlantic unsupported controls no longer silently fall through to the older engine. Other regions/admin actions retain existing dispatch. Missing source history is not silently treated as a free turn.

Continuation candidates use a positive fourfold recent-road cost, preserving necessary returns; the existing app sends only30km/256deduplicated edge IDs. This is NOT whole-itinerary variety. Continuations use the six-objective candidate pool and conditional fuel-approach refinement. Refinement can hit a label limit and retain the earlier feasible candidate with explicit diagnostics; no claim all candidates are loopless. Two-way/profile changes and truncated restrictions need physical qualification beyond local tests.

Local full replays: Inverness and Yarmouth four anchors, all three primary legs new-engine-only, complete pools, fuel carry-forward/escape/geometry joins pass. Extra Yarmouth Dirt→Balanced→Clean run at162km usable passes. Selected Inverness circuits removed. Yarmouth continuation258.261km still overlaps108.943km of the earlier leg (prior edge IDs, same regional pack); the30km history limit cannot prove whole-ride novelty. This remains an open quality issue, not a pass claim. Evidence `/tmp/dirt-multi-arrival-final`, `/tmp/dirt-multi-arrival-styles`; reproducible `bench/replay-multi-waypoint.js` supports private deployment replay.

No stable publication yet. Swift/app/phone packs/production/GitHub unchanged. Arrival restriction and graph mapping changes require native parity after live acceptance. Required pump overrides and other advanced controls remain explicitly unsupported in the opted-in Atlantic new-engine flow rather than using legacy routing.

Arrival-context live canary follow-up: common candidate comparison completes before bounded optional quality refinements. All three profiles consider the same potential winners; optional limits preserve proved fuel results with explicit diagnostics. Incomplete core comparison or unqualified covered packs returns unknown without a legacy switch. This is live JavaScript qualification only, not Android or Swift implementation. Full-itinerary novelty remains unqualified beyond the native 30 km recent-road context.

Atlantic continuation qualification a518fd38: four shared continuation objectives; fuel-aware search first, advisory road search on failure; bounded requested-ID arrival matching (4096 cached IDs per immutable pack); optional common profile-winner refinement up to4seconds inside unchanged20second request deadline. Covered requests never silently fall back on unsupported context or unqualified packs. Private full multileg and mixed-style/162km tests pass. Broad earlier-itinerary overlap remains open; current native prior-road context is30km. Stable DEV physical review only; offline Swift/Android parity is not yet implemented or qualified.

## Zoomed-out rider waypoint search — 9 September 2026, local qualification

Rider area placement keeps the existing nearby snap choice, then expands only when no connected endpoint pair is found. The fallback scales with map zoom (28 screen points), capped at 20 km; explicit match limits and street-level precision remain unchanged. Candidate roads must meet access rules and share a road component with the start, and the normal directed route and fuel search still must complete. This is an area-selection tolerance, not a fabricated connection. Fixed fuel station matching remains 150 m. Existing arrival history cannot be moved to another road. Successful route geometry supplies the snapped destination to the existing app pin update.

Local evidence: 185 focused tests and 18 real NS/NB fuel-supported area-placement cases across Dirt, Balanced, and Clean passed. The benchmark fixtures include eligible roads 2.2–17.4 km from the selected area point. Private hosted verification and stable DEV publication are pending; current stable remains a518fd385ac2e6d794e29c1b445f96daba17e816 on both Atlantic 02 packs. No native app or pack changes. Android must reproduce this rider-area selection behavior when parity work resumes.

Whole-itinerary overlap remains open: current native requests carry only the most recent 30 km / 256 road IDs. The service cannot reliably avoid earlier roads that were not included. Do not equate zero repetition within a primary leg with zero overlap across the whole itinerary.

Follow-up fixed-service guard: rider anchors within the app’s 150 m mapped-pump recognition radius retain the existing narrow endpoint search; they do not use coarse area expansion. This closes the distinction between a general area pin and a rider-selected pump even when the request carries coordinates without a station ID. 186 focused tests pass including this case. Stable area source 1c806472 passed six independent public area/style checks; the fixed-service follow-up is local pending hosted qualification.

## Qualified stable DEV — waypoint area search and mapped-pump guard

Stable https://pack-fabric.vercel.app now resolves to https://pack-fabric-95glsdjaz-goricksmith-7678s-projects.vercel.app, source **7944b89ddabcd4df5ac60e5495cbe66ef087b9f7**. Independent public six-case NS/NB area/style verification passed with exact source and BOTH fabric-v4-20260908-02 identities, after the local/private qualification above. Runtime worktree commit18cb8f9. Evidence: /tmp/dirt-fixed-poi-public/summary.json and per-request files. No reinstall, native changes, phone pack download, production change, or GitHub push. Physical acceptance of the wider snap remains pending the rider’s morning tests.

Overnight continuation: automation overnight-atlantic-routing-refinement is active every15minutes through the 08:00 Halifax September9 handoff. Continue varied styles, unknown-access settings, fuel ranges and moved-pin/primary-leg cases; do not repeat completed qualification without a new reason. Preserve this qualified stable source unless a replacement passes local and hosted checks. Whole-itinerary overlap beyond the native 30km/256edge history is still unresolved; do not claim it fixed. Native parity and a bounded whole-itinerary context contract remain subsequent integration work.

## Exact device log replay — 01:59–02:01 UTC September9

The supplied log uses a518fd (before wider snapping), with a repeatedly failing destination43.566279,-65.491539. Public7944b89d now completes the original coarse placement in6.032s and the first moved-start case in3.930s; destination projection is2391m away. Street-zoom12.5 still rejects that original off-road destination; after moving it onto the road, the logged final case completes in2.628s. Cancellations while adding/moving pins are expected superseded requests, not engine failures.

A new regression checks continuation from a wide-snapped waypoint when native still sends its original coordinates. Expand discovery of the exact supplied arrival edge within the allowed area radius; never switch arrival to another road. 187 adventure tests pass including a two-leg encoded-map proof with identical geometry join. The full original four-anchor device itinerary atzoom6.6 passes locally in all three primary legs with fuel carry and destination escape. Reproduce with bench/replay-multi-waypoint.js, REBUILD_MULTI_CASE=coarsepins REBUILD_MULTI_ZOOM=6.6. Live follow-up pending private/public qualification.

Remaining integration boundary: native must persist resolved coordinates/placement precision per waypoint so zooming into an unrelated edit does not shrink a previously placed area pin’s tolerance. Current requests supply one map zoom for all endpoints; this is not corrected by guessing previous user state on the service.

Qualified stable DEV now **93826d3137c6c8fb05eba3e8f86ad145de2c293f**, exact deployment https://pack-fabric-aurvxp6er-goricksmith-7678s-projects.vercel.app behind https://pack-fabric.vercel.app. Independent public replay of the original four coarse device pins passes all three primary legs with exact source/BOTH02 identities, full pools, fuel carry, joins and escape. Evidence /tmp/dirt-wide-arrival-public/coarsepins-complete.json. Runtime dd2ff41. Rollback7944b89d retained. No native/phone/pack/production/GitHub changes. Overnight follow-ups must use this new stable baseline, not earlier7944. The per-waypoint zoom/coordinate persistence issue and longer itinerary overlap remain open for app integration; neither is claimed fixed by this service handoff.

## Overnight fresh-route fuel repetition refinement — local

The3491m repeated-road case was not receiving the optional shared-pool refinement because it was a fresh route. Enabling the existing refinement alone still hit its400000-label cap. For optional fresh Dirt objectives only, a heuristic weight3 focuses the search enough to remove all3491m, retaining about79.58%known dirt (previous79.78%). Existing time/work/label limits and continuation heuristic stay unchanged. All profiles refine the same potential-winner pool. A candidate is replaced only if repetition strictly decreases without increased urban/avoidance exposure; a failed or non-improving refinement preserves the original fuel-proved route. No saved geometry changes.

187 focused tests pass. The coarsepins unknown162km Dirt/Balanced/Balanced fixture removes the first-leg repeat; add REBUILD_MULTI_FIRST_REPEAT_FREE=1 to make that a regression assertion. The final291.77m repeat remains unresolved and is not claimed removed. Clean-after-unknown departure remains a separate open issue. Stable93826d unchanged pending final local and hosted qualification.

## Shared winner guard — local qualification, September 9

Optional repetition refinements now re-rank the shared pool for all three styles before accepting a replacement. Reject a replacement if any resulting style winner has more repeated road distance or urban/avoidance exposure. This prevents the near-Dalhousie regression where improving one objective exposed a worse winner. Fresh-route optional refinements share one four-second allowance, prioritizing the largest repeat; continuation limits remain unchanged. The directed fresh refinement experiment remains private until hosted qualification.

189 focused tests pass. Local coarsepins Dirt/Balanced/Balanced, unknown enabled,162km usable passes all three legs and removes the first3491m repeat; final291.77m remains. Strict near-Dalhousie retains its accepted471m repeat (7.444s local). Full Inverness/Yarmouth six-primary-leg regression passes with fuel carry, joins and full pools. Evidence /tmp/dirt-winner-guard-{target,nb,baseline}. Stable DEV93826d remains unchanged pending private qualification; no native parity implementation is claimed. The failedbc639776 preview must not be promoted.

## Public winner refinement qualified — 56308d4

StableDEV exactq194y7yik/source56308d4f9d45d74c72be1065f87213e68725f819 now independently passes public coarsepins Dirt/Balanced/Balanced162km unknown-on (three legs) and strict near-Dalhousie471m ceiling. Source/BOTH02 identities, full pools, fuel carry, geometry joins and escape verified. Evidence /tmp/dirt-winner-public-{target,nb}. Runtime23bd403; rollback93826d retained. New device handoff prepended to ROUTING-DEVICE-CANARY.md. No native/production/GitHub/pack changes; no physical acceptance claimed.

Continue overnight on the intermittent Clean deadline and other documented gaps; do not repeat completed basic qualification without a new reason. Deadline also occurred on prior93826d, so it is not attributed to winner refinement. Current latest stable is56308d4, superseding the earlier hold notices. Automation remains active until08:00 Halifax handoff.

## Concurrent Atlantic data loading — local, not deployed

Covered cross-province canary requests start independent NS/NB graph+fuel loads concurrently, retaining requested region order and rejecting any load failure rather than returning a partial list. Joining, pack identity checks, arrival/fuel/access contracts and the20s deadline are unchanged. New debug timings separate data loading/joining, candidate search, and response assembly. This targets avoidable serial I/O; no claim yet that it fixes the intermittent Clean deadline.191 focused tests pass, including load ordering and failure propagation. Private hosted qualification required before stable promotion. Stable56308d4 remains protected.

## Exact-equivalent seam join optimization — local

Replace per-node adjacency Maps with bounded typed-array adjacency assembly and local duplicate checks; store a single canonical edge directly, allocating a peer list only for collisions. Preserve insertion order/Map.set behavior, exact node/edge IDs, source aliases, geometry, metadata, restrictions and duplicate validation. Full NS/NB structural digest matches old join: b70d296b3daaeb7f1ccbc29eb2777d0558a91005aac9e43d9ffbab930233a4b4 (353088nodes,416884edges,739038arcs).191 focused tests pass.

Separate-process local three-run medians: old1085ms vs optimized950ms; first runs1142ms vs894ms. Sampled process resident memory also fell, but these are local measurements, not hosted guarantees. Evidence /tmp/dirt-join-compact-{comparison,times}. Reproducible structural comparator bench/compare-atlantic-join.js accepts REBUILD_PACK_ROOT and JOIN_BASELINE_FILE (trusted earlier join module). Runtime is layered on unpublished concurrent-loading/timing commits; stable56308d4 unchanged pending private cold-request and regression verification. No deadline extension or fuel/access changes; no native parity implementation claimed.

## Fresh fuel-first qualification — local

Directed paved-approach heuristic experiments at weights5 and4 failed the zero-repeat Clean regression (22.703km repeated). Both experiments were discarded; no heuristic weight change remains. Instead, fresh legs now use the existing fuel-first orchestration already used for continuations. The advisory road search is performed only if fuel routing cannot be proved, eliminating redundant pre-search while preserving the same shared objective pool and hard constraints.

191 tests pass, including existing fuel-first search equivalence coverage. Local Clean final-fuel completes5.793s with exact accepted586.9725km geometry and zero repeat. All six Inverness/Yarmouth primary legs exactly match previous qualified geometry; coarsepins unknown162km Dirt/Balanced/Balanced three-leg target passes including first-repeat0. Evidence /tmp/dirt-fuel-first-fresh-{final,multi,target}. Added finalfuel case to local replay benchmark. Combined with unpublished join/loading optimizations, private cold qualification is next. Stable56308d4 unchanged. No native parity implementation or timeout-fix claim yet.

## Direct arc traversal for bound preparation — local

Reverse-cost preparation can visit projected/base road arcs directly instead of passing every arc through nested generators. Forward route search is unchanged. The direct visitor preserves arc order/projection fields and cancellation; generic graphs keep the iterator fallback. Identical full NS/NB reverse heads/from/next/cost digests for paved and distance-weighted costs. Five-run local medians improve approximately135→93ms and120→77ms. Evidence /tmp/dirt-visitor-{comparison,times}.192 focused tests pass including projected arc equivalence and visitor cancellation. Local Clean final-fuel retains exact accepted geometry with zero repeat in5.440s.

This is layered on private82ac4c1's join/loading/fuel-first changes. Stable56308d4 remains protected. Private cold request needed; do not claim fresh-load reliability from local speed measurements. No deadline, candidate pool, access, turn or fuel contract changes; no native implementation claimed.

### Private JS join allocation refinement (overnight September9)

Canonical cross-region duplicate-edge indexing now needs only edges whose two source endpoint nodes are shared across regions, as established by the completed node pass. All roads and source identities remain present; full NS/NB structural digest equals the original join.192 adventure and22 topology tests pass. This is a private performance experiment pending hosted qualification, layered on unpublished loading/join/fuel-first/visitor changes. Stable DEV remains56308d4. No Android/native implementation or new behavioral contract is claimed.

## Verified DEV performance deployment — September 9

Stable DEV now uses exact deployment px2p5tl27, source6cb27706cf0aa07d040c35ae278ecae984f754f2, preserving all five02 regions and ns-nb-v1. Sixteen hosted requests passed, including two independent cold Clean requests at19.378s and19.435s. Both leave less than one second inside the20s request allowance; this is measured improvement, not a universal timeout-fix or reliability guarantee. Six accepted itinerary legs retain exact geometry and fuel-stop IDs. The rollback is q194y7yik/source56308d4. No native/phone/production change. Public service identity verified; routing owner independently checks public routes.
Previously private concurrent regional loading, exact seam joining, direct reverse-bound traversal and fresh fuel-first orchestration now run on stable DEV6cb27706cf0aa07d040c35ae278ecae984f754f2/runtime52c95b34. Both Atlantic02 retained.214 local and16 private hosted checks pass; two independent cold requests19.378/19.435s. Independent public target3/NB/Clean pass. Same roads, candidate pool, access/turn/fuel rules and20s deadline; no native implementation claimed. Narrow cold headroom and previously documented native history/per-pin/unknown-arrival limits remain. Rollback56308d4 retained.

### Private continuation search recovery

After a non-paved continuation candidate reaches its existing label limit, a single more directed search (heuristic3) may retry the SAME objective with unchanged labelcap and original request time/expansion budget. Hard fuel/turn/access/history rules remain; shared full-pool gate unchanged. Fresh legs and paved candidates retain prior behavior. Diagnostic searchRetry records initial guidance/time and outcome.193local tests and real reverse162km continuation regression pass; prior6baseline geometries unchanged. Pending private hosted qualification; stable6cb2770 unchanged and no native implementation claimed. FreshreverseInverness180 label limit remains unresolved.

### Qualified DEV continuation recovery —4da3822

Private continuation recovery described above is now stable DEV4da3822dd7d37f6dde7720d61668aba1d7e883f8/runtimecfc8c3d, exactbz4kvcmdt, BOTHAtlantic02/ns-nb-v1.193+22local,19privatehosted and7independentpublic checks pass; rollback6cb2770 retained. No native parity implementation claimed. FreshreverseInverness180label failure and previoushistory/per-pin/unknown-arrival limits remainopen. Saved builtgeometry unchanged.

### Private connected-start snap recovery

When ordinary endpoint candidate lists have no connected pair, re-query the start against eligible components represented at the destination, within the current allowed radius; retry under existing coarse-area expansion only as needed. Never move a fixed fuel start or change an incoming arrival road. Preserve valid near pairs, destination projections, access rules and explicit radius caps; no artificial connector. Expose waypointSnap.startComponentRecovery.197+22local checks and realNS500m/3.2km cases pass; pending private hosted qualification. Stable4da3822 unchanged. No native parity claim.


### Atlantic request hardening — September 9, 2026

Accepted NS/NB route results, incomplete results and failures must never silently switch to compatibility routing. Cancelled requests return no stale geometry and cannot start a second engine. Malformed JSON/container input returns a client error. Both accepted Atlantic pack revisions require exact graph/geometry/fuel identities, not just a release name. Legacy routing remains available only outside new-engine coverage or for its still-supported operations; PE/NL and offline behavior are not newly qualified. No change to the frozen fuel-replacement interaction, navigation, route costs or UI.

## National engine qualification candidate — September 9

The opt-in national-v1 service mode uses only the audited63 release identities.
Existing NS/NB opt-in behavior is retained. Multi-pack joining now accepts3+
regions and rejects repeated region inputs; shared-node identity and restriction
remapping remain mandatory. This is an unactivated qualification candidate, not
national service acceptance. Preserve the same admission/restriction behavior
in Android. Production/candidate paths preserve one release ID and exact hashes.

Joined graph identity allocation may be lazy: route edge IDs and overlapping
source aliases must remain identical to eager composition. This is a memory
optimization only; no geometry, fuel ranking or restriction policy change.

National pack preparation work allowance scales with edge count while retaining
request deadline; do not reject larger valid packs solely on the Atlantic-sized
fixed preparation count. Route search and legal eligibility remain unchanged.

### National adapter qualification — repeated one-way approach (September9)
The JavaScript candidate recognizes a repeated single-edge from/via only-turn
only when access is exactly YES/NO in one direction, viaNode equals entry, and
the to edge attaches uniquely at the permitted exit. Enforce an only node-turn
there; do not discard restriction, mutate source metadata, or normalize uncertain,
bidirectional, selfloop, entry-only, same-edge, or multi-via cases. This resolves
OSM relation16478624 in WA. Swift/Android must implement the same derived rule
before offline national parity is claimed. Spatial urban candidate narrowing
changes preparation work only, preserving measured exposure and route costs.
Station matching may reject edges whose exact full-source bounding rectangle
cannot intersect the conservative radius rectangle, before legal projection.
Do not substitute endpoint-only bounds or change radius/access/nearest ranking.
This is preparation optimization only; it does not qualify national search.
Distinct parallel from/via edges sharing both endpoints use source-resolved
viaNode only after validating full via/to adjacency; do not infer entry from
array order. This does not permit general repeated-role edge deduplication.
Source-level corrected pack revisions must accompany national admission.
Private OFF-by-default zero-refill advisory candidate: preserve full legaldirected
arrival state and prove destinationescape within remaininginitialfuel. No repeated
edge, forced/requiredpump, minimumStops>0, or priorhistory may take shortcut.
Diagnostic zeroRefillAdvisory identifies use. This changes weightedcandidate
selection in some cases; not approved for frozenAtlantic or claimednativeparity.
National live fuel-chain budget: requests containing a non-Atlantic region may
request windowTimeBudgetMs60000; server cap60s includes graphload/preparation.
All-Atlantic(NS/NB/PE/NL) remains capped20s. Clients must allow~70s transport for
national windows and retain existing~23s Atlantic timeout. Hosting75s is only
response overhead headroom; routework does not restart its60s clock.

2026-09-10: Explicit wander now adds a continuous extra-distance charge to each
existing surface objective: 30 * (1 - wander)^2 per metre. It no longer filters
the completed pool down to the shortest (usually paved) route at zero. Selected
surface ranking and existing candidate count stay intact; wander 1 retains the
original objective. Sixty combinations of two reported NS destinations, three
profiles, five wander values and both unknown settings completed (max 1.37s
locally). Dirt at zero remains dirt-seeking; route changes have natural plateaus.
Release fabric-v4-20260909-02 exact graph/geometry/fuel identities admitted for
all 63 regions; corrected 19 graphs and unchanged 44 passed reader checks.
Production experimental zero-refill advisory must remain OFF.

Superseding the prior OFF instruction after default-WA qualification: the
proved-national-v1 zero-refill option is authorized for non-Atlantic requests
only. Unweighted legal search proves minimum urban exposure then objective cost;
a no-repeat path has zero retrace and zero refills. Initial fuel must cover the
path plus arrival-direction legal escape. Required/forced pumps, minimum stops
and prior rider history exclude this option. Atlantic exclusion remains hard.
This preserves the objective, not the previous heuristic-weighted candidate.
WA default (wander 1, avoidCities true) completes locally in 14.7s with all three
proofs; the previous fuel frontier hit 400k labels on each candidate. 225 tests
pass including exact-search comparison with urban priority and passing pumps.

Large national pack capacity: any non-Atlantic request may use90000ms server
work with100000ms transport; keep all-Atlantic20000ms/23000ms. A smaller caller
window is still honored. All work shares one deadline; incomplete searches must
remain unknown, never interpreted as a proved fuel gap.

## Fuel health metadata isolation
GET /api/fuel-chain now reads version metadata without loading the compatibility routing engine. POST dispatch, route/fuel behavior, pack bytes and Android request contracts are unchanged. A health response proves handler liveness, not fuel-plan feasibility.

## NS–PE bridge-region candidate
For routes whose selected regions include NS and PE, also load NB so the Confederation Bridge alternative is available alongside the direct ferry adjacency. Within-province PE and NS/NB selection remain unchanged. This is a live candidate pending hosted verification and native parity; no pack bytes or road eligibility changed. Android and offline Swift must carry the same required-region rule before calling this complete.

## Unavoidable-exposure lower-bound candidate
Fuel search may use reverse nonnegative avoidance-cost lower bounds in its priority queue, retaining actual accumulated avoidance for dominance and results. Bounds must match graph, target and cost function and relax fuel/turn restrictions only for an admissible estimate; forward fuel and legal-turn checks remain mandatory. Capped reverse bounds remain lower bounds, never corridor limits. Candidate passes 226 JS tests, including unchanged optimal result and a state-limit reproduction. Native parity and physical acceptance remain pending; not promoted to public routing.

Scope: the exposure-bound candidate is enabled only when the selected regions include a region other than NS/NB. Existing NS-only, NB-only and NS/NB behavior is explicitly retained.

### Regional passing-station candidate — September 10 (not accepted/live)

Private experiment only, gated by `DIRT_PASSING_REFILL_ADVISORY=candidate-v1`
with at least one region outside NS/NB. On a minimum-objective, no-repeat road,
certify a minimum-refill schedule on that fixed geometry using mapped station
nodes and full arrival-turn-state escape. This inserts no road detours and
never relaxes range/reserve, turn legality, or projected-access provenance.
It does not prove the fewest refills across other equal-cost road alternatives.
If this witness fails, retain integrated fuel search. Forced/required stops and
prior itinerary history stay on the existing path. Android/native parity and
physical acceptance remain pending; do not promote this experimental flag.

The private regional experiment uses the standard three-objective shared pool
(paved, dirt-10, dirt-30), not NB's six-objective expansion, outside the accepted
NS/NB-only coverage. All three must pass fuel proof within the unchanged app
budget. NS/NB and continuation history retain their existing pools.

The experimental reverse exposure bound is prepared only when an outgoing
edge at the destination has positive exposure cost. Otherwise ordinary bounds
and exact forward exposure accounting remain; this is guidance preparation,
not a relaxation of urban or road eligibility rules.


### Native cross-region request compatibility — September 10

Owner log dirt-app-debug-2026-09-10T182737Z proves the NS→QC request sends
forwardFeeler=true alongside routeFirstPlan=true, allowPartialWindow=true,
windowMaxStops=1. Accept this specific combined-geometry forward-window shape
in the regional engine. Return the same fully fuel-proved candidate partitioned
at the first pump with windowComplete=false when more remains; never report a
fuel-free fallback as a verified chain. Pure graph-only feelers, forced stops,
and other unsupported controls remain explicitly rejected. Existing iOS accepts
returned route geometry and advances from that pump with preserved arrival
history. Android must use the same contract. Real multi-window replay pending.

Regional candidate fuel searches that hit the label cap receive the existing
continuation-style guidance retry (weight3), within the same request budget
and unchanged label cap/constraints. This remains bounded candidate generation.

Owner-trip replay reached three pumps before parallel access roads made the
last two history edges ambiguous. Resolve their direction from the preceding
ordered approach junction; retain rejection for equally consistent orientations.
No geometric direction guess or turn-restriction reset is permitted.


### Regional fuel search: unavoidable access beyond rural destinations

Regional live search must include the reverse urban-exposure lower bound even
when the destination-adjacent roads have zero urban exposure. A rural pin may
require town access farther back. The bound relaxes turns/fuel only for search
guidance; final fuel range, turn restrictions, surface objectives and urban
priority remain unchanged. Never classify search exhaustion as a proved fuel
gap. NS/NB-only behavior is unchanged. September 10 DEV qualification uses
the owner failed destination 46.15605369715979,-70.65032958984375.

Within one shared-candidate request, identical projected topology, pack object,
exposure cost function, destination and bound stopping node may reuse the same
immutable avoidance-distance array. Cancellation still wins. Do not reuse across
changed maps, endpoints or preference costs. This changes computation only.

## September 10: regional live fuel completion repair

DEV-only JavaScript qualification. A fuel-proved candidate for the requested
objective may be returned when another objective exhausts its search budget;
`alternative_search_limited` explicitly identifies the incomplete comparison.
Clean must have a proved paved-objective candidate. No unverified fuel route
is promoted by this exception. Existing NS/NB-only behavior stays unchanged.

The regional opt-in may certify refills on a legal fixed road with repeats,
including a continuation carrying arrival turn history. It preserves reserve,
station-access evidence, arrival restrictions and destination fuel escape.
It does not claim globally optimal retracing. Optional approach refinement must
not exhaust the search after such a fixed-road proof.

A directed fuel-connectivity relaxation may prove failure in the currently
matched graph. `mapped_fuel_range_gap` distinguishes that evidence from an
unfinished search; it is not proof that no real-world station exists. A
successful relaxation never substitutes for full turn-aware routing and fuel
proof. Larger-range diagnostic tests do not change the rider's saved range.

No pack, native binary, or production promotion is part of this qualification.
After owner DEV acceptance, Swift and Android must reproduce these outcomes;
neither native parity nor physical acceptance is claimed by automated tests.


## September 10: multi-state pack selection repair

DEV-only follow-up: US and Canada/US pack adjacency must use the existing
national crossing index. Bounding rectangles must not invent a New York to
West Virginia connection and omit Pennsylvania. This chooses required packs;
actual seam traversal still requires exact shared OSM node/edge identity and
legal turn history. The join work allowance scales to the deterministic sum
of source nodes, edges and directed arcs while retaining the request deadline.
No data rebuild, native parity or production acceptance is implied.

Checkpoint before demand-loaded graph experiment: compact in-memory joins and
requested-objective-first long fuel-off searches are private candidates only.
Hosted six-region requests still exceed the 90-second deadline. Accepted live
DEV remains 139a173; no native parity, production promotion, or new pack bytes
are implied. Future paging must preserve exact road identities, turn restrictions,
profile selection, and fuel proof; an unloaded area is not evidence of no route.
