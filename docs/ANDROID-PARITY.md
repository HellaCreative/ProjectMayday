# DIRT Android parity contract

**Status:** active full-product Android parity authority

**Reconciled:** 2026-09-07

**Frozen iOS/shared-routing implementation:**
`94b467a11375e3ea3233c127b07af2ef039d0658`
(`routing-rc1-2026-09-03`)

**Accepted frozen-routing iOS build:** `2 (13)` on White

**Current iOS engineering reference:** build `2 (17)` routing candidate; Rider
Services acceptance at `9808936`, account/session behaviour through `d8f345c`,
and simulator-test infrastructure through `95f1e83`.

**Latest lockstep deltas:** September 4 Groups presence hardening, the September
5 frozen Rider Services packed-data contract, account/session hardening, and
the September 7 Yarmouth Dirt/fuel correction for build `2 (17)`. The
shared DEV service supplies the online routing change. Android must match the
same no-op stage edit and offline routing laws; Android automation and physical-
device evidence remain open.

The September 7 V4 factory hardening is also lockstep: JS, Swift, and Kotlin
track the exact ordered `from → via edge(s) → to` restriction state. Reaching a
final via road from another approach must remain legal. Directional access code
3 is allowed only at an ordinary rider endpoint; code 4 is allowed only at an
explicit `customers` endpoint selected by fuel/Rider Services. Unknown access
still requires Allow Unknown; denied and impassable directions never open.

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
  last resort. Smaller settlements use the maximum finite ×20 avoidance cost,
  not an absolute wall.
- Dirt remains dirt-first. A shortest-route-plus-60-km ceiling must not replace
  the best legal known-Dirt candidate; build 2 (16) proved that this collapses
  the reported Yarmouth ride into a low-Dirt road route.
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

A fuel timeout never commits the first partially routed pump blindly. Android
must reject every approach-only partial: the same window must prove either the
destination or a next forward pump before the current pump becomes resumable.
A completed continuation receives at most the shared 250 ms scheduler allowance;
an incomplete continuation receives none. Android must reject a partial with a
known material continuation return and prefer a rural pump over an equally safe
urban pump. A missing foundation-route proximity value is missing—not numeric
zero—and cannot grant the winding-route exception; this exact coercion admitted
the 13.2 km Coast Gas return. Fuel diagnostics must echo the effective Allow
Unknown state on direct and incremental results. Setting a stage to its already-
effective profile must not advance the itinerary generation or restart route
and fuel work. When a packed pump partitions an already-proved route, Android
must preserve that route exactly; per-part journey-quality labels must not
launch two replacement route searches. These post-build `2 (17)` deltas are pending physical White
acceptance and make prior Android route/fuel evidence stale; no pack rebuild is
implied.

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

V4 regions in one release share a single locked OSM source epoch; Android must
reject mixed epochs. Cross-region loading uses the explicit, symmetric
63-region road/ferry adjacency registry. Bounding-box overlap is not a border,
and point-only corners are not seams. A seam is usable only when both packs
prove the same OSM node/way/edge identity, direction, access, layer, structure,
barrier state, and restriction context. V4 forbids proximity stitches and
coincident-coordinate joins. Before activation, each V4 manifest must verify
the exact graph, geometry, fuel, seam sidecar, source epoch, release ID, region,
and timezone. Each sealed region downloads `cross-pack-seams.v2.json` from the
same catalog identity; iOS and Android reject it if its region or source epoch
does not match the graph. Borders are sealed after all graphs, so adding this
proof never requires a second graph rebuild.

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
| Build `2 (16)` routing candidate / build `2 (14)` Start Navigation reference | Match degraded-Dirt coherence, safe fuel timeout, no-op effective-profile edit, then first-stage/current-region preparation | Shared fixtures + long-route transition tests + physical device |
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

## Routing recovery — September 7, 2026

The failed routing evolution commits `e92584d` and `106f5a5` were reverted
locally. Product intent remains in `docs/ROUTING-EVOLUTION-SPEC-2026-09-07.md`,
with recovery clarifications taking precedence. The prior implementation is
not qualified for launch. Sealed DEV V4 `fabric-v4-20260907-01` and catalogs
remain read-only; no V3 substitution, pack rebuild, or production publication.
Routing search, costs, variety seeds, forward progress, retrace handling, and
fuel-replacement ranking are one JavaScript/Swift contract. Implement behavioral
changes together and verify both runtimes; automated passes do not replace
White-device acceptance. Android must reproduce the accepted rider outcome,
but no Android implementation or qualification is claimed here.

