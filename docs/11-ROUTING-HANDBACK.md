# DIRT Routing — Handback and Roadmap

Written 2026-08-21 after Phases 0–9. Codex drives from here. This file goes in `docs/11-ROUTING-HANDBACK.md`.

---

## Part 1 — State of the system

### What was wrong

Rider waypoints, generated fuel stops, UI rows, route geometry, and async routing state all lived in one mutable `[Stage]` array. A fuel stop was a boolean on a struct that got copied, split, and collapsed in a dozen places. When the flag was lost, fuel stopped resetting, waypoint order reversed, and rebuilds compounded into spaghetti. Separately: the fuel planner decided whether a stop was needed from shortest-path reachability rather than the ride the profile wanted, so every fuel-capped Dirt leg collapsed to 54–67% dirt; the client edge-wall that prevented backtracks was brittle; Direct ignored its 15 km budget; and a route-tap was being handled by the long-press recogniser as a map tap.

### What was built

**Canonical itinerary** (`Dirt/Features/RoutePlanning/Itinerary/`). `RiderItinerary` holds ordered `RiderWaypoint`s and `RiderLeg`s with a `generation` counter. Generated fuel stops never become waypoints; the only persisted fuel-related intent is an optional per-hop profile override keyed by station ID. It has no public setters. All change goes through one reducer via `ItineraryAction` (`append | insert | move | delete | setProfile | setHopProfile | setAllowUnknown | markImpassable | replaceAll | clear | rebuild`). Every action logs `itinerary action=… gen=a→b before=[…] after=[…] source=…`.

**Derived build** (`ItineraryBuilder`, `BuiltItinerary`, `BuiltLeg`, `FuelStop`). Fuel stops and geometry are outputs, recomputed from the first changed leg forward, with earlier legs reused from the previous build. Every `await` is generation-guarded; stale results are dropped and logged. Progressive reveal commits partial builds with later legs `.pending`.

**Routing source** (`RoutingSource` protocol; `LiveRoutingSource`, `PackRoutingSource`; `RoutingSourcePolicy`). The builder doesn't know whether it's online. Live is authoritative when reachable; packs serve offline reroute. A `RouteResponseCache` keyed on `(from, to, profile, allowUnknown, source, packRev, priorEdges, arrivalEdge)` makes toggles and reverts near-instant.

**Gestures** (`MapLibreMapView`). One resolver: pin → route → map. Tap and long-press share it. Route hit = insert; map hit = append; fuel pins are selectable and locked. Route taps during a build are ignored, never queued.

**Server** (`scripts/pack-fabric/routing/lib/router.js`, `fuel-chain.js`, `api/fuel-chain.js`). Settlement-wall fallback fires only on a proved no-path, never on timeout or low score; low-dirt routes return with `lowDirt=true` instead of being replaced. Soft backtrack penalty (`priorEdgeIds` ×4, `arrivalEdgeId` ×12) replaced the client wall; dead ends are still routable and report `backtrackPct`. Fuel need is decided by routing the leg with the active profile unconstrained — if that ride exceeds usable range, a stop is needed regardless of reachability. Station selection routes the top K=6 candidates and picks the best dirt% that fits (Dirt/Balanced) or the one nearest the shortest path (Direct/Clean). `maxMeters` is a search-time prune. Direct honours `shortest + 15 km`. Responses carry `legId`, `restrictedMeters/Reason`, `stationCandidates`, `balancedMiss`.

**Benchmark** (`scripts/pack-fabric/bench/`). Seven fixed NS routes × 4 profiles × unknown on/off × fuel on/off, deterministic, pinned to live candidate `ns-osm-20260820-01`. `npm run bench:ns -- --compare <sha>` prints deltas. **Every routing change ships with this table in its report.** Assertions are never relaxed to go green; red rows come to the human.

### Where it stands

- Bench: 56/65 at `34b777d`; expected ~62/65 after the approved 9e fix (`phase 9g`). The remaining reds are the short-Balanced fabric limit (kept red deliberately) and whatever 9g doesn't flip.
- Dirt without fuel: 82–92% on every NS route. Dirt with fuel: 80–87% on targeted routes.
- Device: insert/renumber, drag, swipe-delete, From Here → Plan, and progressive reveal verified by the human on 08-21 pre-Phase 7. Post-Phase 9 device pass pending.
- Offline: architecture in place; **never exercised end-to-end under the new model.** Treat as unverified.
- Navigation (cues, deviation reroute, impassable flow): **not audited this cycle.** Planning was the scope.
- Packs: NS frozen at `ns-osm-20260820-01`. All other regions being rebuilt as live candidates on `feature/pack-rebuild-2026-08` (separate worktree). None promoted.

### Locked

