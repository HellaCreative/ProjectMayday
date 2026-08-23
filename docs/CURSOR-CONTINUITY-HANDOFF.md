# DIRT — Continue in Cursor (handoff while Claude credits renew)

Run the same loop with **two Cursor agents + you**:
- **PLANNER** (the brain): reads your physical test + the debug log, decides ONE
  small fix, writes a precise order + a scoped test checklist. Never codes.
- **CODER** (executor): implements exactly that one change, deploys, reports.
  Never redesigns or adds scope.
- **YOU**: physically test each change, paste the result + debug log back to the
  Planner. Keep or drop, then next.

## Operating rules (the discipline that's been working)

1. **One small change per turn. Physically test before the next. Never stack.**
2. **Diagnose from evidence** — your physical test + the `ROUTE diag` / `FUEL diag`
   lines — never guesses.
3. **Protect what works** (see Protected files). Fixing route+fuel doesn't touch them.
4. **Respect the locked policy** (docs/00-…SOURCE-OF-TRUTH §6): internal pack
   regions are invisible to routing; clean-default fires ONLY for ≥1000 km OR a
   true province/state crossing; clean-default never overrides the rider's profile.
5. **Restore point `7cd5a40`** (85–90% baseline) is the floor. If a change makes it
   worse and can't be fixed in one step, revert that commit.
6. **One focused commit + one deliberate deploy per change.** Never auto-deploy on
   every build (that caused the Hobby→Pro deploy-hammer). Bench/route runs locally.

## Current state (2026-08-23)

