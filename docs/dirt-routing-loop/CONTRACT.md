# Routing contract — violate = reject the turn

## Scoreboard

- Primary: `npm run bench:ns` → `scripts/pack-fabric/bench/results/latest.md`
- Target ladder: **38 → 45 → 50 → 56 / 65** green (do not skip ladders by loosening asserts)
- A turn is a **fail** if green count drops, or any previously green case flips red

## Per-turn safety gate (NS green is necessary, not sufficient)

The NS bench is Nova-Scotia-only and JS-only. It cannot see the Swift app, the
unit suite, or JS↔Swift cost drift. So a turn that changes an Allowed file is
**not green** until all of the following hold — Codex verifies these in the
post-execution test pass before handing back:

- `npm run bench:ns` green count did not drop and no former green flipped red.
- `npm test` (full node routing suite) passes.
- JS↔Swift cost lockstep holds: if `profile-costs.js` changed,
  `OnDeviceProfileCosts.swift` changed in lockstep and the `--assert`/lockstep
  check passes.
- Before any hand-back to the human for a ride test: the iOS target still
  builds (`build-for-testing`). A full Swift build is required only at that
  human-handoff boundary, not on every fast cost-tuning turn.

Green-count-only is never enough to skip the human.

## Mode spec — Rick 2026-08-22 (authoritative)

Dirt targets and corridor widths (corridor = max off-crow-flies wander):

| Mode | Dirt target | Corridor |
| --- | --- | --- |
| Dirt | 100% (assert ≥70%) | 60 km base → 80 km max, desperation only (fuel / around water) |
| Direct | ≥60% dirt, crow-flies | 25 km (tight) |
| Balanced | ~50% dirt | 25 km (tight) |
| Clean | 0% dirt / 100% pavement (assert ≤15%) | n/a |

Global: no loops to chase dirt; **no backtrack** except a rider-initiated reroute
at an impassable point. Corridor constants live in `hop-search.js`
(`DIRECT/BALANCED/DIRT_CORRIDOR_M`).

## Non‑negotiable assertions (from bench)

- Dirt (unknown-off, fuel-off long): dirt ≥ 70%
- Dirt fuel-on: dirt ≥ 70% **and** max hop ≤ 237500 m **and** ≤4000 ms/hop
- **Direct: dirt ≥ 60% AND cross-track within the 25 km corridor.** (RETIRED the
  old `length ≤ shortest+15km` — it contradicted the mode: Direct is crow-flies +
  dirt-biased, not shortest.)
- Balanced: dirt **35–65%** (target ~50/50; either side is fine, terrain-limited results pass — Rick 2026-08-22, widened from the too-strict 45–55%)
- Clean: dirt ≤ 15%
- No backtrack except rider-initiated reroute; ≤4000 ms per hop (all cases)

## Allowed files (Codex propose / Cursor edit)

Only these unless Claude opens a CONTRACT amendment via GATE:

- `scripts/pack-fabric/routing/lib/profile-costs.js`
- `Dirt/Routing/OnDevice/OnDeviceProfileCosts.swift` (**must stay lockstep** with JS)
- `scripts/pack-fabric/routing/lib/find-path-v2.js`
- `scripts/pack-fabric/routing/lib/fuel-chain.js` (fuel-on only)
- `scripts/pack-fabric/routing/lib/hop-search.js` (corridor-width constants only) — added 2026-08-22, Rick greenlit
- `Dirt/Routing/OnDevice/OnDeviceRouter.swift` (Swift lockstep for corridor/Balanced) — added 2026-08-22, Rick greenlit
- Bench fixtures **only** if SCOREBOARD proves a pin is off-graph (`snap_miss`) — Claude must list the fixture ID in HANDOFF first

## Forbidden without GATE + human

- **Vercel production deploys** (`vercel --prod`, `ship-routing.js --live`, any
  push to `/api/route` prod). The loop benches **locally** against the R2 pack —
  no per-turn deploy is needed or allowed. A live deploy is a deliberate,
  matched client+service release, GATE + human only. (Root cause of the
  2026-08-22 Hobby→Pro deploy-hammer: `cursor-cli` redeployed the same commit to
  production ~14× in 80 min.)
- Pack rebuilds / R2 uploads / promote
- Changing bench assertion thresholds to “make green”
- Broad refactors across router + UI + packs in one turn
- Touching itinerary/fuel-chain product UI while this loop is active
- Multiple independent cost changes in one turn (one hypothesis only)

## One-knob rule

Each turn: **one** failing cluster (named case IDs from SCOREBOARD) → **one** hypothesis → **one** patch → re-bench → write results.

**Exception — spec-alignment turn (Rick greenlit 2026-08-22):** one turn may
apply the full mode-spec correction together (revert Direct cost damage from
turns 1–4, set the three corridor widths, retire the Direct shortest assertion),
because it implements an authoritative spec, it is not experimental tuning. After
it, the one-knob rule resumes.

## Live / device lockstep

After cost changes: same tables on JS and Swift. Cursor runs `--assert` / lockstep when HANDOFF says so. Packs: do not rebuild mid-loop.
