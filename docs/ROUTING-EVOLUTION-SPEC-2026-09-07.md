# Routing evolution spec — 2026-09-07

**Status:** implementation and local qualification are complete against the
sealed V4 candidate. Stable DEV deployment evidence belongs to the handoff for
the exact commit; physical White acceptance remains a separate final gate.
The accepted laws are mirrored in
`docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md` §12.1.

**Owner:** Richard Smith

**Implementing agent:** Codex (this Cursor session does not write routing/search code)

**Branch:** `feature/routing-itinerary-rebuild`

**Does not reopen Pack Factory.** Search/cost/seed law reopens the routing freeze. Pack bytes stay untouched.

This spec is the handoff. After implementation and White acceptance, Codex must copy the accepted laws into `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md` and cut a new freeze record. Until then, do not treat archived routing docs as authority.

---

## 0. Out of scope

- Merging the live JavaScript engine and the on-device Swift engine into one runtime.
- Water polygons, water walls, or “do not ride next to water.”
- Changing pack bytes, V4 promotion, or the public catalog.

Live search stays JavaScript. Downloaded-graph search stays Swift. They remain two places the same laws run. This work makes those laws identical and documents that requirement. It does not collapse the two codebases.

---

## 1. Product intent

DIRT creates a dual-sport ride toward the next rider pin. Dirt and Balanced may veer laterally for dirt. They must still move toward that pin. Planned routes do not retrace. A proved no-path result does not create a general escape hatch. Retrace is reserved for explicit impassable recovery back to the first usable junction, or departure from a true single-access endpoint such as a hunting lodge.

A second request for the same two points must be allowed to produce a **different forward ride**, not the same line forever. That is a product decision. Variety is not tourism, loops, or a random fuel detour.

Clean stays the deterministic pavement ride unless the rider moves a pin or selects a new From Here destination (new destination still rebuilds Clean; Clean does not shuffle among dirt alternatives).

---

## 2. Lockstep (mandatory documentation + code)

Every behavioural change in this spec is implemented in **both**:

| Place | Engine |
| --- | --- |
| Live `/api/route` (production and DEV) | `scripts/pack-fabric/routing/lib/` (JS) |
| Downloaded packs / offline / airplane reroute | `Dirt/Routing/OnDevice/` (Swift) |

Same seed + same graph + same profile + same access + same avoid-edges → same path. DEV and production use the same laws; only pack identity and endpoint differ.

Codex must add an explicit lockstep block (not a vague “keep in sync”) to all of:

1. `AGENTS.md` (this repo has no root README; AGENTS is the start-here)
2. `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md` §12 / new subsection
3. `.cursor/rules/live-and-pack-lockstep.mdc`
4. `scripts/pack-fabric/README.md`
5. `Dirt/Routing/OnDevice/README.md`
6. `docs/ANDROID-PARITY.md` (same rider outcome; Kotlin when that engine exists)

Required lockstep sentence, in substance:

> Routing search, costs, variety seeds, forward-progress, retrace rejection, and fuel-replacement ranking are one contract. Change JS and Swift in the same commit. A live-only or phone-only search change is a defect. `dirt-mayday.vercel.app` and `pack-fabric.vercel.app` must not silently diverge on these laws.

Required tests: at least one fixture routed through JS and Swift (existing lockstep style) that includes a non-zero `routeSeed` and asserts identical geometry.

Do **not** “fix” drift by auto-downloading packs or pointing production at V4.

---

## 3. Compass (bays without water walls)

Do not wall water. Riding beside water is legal and often desirable.

Measure “toward the pin” as **remaining legal road kilometres to B**, not bird-line distance and not a sausage around the airplane line.

- If a shore road **reduces** remaining road km to B, it may be used (fun, on the way).
- If a shore road **increases** remaining road km (dead-end into a bay, then a huge around), it is not progress. Do not take it merely because it is bird-closer to B.

Search for Dirt/Balanced in a band beside the **land path** (the shortest legal road connection), not beside the crow-flies chord. Halifax → Bathurst via the NS–NB isthmus is the named regression: do not ride up to Minas Basin and then around east if the land path is Truro → Amherst.

Clean already forbids a chord cross-track cone; Dirt and Balanced must stop using the airplane-line corridor as a hard geographic wall.

---

## 4. No retrace

Zero acceptance for riding back over road already used in this rider-leg, except:

1. the rider explicitly reported a road impassable, in which case recovery may follow the ridden line only as far back as the first junction that yields a legal route around it;
2. the snapped pin sits on a dead-end / driveway and those metres are the only legal access;
3. a short packed-station forecourt (maximum 200 m fuel-access allowance).

