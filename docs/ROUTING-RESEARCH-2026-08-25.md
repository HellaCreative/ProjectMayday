# DIRT — Routing Search Foundation (research + how to build it)

Research into how the production routing engines (Google/Bing, OSRM, Valhalla, GraphHopper,
Microsoft CRP) actually build route search, and how to adapt that foundation to Dirt's needs
(adventure/dirt-biased, avoid towns unless forced, respect chokepoints like the Canso
Causeway). Written to be handed to an IDE agent (Cursor/Codex/Claude) as a build spec.

---

## 1. THE big finding: two layers, always separated

Every serious routing engine splits routing into **two independent layers**. This is the
"clean code, bulletproof foundation" you're after — and it's the thing Dirt currently
*blends* (our cost weights are tangled inside the search in `find-path-v2.js`).

```
   ┌──────────────────────────────────────────────────────────────┐
   │  LAYER 1 — THE SEARCH ALGORITHM  (generic, rider-agnostic)     │
   │  Finds the minimum-cost path fast. Knows nothing about "dirt". │
   │  Dijkstra → A* → bidirectional → Contraction Hierarchies / CRP │
   └──────────────────────────────────────────────────────────────┘
                              ▲  asks "what does this edge cost?"
                              │
   ┌──────────────────────────────────────────────────────────────┐
   │  LAYER 2 — THE COSTING MODEL  (this is where "Dirt" lives)     │
   │  A pluggable function: edge attributes → cost. Swappable per   │
   │  rider/profile. Clean=pavement, Dirt=dirt-bias, avoid towns…   │
   └──────────────────────────────────────────────────────────────┘
                              ▲  calls the pairwise search repeatedly
                              │
   ┌──────────────────────────────────────────────────────────────┐
   │  LAYER 3 — ROUTE ORCHESTRATION  (the product: a full ride)     │
   │  Sequences user WAYPOINTS into LEGS, inserts FUEL stops under  │
   │  the tank-range constraint, assembles the final multi-leg      │
   │  route. Calls Layers 1+2 for each leg. (§5b)                   │
   └──────────────────────────────────────────────────────────────┘
```
Layers 1–2 solve one A→B. **Layer 3 is Dirt's actual product** — a full ride with multiple
pins and fuel — and it just orchestrates repeated Layer-1+2 searches. Keeping it a distinct
layer is what makes waypoints and fuel clean instead of tangled into the search (where they
partly are today).

- **Valhalla** names these explicitly: *Thor* (the search) and *Sif* (the costing). Costing
  is a **runtime parameter, not baked into the graph** — that's why one dataset serves cars,
  bikes, trucks, pedestrians.
- **GraphHopper** does the same with a fast search + a **declarative "custom model"** cost spec.
- **Microsoft CRP** (the engine behind Bing) formalizes it: metric-INDEPENDENT preprocessing
  (the graph topology), then cheap metric CUSTOMIZATION (the cost function), then fast queries.

**Rule #1 for Dirt: make the search know nothing about surface, towns, or profiles. All of
that goes in a swappable costing model.** This alone fixes most of our tangle.

## 2. The search-algorithm ladder (Layer 1)

| Algorithm | Idea | Preprocessing | Query speed | Weights fixed at build? |
|---|---|---|---|---|
| **Dijkstra** | expand evenly in all directions | none | slow (whole graph) | no (but slow) |
| **A\*** | steer toward the goal with a heuristic (straight-line distance) | none | faster | no |
| **Bidirectional** | search from BOTH ends, meet in the middle | none | ~2× faster than one-way | no |
| **ALT** | A\* + precomputed "landmarks" for a tighter heuristic | moderate | fast | **yes** (metric) |
| **Contraction Hierarchies (CH)** — OSRM | precompute "shortcut" edges by node importance | heavy | ~100ms across a continent | **YES — baked** |
| **Customizable CH / CRP** — Bing, GraphHopper | split preprocessing (topology) from customization (costs) | heavy topology, cheap re-cost | fast | **NO — costs swappable in seconds** |
| **Valhalla dynamic** | tiled road hierarchy, costs evaluated at query time | tiling only | fast (hierarchical) | **NO — costs at query time** |

