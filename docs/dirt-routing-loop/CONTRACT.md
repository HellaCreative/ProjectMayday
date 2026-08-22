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

## Non‑negotiable assertions (from bench)

- Dirt (unknown-off, fuel-off long): dirt ≥ 70%
- Dirt fuel-on: dirt ≥ 70% **and** max hop ≤ 237500 m **and** ≤4000 ms/hop
- Balanced: dirt 45–55%
- Direct: length ≤ shortest + 15 km
- Clean: dirt ≤ 15%
- No unexplained backtrack; ≤4000 ms per hop (all cases)

## Allowed files (Codex propose / Cursor edit)

Only these unless Claude opens a CONTRACT amendment via GATE:

- `scripts/pack-fabric/routing/lib/profile-costs.js`
- `Dirt/Routing/OnDevice/OnDeviceProfileCosts.swift` (**must stay lockstep** with JS)
- `scripts/pack-fabric/routing/lib/find-path-v2.js`
- `scripts/pack-fabric/routing/lib/fuel-chain.js` (fuel-on only)
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

## Live / device lockstep

After cost changes: same tables on JS and Swift. Cursor runs `--assert` / lockstep when HANDOFF says so. Packs: do not rebuild mid-loop.