- `docs/08-MAP-REFINEMENT.md` — the routing laws. Do not reopen to chase a number. If a bench row can't go green inside the laws, report it; the human decides.
- `docs/09-OSM-PACK-QUALITY-STANDARD.md` — the pack build and release gate.
- `docs/10-ITINERARY-MODEL.md` — the canonical model. Fuel stops never become rider waypoints. `RiderItinerary` never gets a setter.
- `RoutePlannerCard.swift` outside `stageList`/`StageCard`, and the label helpers in `RoutePlannerModel.swift` — UI in progress by another agent; byte-identical output required.

### Working rules that kept this from going sideways

1. Checkpoint commit before any prompt. Commit + tag per phase. Never reset/amend/force-push.
2. Phases are gated: tests pass → bench compare pasted → commit → next phase. A failed gate is a stop-and-report, not a push-through.
3. Diagnose before fix for anything that touches a law. Write the diagnosis doc; let the human sign off.
4. A green row turning red fails the phase regardless of how many others turned green.
5. Logs are the contract. Every decision the system makes emits a greppable line; the replay harness (`LogReplayTests`) turns a device log into a regression test.
6. The human tests experience on the phone; Codex tests numbers on fixed pins. Don't confuse the two.
7. Packs and search code never change in the same phase or on the same branch.

---

## Part 2 — Roadmap

### Phase 10, item 8 — Per-hop profile with forward replan

`RiderLeg.hopOverrides` stores a profile keyed by the fuel station a generated hop departs from. Changing a fuel-hop profile preserves every upstream `BuiltLeg` through that station, then rebuilds only that station forward. The first fuel station therefore remains fixed while later pump choices and geometry may change. Overrides for stations absent from the completed replacement chain are pruned; changing the rider-leg profile clears every hop override on that leg. The expanded rider-leg card exposes compact, non-deletable hop rows with kilometres, dirt percentage, and an individual profile menu. The diagnostic contract is `fuel hop override station=<id> profile=<p> replanFrom=<id>`.

Ordered by rider risk, then value. Each item is sized for one prompt in the phase style above.

### R1 — Fuel economy by surface (safety)
Range is one number today; real dirt consumption is 20–30% worse than pavement. Add tank litres + a dirt-penalty default of 25% to `FuelRangePrefs`. Builder computes usable range per leg from the leg's surface mix: `tank ÷ (dirtShare × dirtRate + pavedShare × pavedRate)`. Chain uses per-leg range. Expect more stops on Dirt; that's correct. Bench gets a `fuel-economy` column. Client-only arithmetic; no server change.

### R2 — Fuel gaps as a first-class itinerary state (safety)
When no chain fits (Cape Breton, Highlands), stop returning a bare 422. Server returns the best available chain with `gapMeters` and the bracketing stations. Builder marks the leg `.gap` (not `.failed`) with `extraLitres`. Card shows a row — "No pump in range · 270 km gap · 33 km over · carry ~1.5 L" — with two actions: *move waypoint*, *I'll carry fuel*. Dirt/Balanced may accept gaps up to 20% over usable; Direct/Clean never offer them. Toast announces; the row persists.

### R3 — Offline parity pass
Exercise `PackRoutingSource` end-to-end on the NS pack under the new model: plan online, airplane mode, navigate, mark impassable, reroute. Same log contract with `source=pack`. Add a bench mode that runs the NS matrix against the local pack and diffs against live; differences are either expected (pack revision) or bugs. Until this passes, offline is unverified.

### R4 — Navigation audit
Same treatment planning got: read the deviation-reroute, cue, and impassable code; check they go through `apply(.markImpassable)` and the builder rather than a side path; instrument; device-test. Expect to find a second `Stage`-style conflation here. Scope it before fixing it.

### R5 — Balanced miss and low-dirt surfaced in the UI
The server already returns `balancedMiss` and `lowDirt`. Show them: a small badge on the leg ("58% — no 50/50 route this short"). Stops riders thinking the router is broken when the terrain is.

### R6 — Pack promotion workflow
Once the rebuild branch finishes: review `PACK-REBUILD-2026-08.md`, promote BC/AB/WA candidates after a device pass in each, then the rest. Re-cut NS last, re-baseline the bench against the new NS candidate, and commit the new baseline. Cross-pack seams involving NS are built at that point.

### R7 — Alternatives per leg
Server returns 2–3 candidates per leg with dirt%, km, backtrack%, and a meander score. Card lets the rider pick. Cheap on the server (the K-candidate machinery from station selection generalises), and it gives telemetry on what riders actually choose — the input for any future profile tuning, which is the only legitimate way 08 gets reopened.

### R8 — Polish
Toast → slide-out from the logo. From Here default profile policy (always Dirt vs last-used). Route-tap feedback haptic. None of this touches routing.

### Not on the roadmap, deliberately
- Reopening 08 cost tables or corridor budgets. Only R7's telemetry earns that conversation.
- Secondary data sources (DRA/FTEN/NRN). 09 says OSM-only until every region passes on OSM alone.

---

*When something structural breaks — a bench regression Codex can't explain, or a feature that needs a model change — that's the time to bring the auditor back. Everything else, the bench and the logs will tell you.*