“Another line” and a new seed must still obey this. A loop is not variety. Entry and exit of a waypoint must be interesting **forward** roads, not an out-and-back on the same stem.

Field defect this law kills: obstruction reroute that sends the rider backward instead of around toward the next pin.

---

## 5. Variety seeds

Variety applies to **Dirt** and **Balanced**. Clean does not pick among dirt alternatives.

### 5.1 Storage

Each **rider leg** stores `routeSeed: UInt64`. Fuel hops inside that rider leg inherit the seed of the rider leg unless a fuel-replacement rebuild mints a new seed for the affected suffix (see §7).

The process-lifetime `planningSessionSeed` on `RoutePlannerModel` is **not** the variety source. It produces the same ride all session. Replace that behaviour.

Same seed + same endpoints + same profile + same access + same avoid-edges → same path (lockstep, reproducible, offline replay). New routing → new seed.

### 5.2 How a line is chosen

For a Dirt/Balanced search, keep **two or three geometrically different forward candidates** (different roads, not an 8% cost coin-flip at one node). All candidates must:

- move toward B on remaining road km;
- refuse meaningful retrace;
- stay within about 5 known-dirt percentage points of the best candidate (or the only connected set if fewer exist).

The seed selects among those candidates. Do not enable the old `variety: true` relax-steal as the product mechanism.

Fuel does not get its own random tour. Once a road line is chosen, fuel partitions or proves pumps on that line (existing foundation-route law). A random pump far off-axis remains illegal.

### 5.3 When a new seed is minted

**From Here**

There is no dragging of the destination pin. The rider selects another map location (short tap after the first pin, or long-press relocate of B). That location may be metres from the previous pin. It is still a **100% new route**: wipe the previous From Here itinerary, mint a **new seed**, search again. Closeness is irrelevant.

**Plan — rider moves an existing rider waypoint, or inserts on a painted leg**

See §5.4. The visible sheet is not only rider pins. A typical chain is Point 1 → F → Point 2 → F → Point 3. Generated F pins are not rider waypoints. Moving Point 2 is a fuel problem when automatic fuel is on.

**Plan — append a new destination pin**

The new last rider-leg gets a new seed. Earlier rider-legs stay frozen.

**Recalc / fuel / profile / Allow Unknown on a stage**

- Same endpoints, rider did not move a pin and did not ask for another line: **keep the seed** (reproducible).
- Profile/Allow edit on a visible Point/F stage: existing stage-ownership law; do not mint a seed for untouched stages.

**Saved ride / Start Navigation / offline**

Replay stored geometry and stored seeds. Do not reshuffle under a locked itinerary.

**Optional rider control**

A visible “another line” on a Dirt/Balanced rider-leg mints a new seed for that leg only and rebuilds it. Not required for From Here (every new map selection already mints).

### 5.4 Fuel on vs fuel off when a rider pin moves

The fork is **whether automatic fuel is on**, not how many rider pins exist.

Do not treat F1 / F2 as rider waypoints. The rider cannot drag an F pin onto empty map; they replace it (§7). When a **rider** pin moves, every automatic F on the affected primary rider-legs is discarded and re-planned. The rider may then pick another pump from the new shortlist.

**Fuel off**

Rebuild only the primary rider-legs whose rider endpoints changed. New seed on each of those legs. Road only. No F pins.

Example: Points 1–2–3, move Point 2 → rebuild 1→2 and 2→3. A later 3→4 stays frozen.

**Fuel on**

Fuel is a forward chain. Moving Point 2 can invalidate the pump used to *reach* Point 2 and every pump after it, because arrival fuel at Point 2 and later rider pins has changed.

Rebuild **from the incoming primary rider-leg through the rest of the itinerary**:

- incoming (previous rider pin → moved pin), including a new fuel chain (Point 1 → F? → Point 2);
- outgoing (moved pin → next rider pin), including a new fuel chain (Point 2 → F? → Point 3);
- every later primary rider-leg, because tank state at Point 3 may no longer match the old F after Point 3.

New seed on every rebuilt primary rider-leg. Freeze only primary rider-legs **before** the incoming one (Point 1 and its inbound chain stay if Point 1 did not move).

Do not keep an old F just because it is still on the map. If the new line still makes that same packed station the right stop, the planner may select it again; that is a new proof, not a frozen pin.

**Insert on a painted Point/F stage, then place the pin**

Same fork. The painted stage belongs to a primary rider-leg. Splitting that rider-leg creates two primary rider-legs. Fuel off: rebuild those two only. Fuel on: rebuild from that split through the itinerary suffix. Outer legs before the split stay frozen.

**Speed**