**The trap to avoid:** plain **Contraction Hierarchies bake the edge weights at build time.**
It's the fastest, and it's what OSRM uses — but if the cost function changes (which is Dirt's
whole point: dirt-bias, avoid-motorway toggle, per-rider tank), you'd have to re-preprocess the
entire graph. **So Dirt must NOT use plain CH.** The engines that support custom costs cheaply
are **CRP / Customizable CH** and **Valhalla-style dynamic costing.**

**Recommendation for Dirt (in order of effort):**
1. **Now / cheap win:** replace the current corridor-hack Dijkstra with **bidirectional A\*.**
   Our "corridors" (60/120 km bands) are a crude, buggy stand-in for what A\*'s goal-directed
   heuristic does properly — and A\* naturally stops the province-wide sprawl without a hand-
   tuned corridor. This is the single biggest clean-up, and it keeps costs fully dynamic.
2. **Later / scale:** if per-query speed on big provinces (or cross-province) becomes the
   bottleneck, adopt **Customizable Contraction Hierarchies (CCH)** — metric-independent
   preprocessing of the pack (done once at pack-build), plus a cheap "customization" pass when
   the rider's cost model changes. This is exactly the NS→BC scaling story.

## 3. The costing model (Layer 2) — where "Dirt" lives

Valhalla's `DynamicCost` base class is the clean interface. Every profile (Clean/Balanced/Dirt)
is one implementation of it. **Adopt this interface for both Dirt engines:**

```
interface RiderCost {
  allowedNode(node)                  → bool   // barriers, access at a junction
  allowedEdge(edge, fromEdge)        → bool   // legal for this vehicle? (turn restrictions,
                                              // access) — NEVER "surface" (see §5)
  edgeCost(edge)                     → number // the real per-edge cost = f(distance, surface,
                                              // road-class, area, structure…)
  transitionCost(fromEdge, toEdge)   → number // turn/junction penalty (sharp turns, class
                                              // changes) — cheap, big quality win
}
```

- **`edgeCost` is the only place surface/road-class/dirt-bias multipliers live.** Our
  `road-tier.js`, `surface-family.js`, and `profile-costs.js` tables ARE this function — they
  just need to be pulled OUT of the search and behind this interface, one shared implementation
  driving both JS and Swift.
- **`transitionCost` (turn costs) is a free quality win Dirt doesn't fully use.** Valhalla notes
  adding turn penalties "produces simpler paths with fewer maneuvers" — fewer silly zig-zags,
  exactly the meander problem we keep fighting.

## 4. Expressing Dirt's rules DECLARATIVELY (this is how you hand it to an IDE)

