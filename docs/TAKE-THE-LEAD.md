# Take the Lead

Updated: 2026-09-16. Owner: Richard "Rick" Smith.

You are picking up DIRT cold, on whatever platform Rick has spun you up in
(Claude, Cursor, Codex). This document exists so you start with what the last
agent knew instead of relearning it at Rick's expense. Read it end to end before
you touch code or answer a question about the product.

This is a working handbook, not a specification. It never overrides
`docs/ROUTING-SOURCE-OF-TRUTH.md`.

---

## 1. Authority, in order

1. **What Rick says in the current conversation.** It beats every document,
   including this one.
2. **`docs/ROUTING-SOURCE-OF-TRUTH.md` §5, "Owner contract: legs and waypoints".**
   Fifteen numbered rules in Rick's own words, plus the tests a change must pass.
   When any other sentence anywhere disagrees with §5, §5 wins.
3. **The rest of the source-of-truth document.** §2 is the rider's result and the
   riding styles; §8 is current state, reports and the backlog.
4. **This document,** for how to work, what the tools are, and what has already
   been tried and failed.
5. **Code comments last.** Several have been wrong or stale. Verify before
   trusting one.

Never create a second routing specification. If a rule changes, edit the
source-of-truth document in place and delete the rule it replaces.

---

## 2. Vision

DIRT is for dual-sport and adventure motorcyclists who ride to ride. The reason
they exist is the road itself: gravel, forestry roads, two-track, the long way
round. Every other routing product on the phone is built to end the journey
sooner. DIRT is built to make the journey worth taking.

The rider says where they are, roughly where they want to go, and what kind of
day they want. DIRT composes the ride between their points, offline, from packs
already on the phone, and hands them a route they would have been proud to plan
themselves with paper maps and local knowledge.

## 3. Mission

Make the best ride between the rider's points, on legal connected roads, every
time, on a phone, with no signal.

In practice that means:

- **The ride is the product.** Distance and time are consequences, not goals.
- **Offline is not a fallback.** Packs on the device are the primary source.
  Routing never depends on a server.
- **Honest surfaces.** Proven dirt, pavement and unknown access stay distinct
  facts. Never present unknown as proven, or a limitation as a success.
- **A different ride every time.** Asking again should offer another good day
  out, not the same canonical answer.
- **Long trips are normal.** Crossing provinces is a feature, not an error.

## 4. Ethos

How Rick wants this built, in his own terms:

- **Interest and quality of travel over efficiency.** "This is not about
  efficiency of travel, it is about interest and quality of travel."
- **Never trade the product for a number.** A faster build or a higher
  percentage is worthless if the ride got worse. A Dirt route that comes back
  near half pavement has failed as Dirt, not merely scored low.
- **Say what is true.** If a corridor cannot reach 70% dirt, say so and show the
  evidence. Do not massage a number, and do not quietly substitute a lesser
  route and call it done.
- **No silent fallbacks.** If the thing the rider asked for cannot be built,
  surface it. Fallbacks that look like success cost a full day of debugging once
  already.
- **One mechanism, not special cases.** Rider waypoints, generated waypoints and
  imported routes should be the same object travelling the same code path.
  Special cases are where the bugs lived.
- **Simplify by deletion.** When something is replaced, remove it. Dead
  alternatives left in place get re-entered by accident.
- **Measure before you believe.** Reproduce, then change. Every expensive
  mistake in this project came from acting on a plausible story.

## 5. The product, concretely

Every leg between two waypoints has its own style and is held to its target:

| Style | Target |
| --- | --- |
| Dirt | Strive for 100% dirt. Rick expects 70-80% where the legal network supports it. |
| Balanced | 50% dirt and 50% pavement on that leg. |
| Clean | 100% pavement, back roads, no highways. |

Supporting rules you will be judged against: no loops, no out-and-backs, no W
shapes at a waypoint, and re-ride a road only when truly necessary; dirt runs
under 1 km do not count and are not worth a detour; direction of travel follows
the roads, not the straight line; wander controls how far the ride may roam and
never decides whether fuel is found.

**Fuel is not part of route building.** Decided 15 September after a day of
failures. Routing never consults fuel range, reserve or pumps. Fuel returns
later as an advisory layer bundled with other points of interest. §5 of the
source of truth carries that design; it is parked until core routing is
accepted.

## 6. Aspirations

Where this is going, so you do not design something that blocks it:

