# DIRT Android parity contract

**Status:** active Android routing, fuel, pack, and navigation parity authority

**Reconciled:** 2026-09-03

**Frozen iOS/shared-routing implementation:**
`94b467a11375e3ea3233c127b07af2ef039d0658`
(`routing-rc1-2026-09-03`)

**Accepted iOS build:** `2 (13)` on White

**LIVE endpoint:** `https://dirt-mayday.vercel.app/api/route`

**Required service contract:** `dirt-routing.r0.v1`

This document replaces both dated Android catch-up documents. It defines the
behaviour Android must match; it is not an instruction to copy Swift syntax or
fork the shared online router into Kotlin.

## 1. Authority and implementation boundary

Read in this order:

1. `AGENTS.md`
2. `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`
3. `docs/ROUTING-FREEZE-2026-09-03.md`
4. this document
5. `docs/00-NAVIGATION-SOURCE-OF-TRUTH.md`
6. current Swift, shared JavaScript, fixtures, and tests

Android uses the shared LIVE route service whenever it is online. Server
search, regional seams, fuel-chain selection, and current production pack bytes
are therefore already shared. Do not create a second online routing algorithm
in Android. Kotlin must implement the same contracts for client state,
presentation, edits, diagnostics, and offline routing/rerouting.

`serviceBuild` is diagnostic and changes with legitimate server or pack-release
commits. Record it on every response; do not hard-code it. A
`serviceContract` mismatch is fatal.

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

The current V3 registry is `ns`, `nb`, `pe`, `nl`, `qc`, and `on`. For those
regions select `graph.v3.bin` with an advertised V2 fallback. Other published
regions remain V2 until Pack Factory promotes their V3 bytes and the registry
changes. Geometry is `geometry.v1.bin`; planning fuel is `fuel.v1.json` when
advertised. The exact V3 byte contract is in
`docs/PACK-DATA-V3-AUTHORITY.md`.

Source selection is simple:

- online planning uses LIVE, even when the same region's pack is installed;
- offline planning/rerouting uses a checksum-valid installed pack; and
- no successful LIVE route triggers a pack download merely to “make it match.”

LIVE and PACKS still refer to the same promoted R2 fabric. Delivery path is not
a second road network.

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

## 9. Android acceptance gate

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

## 10. Non-goals

- Do not change the frozen shared routing engine during Android parity work.
- Do not fork LIVE search into Kotlin.
- Do not rebuild or publish packs from the Android repository.
- Do not add Direct, FTEN, longhaul, free-space joins, Overpass fuel proof,
  Network Lens, surface TTS, or silent planning downloads.
- Do not introduce Apple/email authentication or iOS commerce into Android.
- Do not replace the DIRT interface with default Material composition.

If Android reveals a genuine shared-contract defect, stop and report the fixed
reproduction against the frozen baseline. Reopening the iOS/shared routing
candidate is a separate, explicit decision.