Do not add a second “slow surgical reuse” path. Existing hop deadlines stay. When fuel is on, a correct forward fuel rebuild is the product; micro-freezing a later 3→4 after a Point 2 move is optional later, not this spec. When fuel is off, do not rebuild the whole trip from Point 1.

**Moved pin is Point 1**

The whole itinerary rebuilds (fuel on or off). From Here replacing B is already a whole-route rebuild (§5.3).

---

## 6. From Here vs Plan (interaction)

| Mode | How the destination changes | Seed |
| --- | --- | --- |
| From Here | Select a new map location. Pins are not dragged. | Always new. Whole route is new. |
| Plan | Move a rider pin, insert on a leg, or append. | Fuel off: new seed on rider-legs whose rider endpoints changed. Fuel on: new seed from that incoming rider-leg through the itinerary suffix (§5.4). |

From Here → Plan preserves the built itinerary, including its seeds.

---

## 7. Choose another pump (Plan)

This is rider-visible law. It already exists in the itinerary model (`fuelStopOverrides`, `validFuelTargets`) and as “Choose another pump” on the expanded Point/F row. Riders have not been seeing a clear **tap the F pin → pick another packed station** flow. Restore that as a first-class map action.

Required behaviour:

1. Tap the F pin (or the sheet action) enters replacement mode.
2. Only **graph-valid, forward, in-range** alternatives the planner already retained are highlighted (existing shortlist; public cap remains six).
3. The currently chosen F is obvious; the others are the ones the system did not pick.
4. Tap an alternative: that station becomes the fuel waypoint; rebuild from the preceding anchor **forward** (existing suffix rebuild). Mint a **new seed** for the affected rider-leg suffix because the hops changed.
5. Upstream rider-legs and already-passed fuel waypoints stay frozen.
6. Cancel / tap the same F again exits replacement without changing the route.
7. The F pin is not a free-drag onto arbitrary map. Drop/snap is only onto a highlighted valid station.

If `validFuelTargets` is empty on a hop that had other legal pumps, that is a planner defect in this work: the retained shortlist must actually be present for replacement. Do not fake candidates that fail range or continuation proof.

---

## 8. Profile on cross-province rides

Automatic Clean-first may still run **backstage** for fuel/connectivity on a true province/state crossing or ≥1,000 km (existing SoT). The **visible** Point/F hops must use the profile the rider selected (Dirt/Balanced/Clean). Clean-first must not become the painted ride when the rider asked for Dirt.

---

## 9. Files Codex is expected to touch

Behaviour (same commit, JS + Swift):

- `scripts/pack-fabric/routing/lib/hop-search.js`
- `scripts/pack-fabric/routing/lib/find-path-v2.js`
- `scripts/pack-fabric/routing/lib/profile-costs.js` (only if compass/away-tax must follow remaining road km)
- `scripts/pack-fabric/routing/lib/router.js`
- `Dirt/Routing/HopSearchPolicy.swift`
- `Dirt/Routing/OnDevice/OnDeviceRouter.swift`
- `Dirt/Routing/OnDevice/OnDeviceProfileCosts.swift` (same caveat)
- `Dirt/Features/RoutePlanning/Itinerary/RiderItinerary.swift` (per-leg `routeSeed`)
- `Dirt/Features/RoutePlanning/Itinerary/ItineraryBuilder.swift`
- `Dirt/Features/RoutePlanning/Itinerary/ItineraryReducer.swift`
- `Dirt/Features/RoutePlanning/RoutePlannerModel.swift` (From Here seed mint; F-pin replacement entry)
- `Dirt/Map/MapLibreMapView.swift` (F tap enters replacement without a hidden second tap)

Documentation (same change set):

- The files in §2
- This spec remains the implementation brief until SoT is updated after White

Tests (minimum):

- Halifax → Bathurst (or Halifax → Aulac door) Dirt: does not commit to the Minas north-shore dead-end before Truro.
- Same From Here endpoints, two successive destination selections: different `routeSeed`, different geometry allowed, neither retraces.
- Same seed replay: identical JS and Swift geometry.
- Plan, fuel off: move Point 2 of 3 → 1→2 and 2→3 rebuild; 3→4 if present unchanged. No F pins.
- Plan, fuel on: move Point 2 on Point 1 → F → Point 2 → F → Point 3 → rebuild from the first rider-leg into Point 2 through the suffix; old F pins on that suffix are re-proved, not dragged; rider-legs before Point 1’s outbound stay frozen.
- Plan: insert on a middle painted stage → both new halves new seeds; legs before the split frozen; fuel on continues the suffix.
- F pin replacement: select a retained alternate; upstream geometry unchanged; suffix rebuilt.
- Impassable reroute: around toward B, not back along the completed track, unless that is the only legal road.
- Clean: two searches with different seeds and same endpoints still match (no dirt shuffle).