- **Advisory fuel, then other points of interest.** Fuel first because running
  dry ends a ride; then camping and accommodation, food and water, sightseeing,
  repairs and tyres, rider services. One "what is near this route" index serves
  all of them, each opt-in.
- **Notification-and-action navigation.** While riding: "pump in 2 km, nothing
  for 68 km after it", a last-chance prompt when the tank cannot reach the next
  one, and "filled up?" to reset the range. Detour, then rejoin the route.
- **Loops and imported GPX as first-class rides,** both being one start point
  with the route returning to it.
- **Legs that appear as they are built,** so a rider watches a long trip grow
  rather than staring at a spinner.
- **Reshaping by hand:** drag any waypoint, rebuild only the legs either side.
- **Group rides, saved routes and navigation handoff** already exist in the app
  and must keep working as routing changes.
- **Android eventually.** Routing requirements live in the source-of-truth
  document for that reason; parity is not implied.

---

## 7. Working with Rick

These are not preferences; ignoring them wastes his money and his day.

- **He accepts work only after a phone build.** He opens the Xcode project in
  this checkout, scheme DIRT Dev, and rides the result. Probe numbers are how
  *you* check yourself before handing him something, never a substitute.
- **One thing at a time.** Implement, test, commit, show a before/after table,
  stop. Do not bundle steps.
- **Work in his checkout only:** `/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt`, branch
  `cursor/on-device-routing-speed-37c5`. No extra worktrees, no second Xcode
  project, no copies inside his tree. He has said so twice, with feeling.
- **Never stage `Dirt/Features/Groups/GroupsSheet.swift` or
  `Dirt/Routing/RoutingModels.swift`.** They are his own dirty edits.
- **Never use `-wmo` build flags.** It breaks clean Xcode builds. Tried,
  reverted.
- **No destructive git.** No force pushes, no resets, no discarding his work.
  Commit only the files you touched. Never fetch the GitHub remote into this
  checkout — it once grew `.git` from 95 MB to 7 GB. The full repository rules,
  remotes and push command are in the source of truth, §7 "Git: where the work
  lives"; read them before you run anything. Rick does not read Git, so say in
  plain words what a command will do before you propose it.
- **Keep messages short.** He reads on a phone, often tired. Lead with the
  finding. Tables beat paragraphs.
- **Do not hand him a prompt mid-conversation.** When he is thinking a design
  through, talk it through. He will ask for the prompt, and then he wants it
  complete and self-contained.
- **Do not claim something works because a report says so.** Reproduce it.

---

## 8. How to write code here

**Language and shape.** Swift 6, strict concurrency. The engine
(`Packages/DirtRoutingEngine`) is a pure, testable library: no UI, no app types,
no I/O beyond reading packs. The app is a thin adapter over it
(`Dirt/Routing/NativeRoutingAdapter.swift`). Keep that boundary. If routing
logic is leaking into a SwiftUI file, it is in the wrong place.

**House style, as the codebase actually reads.**

- Dense but deliberate. Short functions are not a goal; clarity is.
- Comments explain **why**, never what. The good ones cite a rule ("§5 rule 3")
  or the failure they prevent. Delete a comment when its reason dies.
- Name things for the rider's world: `ride`, `leg`, `waypoint`, `wander`,
  `dirt`. Not `segment2`, not `helper`, not `manager` unless it manages
  something.
- Constants live once, named, near their use, with the reason for the value.
- No speculative abstraction, no options nobody sets, no compatibility shims.
  If you replace a mechanism, delete the old one in the same commit.
- Prefer making the general case handle the special one over adding a branch.

**Changing routing behaviour.**

- Read `docs/ROUTING-SOURCE-OF-TRUTH.md` §5 first and cite the rule you are
  serving in the commit message.
- Instrument before you tune. Counters and a one-line summary beat a guess; that
  is how the fuel and dirt problems were finally found.
- Keep diagnostics free of routing decisions: a counter may record, never steer.
- If a change is meant to be performance-only, prove routes did not move
  (`edgeIDsSHA256` per route, twelve non-fuel matrix cases IDENTICAL). If it is
  meant to change routes, show the before/after table and get Rick's agreement.

**Commits.** One step per commit. Subject in the imperative, body explaining the
failure it fixes and the evidence. Stage only the files you touched. End with
the attribution line the platform asks you for.

## 9. Clean code, specifically

- Delete the replaced thing. `FuelPlanner` is out of the routing path; distance
  breaks are gone; do not leave a second way in.
- One authority per fact. Dirt percentage is computed in `RouteQuality`; the app
  presents it. Two implementations of the same number will disagree eventually,
  and the app's fallback path once reported 0% dirt on a 63% ride.