The cleanest way to *communicate* a costing model — to a teammate OR to an IDE agent — is
GraphHopper's **declarative custom-model** format: a list of `if <condition> then multiply_by
<factor>` rules over edge attributes. It's readable, reviewable, and unambiguous. Dirt should
adopt this as its costing spec (shared JSON, both engines read it — same pattern as our
`enumsJson` maps today).

**Convention (fixed):** these are **COST multipliers**, matching Dirt's existing cost tables.
`multiply_by > 1` = **more expensive → avoid**; `< 1` = **cheaper → prefer**; `1` = neutral.
**Never `0`** — a zero/near-zero multiplier is a hard exclusion, which is forbidden (§5). To
make something "last resort," use a large *finite* penalty. Per-edge multipliers are `edgeCost`;
lump-sum entry/turn penalties are `transitionCost` (`add`, not multiply).

**Dirt profiles as declarative rules (illustrative — numbers mirror our current tables):**

```jsonc
// DIRT profile  (cost multipliers: >1 avoid, <1 prefer)
{
  "edgeCost": [
    { "if": "surface_family == PAVED",   "multiply_by": 16   },  // pavement expensive → avoided
    { "if": "surface_family == GRAVEL",  "multiply_by": 0.16 },  // gravel is the target
    { "if": "surface_family == LOOSE",   "multiply_by": 0.9  },
    { "if": "road_class == MOTORWAY",    "multiply_by": 70   },  // last-resort (finite, not 0)
    { "if": "road_class == TRUNK",       "multiply_by": 16   },
    { "if": "in_town_core",              "multiply_by": 6    }   // penalize core, bounded (§4b-C)
  ],
  "areas": { "town_core": { /* GeoJSON urban cores, pack-derived */ } }
}
```
```jsonc
// CLEAN profile  (cost multipliers + a highway ENTRY penalty)
{
  "edgeCost": [
    { "if": "surface_family != PAVED",   "multiply_by": 14   },  // pavement-first (loose = 90)
    { "if": "road_class == COLLECTOR",   "multiply_by": 0.86 },  // rural backbone (preferred)
    { "if": "road_class == LOCAL_PAVED", "multiply_by": 0.92 },
    { "if": "road_class == ARTERIAL",    "multiply_by": 1.4  },  // connector
    { "if": "road_class == TRUNK",       "multiply_by": 16   },  // last-resort (finite)
    { "if": "road_class == MOTORWAY",    "multiply_by": 70   },  // last-resort (finite)
    { "if": "road_class == RESIDENTIAL && !is_endpoint_edge", "multiply_by": 1000 } // dest-only, huge but FINITE
  ],
  "transitionCost": [
    { "if": "entering road_class in {TRUNK, MOTORWAY}", "add": 300 }  // §4b-A lump-sum ENTRY toll
  ]
}
```

This IS the spec to hand an IDE: *"here are the edge attributes, here is the rule grammar,
here are the three profiles as rule lists — implement `edgeCost` to evaluate these rules, and
make both engines read the same rule JSON."* Unambiguous, testable, and diff-able when a rule
changes.

## 4b. The hard part of costing: why avoid-highway and avoid-city actually fail (and the fixes)

A per-km multiplier is NOT enough to make Clean behave. This section is the "higher level of
sophistication" — it's what separates a toy avoid-switch from Google's. It directly targets the
two bugs Rick is fighting: highway-hopping and the through-city-or-200-miles avoid-city problem.

### Fix A — road-class ENTRY / TRANSITION penalties (stops highway-hopping)
A smooth per-km penalty can never stop brief highway hops: a 500 m stretch of highway that
shortcuts a 3 km rural wiggle is still *locally* cheaper, so the router keeps dipping onto it.
The industry fix (PTV, Waze, Valhalla all do this): a **lump-sum cost for ENTERING a road
class**, applied in `transitionCost` when the road class *changes upward* (local/arterial →
trunk/motorway). Now any highway use — even 200 m — pays a fixed toll, so a brief hop only wins
if it saves a lot. Add two targeted guards Waze uses:
- **Anti-rejoin:** extra penalty for "leave highway X → immediately rejoin highway X" (the exact
  jitter you're seeing).
- **Anti-loopy:** penalize reusing a junction/node twice (also helps the fuel-leg backtrack).

Our Clean cost is pure per-km (motorway 70×, trunk 16×) with **no entry penalty** — that single
omission is why it jumps in and out. Add the entry/transition penalty and the hopping stops.

### Fix B — treat Clean as a road-HIERARCHY profile, not a per-km tax (stays on rural roads)
Road networks have levels: **local** (all roads), **arterial** (drops residential/service),
**highway** (motorway/trunk/primary only). Valhalla's **hierarchy limits** stop "divebombs"
where a route needlessly rides high-class roads; **bikes route on the local level only and never
transition to the highway tier.** That is exactly what Clean-on-rural-pavement wants:
- Model Clean as a **"stay-low" profile**: prefer the arterial/local paved network; the highway
  level is a **last-resort connector**, entered only when the lower network can't complete the
  route (the causeway, a river with one bridge). This is more reliable than tuning per-km
  numbers, because it's a *structural* preference, not a cost race.
- Your **"allow highways" switch** then has a crisp meaning: OFF = Clean stays on the low
  hierarchy (highway tier is last-resort only); ON = the highway tier is a normal option. Much
  cleaner than a graded multiplier, and it matches how Google's "avoid highways" actually feels.
- Note the industry moved past the blunt on/off "avoid" switch to a **graded cost** (e.g. a
  −99…block scale): −99 = strongly prefer this class, 0 = neutral, block = last-resort. Clean's
  "allow highways" can stay a simple toggle in the UI while mapping internally to
  last-resort-vs-normal on the highway tier.

### Fix C — avoid-city needs a CORE-vs-RING model + a bounded penalty (not through, not 200 mi)
The binary failure (dives through downtown OR detours 200 mi) is an **un-calibrated soft
penalty**: too weak and the city is cheaper to cross; too strong and any detour beats it. Two
pieces fix it:
- **Distinguish the urban CORE from the ring.** Penalize the **core** (downtown/local city
  streets) heavily, but keep the **arterial ring / bypass** around the core at a low penalty. The
  route then naturally takes the bypass — through-adjacent, not through-downtown, and not a
  province-long detour. (This is why "avoid cities" as one flat polygon penalty misbehaves: it
  can't tell the bypass from Main Street.)
- **Bound the avoidance cost.** The city penalty should be a *bounded* extra (a ceiling), so the
  router will accept a modest bypass but never trade it for a 200 km reroute. Uncapped per-km
  penalties are what produce the absurd detours.
- **Never hard-exclude the city** (you may need to *reach* a destination inside it) — see §5.
- Pack-derived city cores + ring definitions replace the hardcoded `METRO_CORE_WALL` boxes.

Together these three are the difference between "Clean sort of avoids highways/cities" and
"Clean confidently stays on rural pavement and slips past towns on the bypass." They live
entirely in Layer 2 (`edgeCost` + `transitionCost`) — no search change needed.

## 5. Avoid towns, and the Canso Causeway — the two things you named

Both are solved by **one principle the whole industry agrees on: penalize, NEVER hard-exclude
(except for genuine illegality).**

- **Avoid towns/cities:** define urban cores as **geographic polygons** and add an area rule
  (`in_town → multiply_by 0.15`). GraphHopper's `areas` + `in_<area>` boolean is exactly this.
  It supersedes our hardcoded `METRO_CORE_WALL` boxes with real, pack-derived town polygons.
  Because it's a *soft* penalty, a route that genuinely must pass near/through a city still can
  — it just pays for it. GraphHopper even supports "avoid X *unless* inside area Y"
  (`road_class == MOTORWAY && in_near_town == false`), which is literally your "avoid highways
  unless the route has to get close to that city."

- **The Canso Causeway (chokepoints):** you do **nothing special.** The causeway is the only
  edge connecting the mainland to Cape Breton, so *any* path to Cape Breton must traverse it —
  the graph's connectivity forces it automatically. The ONLY thing you must never do is
  **hard-exclude** edges (delete them from the search). If Clean deletes "non-preferred" roads,
  or Dirt deletes pavement, you can sever the one causeway/bridge and get "no route." The
  industry rule (and ours going forward): **surface/road-class/town are COSTS in `edgeCost`,
  never eligibility filters in `allowedEdge`.** `allowedEdge` is ONLY for genuine illegality
  (private land, turn restrictions, vehicle bans). This is also the root of our "no route"
  failures and the re-route-behind bug — soft-cost everything, filter almost nothing.

## 5b. Layer 3 — orchestration: waypoints, legs, and fuel

Layers 1–2 route one A→B. Dirt's real product is a **multi-leg ride with fuel**. The industry
builds this as a thin orchestration layer that calls the pairwise search repeatedly. Three
concepts, each with a named industry solution:

### Waypoints and legs
- A route through an **ordered list of user pins** = a sequence of **legs**, one pairwise
  Layer-1+2 search between each consecutive pair (origin → wp1 → wp2 → … → dest). Dirt places
  pins in rider order (no need for TSP order-optimization — that's a different product).
- **Waypoint TYPE is the key detail (this fixes our backtrack bug).** Valhalla distinguishes:
  - **`break`** — a real stop: the leg can start fresh, a U-turn is allowed there.
  - **`through` / `via`** — a pass-through: **U-turns are penalized; the route must continue in
    the same direction through the point.**
  Our fuel stops and mid-route pins should be **through-points**, so the route can't reverse
  direction at an anchor. This is precisely the fix for the fuel-leg backtrack and the
  re-route-behind bug — both are anchors being treated as free `break` points instead of
  forward-continuing `through` points. Implement it as a **U-turn / reverse-direction penalty
  in `transitionCost`** at anchor edges.
- **Snapping:** each pin snaps to the nearest routable edge; keep the snap radius bounded
  (Valhalla/OSRM cap it) so a pin in the woods doesn't grab a road 5 km away.

### Fuel — Dirt uses FORWARD fuel-anchor construction, NOT fixed-route-then-insert
**Correction (this supersedes the earlier FRVRP framing).** The classic model is the
Fixed-Route Vehicle Refueling Problem / Gas Station Problem (Khuller et al., ACM 2011): build
the route first, then pick refuel points *on* it. **Dirt deliberately rejected that** — it's
exactly what caused the 20 km-off-the-road-and-20 km-back-down-the-same-path detour, because a
station off the fixed line can only be reached as a spur. Dirt's approved model instead makes
**fuel a first-class constraint inside the forward search:**
- The next rider waypoint is a **gravity source**. From the current anchor, the search advances
  toward that gravity within a bounded **~45° fan** (a forward cone, not the whole graph).
- A fuel stop is chosen as a **forward anchor** that *advances* toward the waypoint (landed in
  the **50–80% comfort window**), and the ride **continues from the fuel anchor** — the route is
  never a fixed line with a spur hung off it. Each leg is a fresh Layer-1+2 search inside the
  fan; fuel and range shape the route as it's built.
- This is closer to a **constrained-shortest-path with refueling** than to FRVRP, and it is
  *better* for Dirt precisely because fuel changes the route. Keep it.
- Khuller's greedy fill rule ("fill only enough to reach the next stop unless it's pricier") and
  the EV "insert-stops-only-when-needed, search near the partial-range point" pattern still
  inform the *comfort-window* choice within the fan — but the route is built forward, not fixed.
- The `through`-waypoint / no-U-turn penalty (below) still applies so a leg can't reverse at the
  fuel anchor.

### Range legs vs route legs (keep them distinct)
- **Route legs** = segments between the rider's chosen pins (product intent).
- **Range/fuel legs** = sub-segments imposed by the tank constraint, inserted *within* a route
  leg when it's longer than the usable range.
- Assemble as: for each route leg, run FRVRP to insert fuel anchors, producing a chain of range
  legs; concatenate. Report both to the rider (our "F2 → F3" fuel legs are the range legs).

**Net for Layer 3:** a small orchestrator that (1) walks the ordered pins as legs, (2) treats
fuel stops and mid-route pins as forward-only `through` anchors, (3) builds each leg FORWARD
toward the next waypoint's gravity within the ~45° fan, placing fuel anchors in the comfort
window as it goes (NOT fixed-route-then-insert), (4) concatenates. It never re-implements search
or costing — it only calls Layers 1–2. Our fuel code already does the forward-anchor
construction; the missing pieces are the **through-waypoint U-turn penalty** (fixes backtrack)
and cleanly separating **range legs from route legs**.

## 6. How this maps onto Dirt today (the migration)

| Industry pattern | Dirt today | Move to |
|---|---|---|
| Search separated from costing | costs tangled in `find-path-v2.js` | pull costs behind a `RiderCost.edgeCost` interface |
| Goal-directed search | corridor bands (60/120 km) hand-tuned, buggy | **bidirectional A\*** (heuristic replaces corridors) |
| Turn costs | barely used | add `transitionCost` — kills zig-zag meander |
| Highway-hopping (Clean) | pure per-km penalty, no entry cost | add road-class ENTRY penalty + anti-rejoin/anti-loopy (§4b-A) |
| Stay on rural roads (Clean) | per-km tier tax, jumps tiers | model Clean as a "stay-low" HIERARCHY profile; highway tier = last resort (§4b-B) |
| "Allow highways" switch | graded multiplier, fiddly | toggle = highway tier normal vs last-resort-only (§4b-B) |
| Avoid-city (through or 200 mi) | flat polygon penalty, uncalibrated | CORE-vs-RING model + bounded penalty (§4b-C) |
| Declarative cost spec | JS/Swift cost tables, hand-mirrored | shared **rule-JSON** both engines read (like `enumsJson`) |
| Penalize, never exclude | some hard-exclusion still present | surface/class/town = COST only; `allowedEdge` = legality only |
| Town avoidance | hardcoded `METRO_CORE_WALL` boxes | pack-derived polygons + `in_town` area rules |
| Custom cost, fast | dynamic (good — keep it) | later: CCH preprocessing for scale |
| Waypoints (Layer 3) | ordered legs (good) | add `through` vs `break` waypoint types + U-turn penalty |
| Fuel anchors reverse-route | fuel leg backtracks / re-route goes behind | make fuel/mid-route anchors `through` points (no U-turn) |
| Fuel model | FORWARD anchor + gravity-fan + comfort window (good) | KEEP — do NOT revert to fixed-route-then-insert (FRVRP); that causes the off-and-back spur |
| Range vs route legs | partly blended | keep distinct: route legs (pins) vs range legs (fuel sub-splits) |

**The single highest-leverage refactor:** separate Layer 1 from Layer 2 and switch the search
to **bidirectional A\*.** That gives you the "efficient, plots-fast, bulletproof foundation,"
and it makes the corridor/sprawl/meander bugs go away *by construction* instead of by tuning.

## 7. How to communicate this to an IDE agent

Hand the agent, in this order:
1. **The architecture rule (§1):** search and costing are separate; the search is
   rider-agnostic; all preference lives in a swappable costing model.
2. **The algorithm choice (§2):** bidirectional A\* now; NOT plain CH (weights would bake);
   CCH later for scale.
3. **The costing interface (§3):** `allowedNode / allowedEdge / edgeCost / transitionCost`.
4. **The declarative rule spec (§4):** the edge attributes, the `if/multiply_by` grammar, and
   the three profiles as rule lists — one shared JSON both engines read.
5. **The two invariants (§5):** penalize-never-exclude; `allowedEdge` is legality only.
6. **The orchestration layer (§5b):** waypoints as ordered legs; fuel = FRVRP on a fixed
   route (comfort window); fuel/mid-route anchors are forward-only `through` points (U-turn
   penalty) — this is the structural fix for the backtrack + re-route-behind bugs; keep range
   legs distinct from route legs. Layer 3 only calls Layers 1–2, never re-implements them.
7. **The migration table (§6)** as the task list.

That is a complete, unambiguous build brief. It tells the agent *what* to build, *which*
algorithm, *where* the rules go, and *how* to express them — with the exact failure modes
(baked CH, hard-exclusion) called out so it can't wander into them.

---

## Sources
- Valhalla dynamic costing (Thor/Sif, DynamicCost interface): valhalla.github.io/valhalla + Mapzen "Dynamic Costing via Sif"
- Microsoft Research — Customizable Route Planning (CRP), the Bing engine
- Contraction Hierarchies (Geisberger/Sanders/Schultes/Delling), KIT
- GraphHopper custom models + "areas" (declarative rule language)
- OSRM bidirectional Dijkstra + CH; GraphHopper CH/CCH/Landmarks + Custom Models
- "A Survey on Route Planning in Large Road Networks" (Allen Chou)
- Soft-penalty vs hard-exclusion: Nextmv "avoiding bridges/train tracks"; routing patents on block-vs-penalize
- Road-class entry/transition penalties + graded avoidance (not on/off): PTV "Street Penalties for Routing API"; Waze routing penalties (anti-rejoin, anti-loopy)
- Road hierarchy levels + hierarchy limits (stay-low profiles, no divebombs): Valhalla path-algorithm docs + Interline "Intro to Valhalla"
- Avoid-area calibration (bounded penalty, avoidance-area network effects): routing patents on avoidance-area network effects; Waze avoid heuristics
- Waypoint types (break vs through, U-turn control): Valhalla API reference + Stadia Maps "Getting the Best Routes"
- Fuel / refueling: Khuller, Malekian, Mestre — "To Fill or Not to Fill: The Gas Station Problem" (ACM 2011, UMD); Fixed-Route Vehicle Refueling Problem (FRVRP)
- EV charging-stop insertion under range constraint (Constrained Shortest Path): arXiv 2011.10400 + EV route-planning surveys