---

## 10. Freeze and release

This reopens routing search law. It is not a pack rebuild.

1. Implement JS + Swift lockstep.
2. Deploy matching DEV live (`pack-fabric.vercel.app`) and an iOS DEV build.
3. White physical pass: From Here variety, Plan pin move/insert, F replacement, Halifax–NB water trap, no retrace.
4. Update `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md` and a new freeze record.
5. Then production live + production app together.

Do not ship live search without the matching client, or the phone without the matching live service.

---

## 11. Explicit non-goals (repeat)

- One compiled engine / WASM / JavaScriptCore unification.
- Walling oceans, lakes, or bays as urban-core boxes.
- Random fuel tourism.
- Reshuffling a saved or in-navigation itinerary.
- A language model or any cloud “AI router” in this change.
- Extra corridor-width ladders, a fourth profile, per-bay special cases, scenic heatmaps, or popularity scoring.
- Making “another line” a required control. From Here already mints a new seed on every new map selection.

---

## 12. Perfection, speed, and what not to invent

This spec is meant to be the last structural rewrite of search law. Codex implements it, White accepts it, then freeze. Do not use this pass to start another algorithm.

The product is the **ride between the pins**. Pins are anchors. Dirt, remaining-road compass, no retrace, and seeded forward alternatives are how that ride stays an adventure. Allow Unknown remains the rider control for more unknown fabric. Do not invent a new “fun” score.

### Speed (required method, not a new product)

Variety must not mean two or three full Dirt searches in a row. That would be slower than today.

1. One cheap **land-path** (distance A* already exists) so the compass knows remaining road km and the band sits on land, not on the airplane line.
2. One Dirt/Balanced hunt **inside that band** that keeps two or three geometrically different forward paths as it goes. The seed picks among those. Do not run the old crow-flies width ladder (60 / 120 / 180 km…) as a second product.
3. Fuel stays **foundation-first**: prove the chosen road line, then place or partition pumps on it. Do not profile-search every candidate pump.
4. Clean-first, if it runs, stays backstage and must not add a rider-visible extra wait for a pavement line they did not ask to see.

Existing 20-second live windows and hop caps stay. Faster is better; a timeout is still a timeout, never a fake no-road.

### Same laws in navigation

Obstruction reroute and offline recovery use this compass and no-retrace law. They mint a search because avoid-edges changed; they do not mint a vacation. They go around toward the next pin.

### Honest dirt

Keep the existing known-dirt vs unknown-surface distinction and the journey-quality labels (ready vs degraded). If the sheet says 100% dirt, it must be known unpaved, not unknown painted as adventure. Do not add a new quality contract in this spec.

### AI — later, and not as the router

A model cannot invent motorcycle-legal roads, cannot run on the downloaded graph in airplane mode, cannot lockstep JS and Swift, and cannot replay a seed. Putting one in the live 20-second window is slow, costly per request, and will hallucinate tracks that are not in the pack.

The seeded 2–3 **already legal** dirt lines are the creativity. If AI is ever used, it is a later, optional caption or ranking of those finished lines — never the pathfinder, never this spec.

### Owner acceptance clarifications — 2026-09-07

- The sealed DEV target is `fabric-v4-20260907-01`; no pack rebuild, mutation,
  upload, restamp, V3 fallback, runtime OSM call, production change, or physical
  phone install belongs to automated qualification.
- Planned routes have zero general retrace. Only explicit impassable recovery
  to the first usable junction and unavoidable departure from a true
  single-access endpoint may reopen ridden road.
- A fuel stop uses real packed, directionally legal geometry. Separate one-way
  entrance and exit roads are valid. Synthetic connectors, illegal U-turns,
  and substantial fuel-only out-and-backs are not; the forecourt allowance is
  200 m.
- Multi-stop foundation planning proves the mathematically minimum feasible
  stop count, first-tank/full-tank limits, and destination reserve. It stays
  inside the owning rider leg. Profile or Allow Unknown edits do not rewrite
  later primary rider legs.
- The 20-second direct and 30-second fuel windows are hard maxima, never target
  waits. Resource exhaustion is an honest incomplete result, not permission to
  return a paved-heavy Dirt success.
- The 55% known-Dirt requirement is a regression floor. Dirt continues to seek
  the highest known-Dirt route inside legal access, no-retrace, fuel, and 1.5×
  coherent-distance constraints.

### After White

Update SoT, cut a freeze, stop. Garnish after that is how this algorithm gets rewritten again.