### Pack lookup lifetime recovery

iOS now retains a weak reference to the exact graph object alongside its spatial
lookup, preventing a reused memory address from selecting an unloaded graph's
lookup. This restores the existing snapping contract; it changes no costs,
search law, pack bytes, or navigation feature. JavaScript caches already use
object-keyed weak maps. Android must likewise key cached indexes to a live graph
identity, not a reusable address or unrelated revision. Physical qualification
of this recovery remains pending.

## DEV connection revision — September 8, 2026

DEV uses connection revision `connections-v4-20260908-02` with the unchanged
`fabric-v4-20260907-01` road, geometry, fuel, and Rider Services bytes. Only the
connection catalog and seam sidecars use `/v4/connections/<revision>/`.
QC/ON now retains 7,099 proven node/edge connections. Sidecar `componentPair`
and `networkSize` describe strict-access weak connectivity for attempt ranking,
not permission to travel. Within the existing bounded retry window, try one
representative per component pair, larger shared networks first, before repeated
crossings of the same fragment; ordinary directed/turn-aware routing must prove
every attempt. Legacy records keep their existing geographic order. JS and
Swift both implement this coverage policy. Geographic seed/chord ordering and
regional backtracking predate this change and are not yet fully lockstep.
Downloaded connection files must match the selected catalog checksum before
reuse or activation after top-up. Production continues using its accepted data.
Android must reproduce this outcome; no Android implementation is claimed.

An incomplete live fuel response may include `foundationRoute`, the completed
road line for that exact request. Reuse it only for advisory display at the
same departure and destination; retain the fuel-unknown/gap status and never
interpret the geometry as proof of fuel coverage. Advancing to a pump invalidates
the retained departure. Missing foundation uses the existing road fallback.
Responses also report optional `connectionRevision` separately from graph
release/source identity. These additions are shared API/client behavior.

Connection revision `connections-v4-20260908-03` supersedes 02 for DEV and adds
complete proven coverage for DE/NJ (1,302), NT/YT (298), and OR/WA (4,546), while
retaining the QC/ON correction. NT/YT's crossing network is separate from NT's
largest network; size-based audit results are not proof of a missing road.
V4 live searches now use directional access directly, matching existing Swift
`v4AccessAllowed`: unknown requires Allow Unknown, denied/impassable/invalid
remain closed, and endpoint/customer codes retain their endpoint purposes.
Legacy aggregate access is used only for legacy graphs. The reverse-distance
lower bound likewise uses the actual predecessor-to-current V4 direction.
No Swift access retuning was needed: its current implementation already uses
this law and its V4 endpoint tests cover these distinctions.

V4 selected fuel endpoints now admit a connected customer-only entrance/exit
of at most 200 actual road metres. Directional access and the full turn state
remain authoritative; customer roads are an endpoint prefix/suffix, never a
through shortcut. Clean may use this real endpoint access. A selected station
is snapped by proximity, without route-intent or heading penalties, retaining
only projections within 2 m of the nearest legal projection. A failed entrance
must not silently move the pump onto a nearby public road. The shared forecourt
fixtures prove separate one-way entry/exit and rejection of a forbidden final
turn through both engines with the same 80 m snap radius.

V4 route materialization preserves the searched road geometry. Geographic loop
pruning cannot cut across roads after turn legality was proved. This removes
an unsafe transformation; it does not itself qualify the pending no-retrace
search law. Android must apply these same endpoint and geometry rules.


## Atlantic canary: toll collection — September 8, 2026

`barrier=toll_booth` without an explicit closure is a passable payment point,
not an ambiguous closed barrier. Explicit access, locked, and conditional
restrictions retain precedence. The shared factory must preserve passage through
bridge and ferry payment points in the final compact pack. JS, Swift and Android
read the resulting packed permission; no client-specific geographic override is
allowed. Factory tests cover passage both ways and explicit closures. Android
implementation or physical acceptance is not claimed by this correction.

Explicit `access=yes` or `motor_vehicle=yes` at these passable payment points
must also remain passable. Destination/customer-only access does not become
unrestricted through access.