- Fail loudly. An empty result, a resource limit or a missing pack must reach
  the rider as a clear message, never as a quietly substituted route.
- Guard invariants where they are established, not everywhere downstream.
- Long functions that mirror one algorithm are fine. Splitting the search into
  fragments that hide the cost model is not.
- Tests belong with the rule they protect, named for the behaviour, not the
  function.

## 10. How to test

**Engine tests** (fast, no packs):

```
cd Packages/DirtRoutingEngine && swift test      # 56 tests as of 2026-09-16
```

Every code commit must pass them first.

**The probe** is how you check real routes without a phone. Build it in a
scratch directory, never inside Rick's checkout, so you leave no artifacts:

```
rsync -a --exclude .build /Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/Packages/DirtRoutingEngine/ /tmp/engine/
cd /tmp/engine && swift build -c release --product dirt-routing-probe
dirt-routing-probe PACKS REGIONS FROM_LON FROM_LAT TO_LON TO_LAT STYLE SECONDS [SEED [ZOOM [FUEL_USABLE [FUEL_FIRST]]]]
```

Packs:

| Directory | Contents |
| --- | --- |
| `.build/greenfield-routing-evidence/packs` | `ns` and `nb` only. Most contract routes. |
| `.build/restriction-release-copy/partial-staging/packs` | Full set including `qc`, `on` and US states. Needed for three-pack and staged routes. |

Environment: `DIRT_PROBE_COMPACT=1`, `DIRT_ALLOW_UNKNOWN=1`, `DIRT_WANDER=0..1`,
`DIRT_DIRT_PAVEMENT_AWAY=<n>`, `DIRT_PRIOR_EDGES=<file>`, `DIRT_ARRIVAL_EDGE=<id>`.

Receipt fields worth knowing:

| Field | Meaning |
| --- | --- |
| `knownDirtPercent` | Proven dirt as a share of distance. The number Rick judges. |
| `minimumSectionDirtPercent` | Dirt in the weakest quarter. Catches a ride that is all dirt at one end. |
| `longestPavedRunMeters` | Longest unbroken pavement. 45 km inside a Dirt ride is a smell. |
| `reriddenMeters` | Road ridden more than once. Rule 3 stated directly. Should be near zero. |
| `returnMeters` | Metres back within 2 km of somewhere passed at least 10 km of riding earlier. Catches loops on different roads. |
| `backwardMeters` | **Chord diagnostic only.** Progress along the straight start-to-finish line; riding around a bay scores as "backward". Never call this backtracking. |
| `edgeIDsSHA256` | Route identity. Same hash means byte-identical ride. |
| `searchSummary` | Candidate log, e.g. `profile/59%/602257m,road/65%/668009m,shape:0->0`. |

**The matrix**: `Packages/DirtRoutingEngine/Scripts/speed-matrix.sh PROBE OUTDIR`
runs sixteen cases; `compare-receipts.py BEFORE AFTER` reports IDENTICAL, TIMED
or DIFFERENT. A performance-only change leaves the twelve non-fuel cases
IDENTICAL.

**The contract routes** (from Porters Lake, `-63.340263 44.764835`): Cape Breton
`-60.477673 46.931127`, Yarmouth `-66.09856 43.84097`, north New Brunswick
`-67.02568 47.31730` with `ns,nb`. Long staged route: Gaspé `-64.273363
48.922934` with `ns,nb,qc`. Run each in Dirt, Balanced and Clean.

**Reading Rick's phone logs.** He exports `dirt-app-debug-*.txt` from the app and
sends it. The lines that matter: `build start` (profile, allowUnknown, zoom),
`pack route` / `pack fuel` (elapsed, prepare breakdown, searches, pops,
peakLabels, footprint, candidates), `build leg` (per-leg metres and dirt %),
`camera build leg`, and any `failed` / `limit` / `gap` line. Everything else is
map tiles, StoreKit and network noise.

## 11. How to hand work to Rick

He should be able to judge it in thirty seconds, on a phone.

1. **What changed,** in one or two sentences, naming the rule it serves.
2. **The table.** Per route and style: km, dirt %, the style's target
   (100 / 50 / 0), seconds, peak memory, and `reriddenMeters` when shape is in
   question. For multi-leg rides, per leg.
3. **What did not move:** matrix IDENTICAL count, or the edge hashes.
4. **The commit hash.**
5. **What you could not finish, and why,** with the evidence. Never hide it.
6. **Then stop** and ask him to build DIRT Dev on his phone. Do not start the
   next step.