- **Working:** live is fast; direction is correct (west pin→west, east→east — "the
  fan"); Cape Breton connects across internal shards; mode-switching recalculates;
  corridors are Dirt 60 km, Balanced/Direct/Clean 25 km.
- **In progress:** Clean pavement purity — Clean was picking up 16–36% dirt because
  its new 25 km corridor forces `clean_unpaved_last_resort`. Fix in flight: Clean =
  pavement-first, widen corridor for pavement before using any unpaved.
- **Product law:** four modes — Dirt (max dirt, 60 km corridor, may meander),
  Direct (≥60% dirt, crow-flies, 25 km), Balanced (~50% dirt, 25 km), Clean (100%
  pavement, avoids towns/highways). Fuel always on; a fuel stop is a forward
  through-point (no out-and-back); never backtrack except a rider reroute at an
  impassable point.

## Roadmap (what's left, in order — do NOT jump ahead)

1. **Clean pavement purity** (in flight).
2. **Fuel algorithm — greedy furthest-reachable + one-step look-ahead.** From a full
   tank, take the furthest reachable station that still makes forward progress
   (back off from the range limit to the nearest available), confirm the next window
   has a reachable station or the destination is reachable, commit, repeat. Never
   return an empty gap when a station is in range. Fuel-stop placement is still the
   weakest area.
3. **A\* / goal-directed search** (speed only — long fuel routes still hit
   600k–1.28M node pops; add a straight-line-to-goal heuristic within the corridor;
   route output must not change).
4. **Then, only after 1–3 are hardened:** interaction polish (drag / insert /
   renumber / fuel-stop replace — already built, re-verify), auto-download the area
   pack on drop-pin, cross-province.

## Debug diagnostics (read these to diagnose — they're in the app debug dump)

- `ROUTE diag`: buildMs, searchMs, pops, requestedProfile, effectiveProfile,
  fallbacks[], corridor, widened, maxCrossTrack (m off the straight line),
  backtrackPct, failureReason, attempts[width:outcome/pops/ms].
- `FUEL diag`: status, reachable, candidates, matchedFuel, pops, elapsedMs,
  gapReason, failureReason.
- `policy` line: packsCover, singleRegion, provinces, installed, selected(live/pack).

## Protected files (do NOT modify while fixing route+fuel)

`RoutePlannerModel.swift` (touch/select/drag/insert/renumber), `ItineraryReducer.swift`,
`RiderItinerary.swift`, `ItineraryAction.swift`, the fuel-stop replacement + forward
cascade, cross-region seam stitching (`CrossPackSeam.swift`,
`build-cross-pack-seams.js`), and the pack build/promotion tooling.

## Key files (where route+fuel fixes happen)

- Search / corridor / fan: `hop-search.js`, `find-path-v2.js`, `OnDeviceRouter.swift`.
- Costs: `profile-costs.js` + `Dirt/Routing/OnDevice/OnDeviceProfileCosts.swift` (keep in lockstep).
- Fuel chain: `fuel-chain.js` + `RoutingSource.swift` (fuelChain).
- Clean-default / region classification: `ItineraryBuilder.swift`.
- **Two engines** (JS live + Swift on-device) implement the same logic and MUST stay
  in lockstep — change both, or you'll get "works online, breaks on device."

## Watch out for (known traps)

- Shelved fuel-chain WIP is in `git stash@{0}`/`@{1}` — do NOT `git stash pop` it
  (it imports code that breaks the whole suite).
- The live service is stale unless the Coder deploys after a JS change.
- Don't let the cross-region clean-default creep back onto internal shards.

---

## PLANNER agent — paste this as its instructions

```
You are the routing PLANNER for DIRT, a dual-sport motorcycle adventure-routing
app. You are the brain: you diagnose and decide; you NEVER write code.

Each turn:
1. Read Rick's physical test result + the debug log he pastes (ROUTE diag / FUEL
   diag / policy lines).
2. Identify the single highest-value root cause FROM THE EVIDENCE — not a guess. If
   you're unsure, say "I'm not sure" and ask for the one data point you need.
3. Write ONE small, surgical fix order for the Coder agent, ending with a SPECIFIC
   test checklist: what to test, what a pass looks like, and what NOT to test yet.

Rules:
- One change per turn; Rick physically tests before the next; never stack changes.
- Respect the locked policy: internal pack regions are invisible to routing;
  clean-default fires only for >=1000 km OR a true province/state crossing; it never
  overrides the rider's profile.
- Protect the interaction layer, seam stitching, and pack tooling (see handoff doc).
  Restore point 7cd5a40 is the floor.
- Product law: Dirt (max dirt, 60km corridor, may meander), Direct (>=60% dirt,
  crow-flies, 25km), Balanced (~50%, 25km), Clean (100% pavement, avoid towns/
  highways). Fuel always on; forward-only fuel stops; no backtrack except rider
  reroute. Keep every order scoped to single-province route+fuel until it's hardened.
- Follow the roadmap in docs/CURSOR-CONTINUITY-HANDOFF.md; do not jump ahead.
Read docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md and
docs/CURSOR-CONTINUITY-HANDOFF.md before your first plan.
```

## CODER agent — paste this as its instructions

```
You are the routing CODER for DIRT. You implement EXACTLY what the Planner
specifies — one small change, one focused commit, one deploy. You do not redesign,
generalize, or add scope.

Each turn:
1. Make only the change the Planner ordered. Keep JS (live, scripts/pack-fabric) and
   Swift (on-device, Dirt/) engines in LOCKSTEP if the change is shared logic.
2. Build and confirm it compiles. Deploy the routing service ONCE (deliberate) if a
   service file changed — never auto-deploy on every build.
3. Report the exact file:line changes + before/after values, then restate the
   Planner's test checklist for Rick.

Do NOT:
- touch protected files (interaction layer, seam stitching, pack tooling — see
  docs/CURSOR-CONTINUITY-HANDOFF.md),
- git stash pop the shelved fuel-chain WIP (stash@{0}/@{1}) — it breaks the build,
- change bench thresholds or pack bytes,
- force a change that breaks the build or a protected behavior — stop and report instead.
Work in /Users/richardsmith/SandBox01/MAYDAYiOS/Dirt on feature/routing-itinerary-rebuild.
```
```
```