### September 9 — installed pack management

Downloaded packs offer Update when a newer approved revision is available and Delete for installed revisions. Update stages and verifies the complete replacement before switching; failure retains the previous pack. Rows remain visible during updates and actions report failures. Delete removes every cached revision for that region so catalog changes cannot leave the displayed install behind. Neither operation replaces/removes a revision pinned by active navigation. This change does not modify route selection or navigation behavior.

### September 9 — Loop and optional ride settings (DEV)

Loop means closing the current ordered waypoint plan back to its first point, not generating a distance-targeted round trip. Append a distinct return waypoint, retain earlier leg identities and carry fuel consumption into the new return leg. Hide the action when the end is already within 25 metres of the start.

Route planning offers a settings affordance beside fuel (portrait and landscape), opening a full-screen draft with ride wander, avoid cities/towns, and avoid highways. Cancel changes nothing; Apply rebuilds the full route/fuel plan. Settings travel in optional `options.ridePreferences` (wander 0…1, avoidCities/avoidHighways booleans), remain scoped to one build, distinguish cache entries, and are saved as optional metadata. Older saved routes retain defaults. The accepted default payload is unchanged.

Wander narrows the proven shared candidate pool by distance before applying surface preference, without relaxing access/fuel constraints. City avoidance minimizes mapped urban exposure; highway avoidance strongly weights other roads while allowing necessary connections and waypoint/fuel access. DEV qualification currently covers live NS/NB; offline custom planning is explicitly unavailable rather than silently ignoring preferences. Existing downloaded-route navigation remains unchanged. Broader regional/offline customization is not yet qualified.

### September 9 — national DEV catalog wiring

DEV catalog, graph, geometry, fuel, cross-pack seams and Rider Services now use the same immutable `v4/candidates/fabric-v4-20260909-01` namespace. Production URLs remain unchanged. This catalog switch follows Richard’s explicit DEV-now direction while national uploads/checks continue; incomplete uploads or server-memory failures remain tracked and are not a claim of nationwide qualification. Android DEV must select the same namespace. Existing navigation keeps its pinned installed revision.

### September 9 — Loop discoverability correction

Keep Loop back to start at the top of Plan a route, above the leg list. Show it disabled before two points exist with an explanation, and identify an already closed route. Do not hide the feature until eligible or bury it beneath fuel stages. Route-building behavior is unchanged.

### September 9 — dedicated Loop and return journeys

Routing tabs use icon/title controls on system light material with orange selection: From here, Loop, Plan a route, Saved. Create Return Route belongs to From here and Plan for an open itinerary; it preserves outbound stops and appends home. Dedicated Loop takes a start, a map-picked direction guide and total distance (50–500km), independent of tank range. It compares three complete circuits, carries fuel between legs and ranks target-distance error, repeated geometry and reused stations. Generated guides are not a promise of exact distance; show actual distance and shared-road estimate. Only complete verified builds are accepted. Cancellation cannot publish an obsolete circuit; draft replacement asks in-app before discarding an existing plan. Optional preferDifferentRoads strengthens positive prior-road costs on live NS/NB and is saved with preferences; absent requests retain accepted behavior. No nationwide/offline Loop qualification is claimed.


## Loop setup simplification — 2026-09-09

Match the current iPhone contract: start/end at current authorized GPS location; Direction menu North, Northeast, East, Southeast, South, Southwest, West, Northwest (default North); total distance 50–500 km in 25 km steps; existing Surface profiles; Create Loop. Remove start/map/towards setup and setup pins. Missing location produces inline feedback, not a permanently disabled button. Keep existing fuel validation and return-route behavior. The compact native glass/icon-title/orange-active planner treatment is the approved baseline for future UI; see root DESIGN.md. Android implementation/qualification is not claimed.


### September 9 — checked fuel-stop replacement

From Here, Loop and Plan a Route share the same fuel-stop replacement interaction. Tapping an F pin or fuel stage checks up to six canonical stations within 25 km. Highlight a station only after its replacement itinerary has a proved incoming fuel hop and complete onward continuation; preserve every upstream built leg. Tapping a highlighted station commits that checked itinerary. Never freely drag a fuel pin. Route edits, mode changes and navigation invalidate pending checks and cached choices. Failed or stale checks leave the original route intact.