If he is asleep or away and has authorised a long run, keep the same format and
append a dated report to §8 of the source-of-truth document, with a backlog
entry for everything you noticed but did not fix.

---

## 12. Where things are

Repository root: `/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt`, branch
`cursor/on-device-routing-speed-37c5`, published with `git push github HEAD:main`
to `HellaCreative/ProjectMayday`. Remotes, the files that must never be staged,
and the no-fetch rule are all in the source of truth, §7 "Git: where the work
lives".

| Path | What it is |
| --- | --- |
| `docs/ROUTING-SOURCE-OF-TRUTH.md` | The authority. §2 styles, §5 contract, §8 state and backlog. |
| `docs/TAKE-THE-LEAD.md` | This handbook. |
| `Packages/DirtRoutingEngine` | The Swift routing engine, standalone SwiftPM package. |
| `Packages/DirtRoutingEngine/Scripts` | `speed-matrix.sh`, `compare-receipts.py`. |
| `Dirt/Routing` | App-side adapter, models, surface presentation, debug log. |
| `Dirt/Features/RoutePlanning` | Planner UI, itinerary state, loop planning. |
| `scripts/pack-fabric` | The JavaScript pipeline that builds packs. Reference only; do not edit it to fix a Swift problem. |

Engine files that matter most:

| File | Purpose |
| --- | --- |
| `PathSearch.swift` | The label-setting search: costs, corridor, progress gate, meter-band dominance, frontier reporting. |
| `ProfilePolicy.swift` | What a style costs: surface and road-class weights, away-tax, wander, dirt clawback and transition costs. |
| `RoutingEngine.swift` | Runs candidates per style, compares them, recovery passes. |
| `RouteQuality.swift` | Measures a finished route: dirt %, sections, re-ridden road, returns, shape faults. |
| `RoadCompass.swift` | Remaining road metres to a destination, per node. |
| `StagedRouter.swift` | Long three-pack routes planned in overlapping two-pack stages. |
| `RegionalGraph.swift`, `PackRepository.swift`, `IndexedGraph.swift` | Opening, joining and indexing packs. |
| `FuelPlanner.swift` | Retired from the routing path. Kept in history; do not wire it back in. |

App files that matter most:

| File | Purpose |
| --- | --- |
| `Dirt/Routing/NativeRoutingAdapter.swift` | Prepares packs, runs the engine, writes the one diagnostic line per request. |
| `Dirt/Features/RoutePlanning/Itinerary/RoutingSource.swift` | Always selects the pack source; network routing is disabled. |
| `Dirt/Features/RoutePlanning/Itinerary/ItineraryBuilder.swift` | Builds rider legs, logs `build leg` lines. |
| `Dirt/Routing/SurfacePresentation.swift` | Turns segments into the card's dirt/paved numbers; has a legacy fallback when segments are missing. |
| `Dirt/Features/RoutePlanning/LoopPlan.swift` | Loop geometry and scoring. Being rebuilt; see §14. |
| `Dirt/Routing/OnDevice/GraphPackStore.swift` | Which regions a route needs and whether their packs are installed. |

How a route is built, end to end:

1. `RoutingSource` selects the on-device pack source and logs
   `routing source=pack; network routing disabled`.
2. `GraphPackStore.requiredRoutingRegions` walks neighbouring regions between the
   rider's points, so Halifax to Ontario pulls in New Brunswick and Quebec.
3. `NativeRoutingSession.prepare` opens each pack, joins them into a
   `RegionalGraph` when there is more than one, and builds an `IndexedGraph`,
   cached by the exact region set. This is `prepare=[open,join,index,fuel]` in
   the log and it dominates long cross-region routes.
4. `RoadCompass.toward` builds remaining-distance-to-destination per node. On a
   joined continental graph this alone can take 10 to 18 seconds.
5. `RoutingEngine` runs the style's candidates at one or more corridor widths and
   compares them with `RouteQuality.prefersDirt`.
6. `PathSearch` is where cost lives. Label state is node, incoming edge,
   restrictions and bucket; under a finite `maximumMeters` the bucket is a meter
   band so a cheap long path cannot evict a shorter one.
7. `RouteQuality` measures it; `NativeRoutingAdapter` converts to `RouteResponse`
   with per-segment surfaces; `ItineraryBuilder` assembles rider legs.

Fallback tag if something goes badly wrong: `pre-find-speed-2026-09-15`.

---

## 13. What has worked

