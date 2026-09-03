# Android lockstep delta — 2026-09-02

This document captures the accepted iOS/shared-routing work completed on 2026-09-02 so Android can remain behaviourally aligned. It is a delta to the Android parity ledger, not a replacement for it.

## Source baseline

- iOS/shared repository: `MAYDAYiOS/Dirt`
- Accepted source commit: `b63a3bf3fb02c42ec0d8e54359c62250f45653fc`
- Production route service: `https://dirt-mayday.vercel.app/api/route`
- Production service build verified at handoff: `b63a3bf3fb02c42ec0d8e54359c62250f45653fc`
- Android baseline observed at handoff: `MAYDAYAndroid` commit `246d0d4`

The production build identifier is a release assertion, not a value to hard-code into either app. Both clients must record the returned service identity in diagnostics.

## What Android receives automatically

Android's online planner must continue to call the shared LIVE route service. The following server repairs are therefore already active for Android and must not be copied into Kotlin as a second online implementation:

| Source commit | Shared LIVE behaviour |
| --- | --- |
| `b2241f3` | Graph-size-aware live-search scaling for large regions such as Ontario and Quebec. |
| `063ea94` | Region-scoped pack verification; release checks take an explicit region rather than inspecting unrelated regions. |
| `effb608` | Route and fuel work remain inside one live planning operation, with reusable fuel/corridor context. |
| `1c041e0` | Large-graph routing budgets scale without weakening the route objective. |
| `a49d9d1` | DIRT route-quality recovery, urban-topology handling, and disconnected duplicate-node bridging. |
| `b63a3bf` | Faster graph preparation, safe reuse of wide-search results, bounded low-DIRT recovery, and early completion of fuel-candidate evaluation once a winning minimum-stop plan is proven. |

Online Android routing must not depend on a downloaded navigation pack. Downloaded packs are for offline navigation and rerouting after navigation starts.

## Android code that must be brought into lockstep

### 1. On-device/offline router laws

Port these rules into the Kotlin on-device router and protect them with unit tests:

1. DIRT may search a wider corridor, but the selected route must continue making sensible progress toward the next rider waypoint. A wider corridor is not permission to travel backward, overshoot the waypoint unreasonably, or create a down-and-back excursion.
2. A route may leave a sensible paved line solely to earn dirt only when the diversion supplies at least 1 km of continuous, known unpaved riding. Unknown surface does not count toward that kilometre.
3. Necessary connectors, rider-placed waypoints, and roads required to reach the destination remain allowed even when the unpaved portion is shorter than 1 km.
4. Legacy CanVec-imported `track` and `service` roads without explicit access evidence are unknown access. They are not silently treated as permissive.
5. Major urban cores remain a strong wall for every profile and may relax only when no route exists. Smaller settlements are a cost, not an absolute wall.
6. Coincident or near-coincident graph nodes that represent the same physical junction must be bridged consistently for all profiles; preprocessing must avoid quadratic sibling scans.
7. DIRT quality recovery runs only when the primary result is below 70% dirt. It may keep the full lateral corridor, but the candidate's total ride length must remain bounded relative to the proven primary ride and the hard fuel limit. It must never convert a dirt objective into unlimited wandering.
8. A wide-search result may satisfy a later narrow pass only when every route point is actually inside the narrower corridor.

Do not copy JavaScript-specific search limits literally. Match the behaviour and safety laws using Android's graph representation and performance envelope.

### 2. Fuel-planning rules

Android must preserve the accepted fuel policy:

1. Start with a full tank.
2. Fuel calculations may be disabled. When disabled, build the rider's route without automatic pump insertion.
3. When enabled, begin watching for sensible forward pumps after 70% of usable fuel has been consumed; watching is not the same as inserting a stop.
4. Go directly to the next rider waypoint when it is safely reachable and the rider can still reach fuel after arriving.
5. Otherwise choose the forward pump sequence that completes the ride with the fewest total automatic stops.
6. Then prefer directional progress, followed by shorter sensible travel. Dirt percentage is the final tiebreaker only.
7. Do not choose an early, backward, overshooting, or down-and-back pump when a sensible forward option exists.
8. A rider-placed waypoint on a fuel station resets the tank because the rider is assumed to refuel there.
9. Alternative-pump replacement must keep at least the useful evaluated candidates for that departure. Selecting another pump rebuilds the affected route because both the approach and downstream fuel state change.