The live NS/NB adventure service supports an explicit required first station, with no intervening refill before that station and continuous onward geometry. Feasibility of an individually proved replacement may be accepted even if another surface-objective comparison is incomplete; normal route candidate-pool requirements remain unchanged. Mapped station access remains provisional. This does not qualify offline parity or Android implementation.


### Fuel replacement acceptance freeze — September 9, 2026

Richard accepted fuel-stop replacement on White and explicitly froze it. Preserve the shared From Here/Loop/Plan a Route interaction and checked replacement/upstream-preservation contract above. Baselines: iOS904f11f, live476230d4bfa3ed8b5fed16514e2908266b691b63. Future engine changes must preserve this accepted behavior; no Android implementation or offline qualification is implied.


### Atlantic request hardening — September 9, 2026

Accepted NS/NB route results, incomplete results and failures must never silently switch to compatibility routing. Cancelled requests return no stale geometry and cannot start a second engine. Malformed JSON/container input returns a client error. Both accepted Atlantic pack revisions require exact graph/geometry/fuel identities, not just a release name. Legacy routing remains available only outside new-engine coverage or for its still-supported operations; PE/NL and offline behavior are not newly qualified. No change to the frozen fuel-replacement interaction, navigation, route costs or UI.


### Shared visual consistency — September 9, 2026

The approved planner icon/title tabs remain the visual reference. Selected tabs and light-surface text actions use deep orange (#B85C00; dark appearance #FFB35C), with neutral native glass surfaces. Bright orange filled actions retain dark text. Shared CTA type is sentence case and semibold; headers reserve separate 44-point back/close targets and allow wrapping. Pack actions sit below pack details on neutral cards; Profile subscription management uses the shared glass/secondary-action treatment; Group Create/Join stack at accessibility text sizes. Ride wander now also displays its existing percentage. Port this hierarchy and spacing using native Android equivalents. Routing, fuel replacement, navigation and account operations are unchanged. Native visual acceptance on White remains pending; no simulator was launched for this pass.


### Environment and subscription badge — September 9, 2026

The existing DIRT wordmark size is preserved. Development builds show DEV regardless of sign-in or subscription. Production shows PRO only when the subscription service reports an active subscription, and FREE otherwise. Signing in alone does not grant PRO. The badge is presentation only; entitlement enforcement and tester bypass logic are unchanged. Accessibility names include the edition. Android must expose the same environment/entitlement distinction. The expanded Open Terrain HTML screens are design previews, not a native UI or navigation behavior change.

## Open Terrain native UI — September 9, 2026

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

### Loop and waypoint refinement — build 29

Loop generation tries six closed four-leg circuits around a centre in the selected compass sector, with both travel directions and a wider alternative. Later candidates calibrate distance from the first completed road circuit. The last two keep the selected outward profile and use Clean on the final two legs; display those actual leg profiles. Rank complete fuel-checked circuits by distance error, repeated geometry, signed-area/convex-hull fill, and reused pumps. Reject fill below 0.35, shared roads above max(3 km, 15% of circuit), and distances outside 50–150% of requested. No candidate passing these gates means a clear failure, not an out-and-back labelled a loop. Ordinary routing and fuel replacement remain unchanged.

Adding a waypoint on an existing leg in From Here, Loop or Plan creates a provisional selected pin without route requests. Drag changes only its draft coordinate. Show “Is this where you want to place this waypoint?” with Yes/No; No retains the editable pin, and the next drag release reopens confirmation. Yes inserts once and rebuilds. From Here converts to the editable plan at confirmation. Clear/mode changes invalidate the draft. Saved previews and navigation remain non-editable. Selected waypoint pans have priority over competing map gestures; genuine cancellation does not commit the move.

Layers uses Profile-height glass presentation with a top-right X; the existing Layers navigation toggle also closes it. Active route-tool tabs use the dark navigation surface, white labels/icons, and rounded corners.

### Full-height Layers containment — build 30

While the full-height Layers or Profile sheet is open, suppress the floating map-control stack, rather than trying to place it above the full-height panel. Keep the sheet header/X within the safe viewport and the primary navigation fixed at the bottom. The list scrolls inside the sheet. This avoids control-stack padding increasing the parent layout beyond the screen.