- **Taking fuel out of route building.** Route quality stopped fighting fuel
  plumbing and the engine got simpler.
- **Instrumentation before tuning.** Per-search counters and a one-line style
  summary found in minutes what six rounds of tuning had missed.
- **The probe as a first-class tool.** Reproducing Rick's phone numbers on the
  Mac turned arguments into measurements.
- **Meter-band dominance** under a distance cap: correct, and it only affects
  capped searches, so nothing else moved.
- **Writing the contract in Rick's own words** and making §5 the authority.
  Ambiguity was costing a round trip every time.
- **Wander measured against road progress** rather than a fixed geodesic band.
- **Staging long routes** into overlapping two-pack windows: Gaspé went from
  failing at 60 seconds and 1.35 GB to about 15 seconds and 308 MB.
- **Allow Unknown** is what actually reaches Rick's 70-80% dirt bar.

## 14. What has not worked

- **Fuel inside routing.** Windows, sweeps, fans, progress shares, gap cards.
  Every one produced paved legs, wrong-way detours or silent fallbacks.
- **Choosing pumps by shortest distance and drawing the ride afterwards.** It
  contradicted the product outright and survived a day because it was fast.
- **Post-hoc slicing.** Distance breaks cut a finished route into pieces, which
  bought no speed and dropped the segments, so long routes rendered grey and
  reported 0% dirt.
- **Chord-based "backtracking".** It counted riding around bays; nothing was
  re-ridden.
- **Tuning a single knob per round.** An unscaled goal pull gave styled-but-paved
  routes; scaling it down starved the search into meter-cap failure. Same bug,
  two faces.
- **Trusting a passing check.** The shape checker reported zero faults because
  it only looked for repeated edge identifiers.
- **Loop's manufactured anchors.** Five waypoints from trigonometry, six full
  candidates, forced Clean legs, and circuits with 18 to 55 km of repeated road.
  Being rebuilt as one outbound sweep plus one return with the outbound roads
  excluded.
- **`-wmo`.** Broke clean Xcode builds.

---

## 15. Where the work stands, 16 September 2026

Branch `cursor/on-device-routing-speed-37c5`, HEAD `a972109`, pushed to GitHub
`main`.

Done: fuel out of routing; distance breaks removed; wander rebuilt; long routes
staged; shape faults detected and repaired once; backtracking measured honestly.

Current numbers, Dirt, fuel off:

| Route | Allow Unknown off | Allow Unknown on |
| --- | --- | --- |
| Cape Breton | 668 km / 65.6% | 686 km / 78.7% |
| Yarmouth | 615 km / 56.7% | 537 km / 70.5% |
| north NB | 783 km / 65.5% | 798 km / 71.9% |
| Gaspé (staged) | 1,281 km / 69.3% | 1,399 km / 77.6% |

Re-ridden road is 0 km on all of them and returns are under 1%. The 70-80% bar
is met with Allow Unknown on, which is the live product question: it unlocks the
dirt and it is also what put Rick on a mucky unproven track. That belongs in the
interface, not the algorithm.

In flight: the Loop rebuild. The two-leg design (start → far → home) is on the
phone, but the first phone test failed — the no-reuse return never succeeded, so
every loop that completed did so through a relaxation that un-bans most of the
outbound, re-riding 5–14% of the ride; two loops failed outright with errors the
rider could not act on. Rick's decision of 16 Sep follows from that test: compass
headings are removed and the rider drops a far pin instead, and repetition
becomes a cost the search pays rather than a ban that collapses. See the source
of truth §2 "Loop and navigation handoff" and §5.

Open items, also in §8's backlog: north New Brunswick wander saturates by 50;
Quebec indexing costs about 10 seconds inside staged Gaspé; no Ontario pack
installed, so an Ontario pin runs 60 seconds and 1.35 GB before failing; the
shape checker is unproven on a real loop; advisory fuel and the other points of
interest are parked.

---

## 16. Your first moves

1. Read `docs/ROUTING-SOURCE-OF-TRUTH.md` §5 in full, then §8's backlog.
2. `git log --oneline -15` and `git status --short`. Expect Rick's two dirty
   files; leave them alone.
3. Build the probe in a scratch directory and run the three contract routes in
   Dirt. If your numbers match §15, your environment is sound.
4. Ask Rick what he is chasing today before changing anything. When he describes
   a problem, reproduce it with the probe or from his debug log before proposing
   a cause.
5. When you change routing, prove routes did not move where they should not.
6. Hand work over the way §11 describes, then stop for his phone build.