The candidate search may stop once a complete minimum-stop plan has been proven and all remaining candidates are unable to beat it on the accepted ordering. That optimization must not remove the alternatives required by “Choose another pump.”

### 3. Itinerary edits and reusable planning context

Port the client-side behaviour from `effb608` and `d17a4a0`:

- Keep route and fuel work within one live planning operation and consume the returned routed hops instead of routing the same selected pump hops again.
- Reuse the broad corridor's station set when the rider changes DIRT/Balanced/Clean or Allow Unknown within the same planning operation.
- Retain alternative-pump candidates by departure/fuel state so the pump chooser can show them without a fresh province-wide search.
- When a waypoint is appended, inserted, moved, or deleted, preserve unaffected route work but revalidate the fuel chain from the earliest affected rider leg.
- Reuse an upstream automatic pump only when its incoming fuel state and downstream reachability remain valid.
- A rider-added fuel waypoint must be treated as a refuelling reset before validating the suffix.
- Never keep stale automatic pumps merely because their coordinates are unchanged.

### 4. Diagnostics and release verification

Android diagnostics must make parity failures observable. At minimum retain:

- requested and effective profile;
- LIVE versus offline source;
- service build and pack identities;
- route distance, dirt percentage, corridor, maximum cross-track distance, backtrack percentage, fallbacks, search duration, and search work;
- automatic-fuel state, range, reserve, selected reason, stop count, candidate count, cache hits, and planning duration;
- itinerary edit type, earliest rebuilt leg, and reused-leg count.
- one echoed request ID plus begin/response/transport-failure events for every
  live route, fuel-chain, and fuel-data request;
- HTTP status, response bytes, elapsed time, configured timeout, cancellation
  state, profile-route attempt count, slowest candidate route IDs and timings,
  longest candidate hop, and fuel-window budget overrun; and
- an explicit cancel request and cancelled/stale disposition for every route
  generation replaced by a later waypoint edit.

The live verification command must require a `--region` argument and verify only the requested state, province, or routing region. Do not let an unavailable BC pack fail an Ontario, Quebec, or Nova Scotia verification.

## Fixed parity probes

These are regression anchors, not universal route-quality targets. Run them against LIVE first and then against Android's installed offline graph when the matching pack exists.

| Probe | Start → destination | Accepted LIVE result at source commit |
| --- | --- | --- |
| Nova Scotia short DIRT | `44.764830,-63.340265` → `45.105110,-62.882021` | about 110,275 m; 47% dirt |
| Quebec short DIRT | Existing 67 km Quebec regression fixture | about 67,268 m; 70% dirt |
| Ontario DIRT | Existing 372 km Ontario regression fixture | about 372,023 m; 83% dirt |
| Nova Scotia one-stop fuel | Existing 450 km / 15% reserve regression fixture | one automatic stop at Ultramar `osm:n5288561941`; at least two viable pump choices retained |

For the one-stop probe, the accepted routed legs were approximately 382,484 m and 12,940 m. Exact timing varies with network and device; route choice, stop count, forward progress, and parity laws are the gates.

## Android acceptance gate

Android is lockstep for this delta only when all of the following are true:

- Online tests prove Android is using the current shared LIVE contract and does not require a downloaded pack.
- Offline unit tests cover the 1 km dirt-diversion rule, CanVec unknown access, urban fallback, duplicate-node bridging, forward-progress guard, and bounded DIRT recovery.
- Itinerary tests cover append, insert, move, delete, profile change, Allow Unknown change, rider-added fuel waypoint, and alternative-pump replacement.
- Fuel tests prove zero stops when safe, the minimum safe stop count otherwise, arrival fuel escape, no backward/down-and-back stop, and preservation of pump alternatives.
- The Nova Scotia, Quebec, and Ontario fixed probes pass without changing the accepted profile objectives.
- Android's required Pixel 7 emulator verification passes before any physical-device build.

## Non-goals

- No routing-map-pack rebuild is required solely for these application/service changes.
- Do not fork the online routing algorithm into Android.
- Do not weaken DIRT into shortest-route behaviour in pursuit of speed.
- Do not narrow the DIRT corridor merely to improve timing; constrain backward progress and unreasonable total journey expansion instead.
- Do not reopen accepted routing, fuel, cleanup, map-pack, or presentation decisions outside this delta.
