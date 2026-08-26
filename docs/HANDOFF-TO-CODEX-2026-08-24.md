# DIRT — Handoff to Codex (2026-08-24)

You're picking up the Dirt routing work mid-stream. This is the full state. Read the linked
docs for detail; this is the map.

## How we work (non-negotiable)
- **Two engines, always in lockstep:** JS (live Vercel engine `scripts/pack-fabric/api/route.js`
  + `routing/lib/*`) and Swift on-device (`Dirt/Routing/OnDevice/*`). Every routing/cost change
  lands in BOTH, identical.
- **DEFINITION OF DONE = deployed live + verified, not "committed."** Every task ends by
  deploying the live engine at HEAD and confirming, via a live `POST` to
  `https://dirt-mayday.vercel.app/api/route`, that the response `serviceBuild` == HEAD commit.
  Rick routes via `selected=live`, so nothing is testable until it's actually live.
- **Pack publish is via wrangler:** `node scripts/pack-fabric/scripts/ship-routing.js --promote
  <releaseId> --pack <region>` (uses `npx wrangler r2 object put --remote`, authenticated as
  rick@hellacreative.com). The `publish-packs-cdn.js` aws-s3 path is LEGACY — not the real path.
  (Claude earlier misdiagnosed a "silent publish failure" there; it was wrong — ignore it.)
- **One change → deploy → verify → Rick physically tests → next.** Never stack. Diagnose-first
  on anything non-trivial (reproduce + explain the mechanism before changing).
- Live API request shape: `{"profile":"cleanest|balanced|dirt","locations":[{"lat":..,"lon":..},
  {"lat":..,"lon":..}]}`. Fuel: `POST /api/fuel-chain`.

## Current live state
- `serviceBuild` = `5a8ffdc` (HEAD) unless a newer deploy has landed since.
- NS pack = release `ns-v3-20260823-05` (`graphSha256 c2d7b2c…`, ~15.57 MB, paths restored,
  structure in). Only NS is v3; other 62 regions still v2.
- Profiles: **Clean, Balanced, Dirt** (Direct was removed — redundant with Balanced).

## Authoritative docs
- `docs/PACK-DATA-V3-AUTHORITY.md` — the v3 pack data model + build order + locked taxonomy.
- `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md` — ride-mode / routing-law definitions.
- `docs/AUDIT-2026-08-24.md` — full A–G audit (findings ranked; note P0-5 was WRONG — see above).
- `docs/CLEANUP.md` — all UI/interface/testing-scaffolding cleanups (do LAST).
- `docs/00-NAVIGATION-SOURCE-OF-TRUTH.md` — Start Navigation, Junction/Rally cues, HUD (supersedes `NAVIGATION.md`).
- `docs/FIELD-FEEDBACK.md` — tester feedback (unconfirmed; incl. the re-route-behind bug).

## DONE (live + verified)
- Full v3 pack de-compression A–G: leaves preserved + decoded byte-identical (JS↔Swift), ferry,
  structure (fords/tunnels/overpasses).
- Honest Dirt% (counts gravel as dirt, matches the orange map paint).
- Clean uses road-class tiers; arterial over-routing largely fixed (Halifax→Porters Lake Clean
  now 46 km, was 162).
- **Direct profile removed** entirely (Clean/Balanced/Dirt only); legacy "direct" → Balanced via
  the existing unknown-profile default. Verified live.
- **Fuel comfort window:** refuels in the 50–80% tank band, not at the wall (Sydney stop 79.9%
  not 99.9%). Verified live (`5a8ffdc`).

## IN FLIGHT (prompts already written, may be running)
1. **Gas-station-waypoint refuel** — a numbered waypoint on a gas station = a live refuel
   (recomputed on every itinerary edit; drag off → reset removed + replan). Both engines +
   deploy + verify.
2. **Fuel-leg backtrack — DIAGNOSE (read-only).** On a Dirt route with a fuel stop, the leg
   leaving the station backtracks on already-ridden dirt instead of taking a nearby PAVED
   (yellow) road forward. Hypothesis (verify before fixing): the prior-edge **backtrack penalty
   ≈4×** (`fuel-chain.js:210`) is weaker than **Dirt's paved penalty ≈16×**, so doubling back on
   dirt scores cheaper than a paved connector forward. Proposed fix: raise the backtrack penalty
   so it dominates the worst surface penalty (reversing never beats forward). Confirm the
   4×-vs-16× cause first.

## NEXT — the sequence Rick locked
1. Finish **fuel**: gas-station-waypoint refuel → fuel-leg backtrack fix → **gap look-ahead**
   (empty-dirt-spur rides still gap: `no_route_connected_fuel_chain`; needs a look-ahead/recovery
   lever — the comfort window intentionally didn't solve this).
2. **Route-distance regression tests** — fixed NS pin-pairs per profile with distance bands (e.g.
   "Halifax→Truro Clean ≤ 110 km"). This is the guard that would have caught every over-routing
   bug, and the tool for validating other provinces as they go v3. Foundation piece.
3. → Foundation done. Then: **cross-province / cross-state seam stitching** + **finalize the pack
   build** so provinces/states can be rebuilt to v3. (Auto-download packs on route creation is the
   UX for this — see CLEANUP "Pack management model".)
4. **Cleanup LAST** (CLEANUP.md) + navigation (`00-NAVIGATION-SOURCE-OF-TRUTH.md`) as their own efforts.

## Open functional items (not yet scheduled)
- **Dirt/Balanced still route on COARSE surface, not the v3 leaves** (only Clean was migrated;
  audit P0-3). The half-connected v3 value. Migrate them to leaf costing — one profile at a time.
- **Re-route-behind bug** (FIELD-FEEDBACK): when a rider hits an impassable spot and re-routes, it
  routes backward instead of toward the next waypoint. Fix: treat the impassable location as an
  obstacle (river/lake) — pull toward next-waypoint gravity, go around by the lesser of two
  distances, never backward. Ties to the same forward-progress logic as the fuel-leg backtrack.
- Clean residual: arterial is still double-penalized (tier 1.4 × always-on preferBackRoads 4.5 =
  6.3×; audit P0-1). 46 km is plausibly fine given harbour geography — verify before touching.
- Dirt lateral meander (audit P1-3) and Clean unbounded corridor (P1-5) — safety-net tuning.

## First thing to do
Confirm current live `serviceBuild` (curl the endpoint), report whether the two in-flight fuel
prompts (waypoint refuel, backtrack diagnosis) have landed, then continue the sequence from where
they leave off. Ask Rick before starting anything that isn't already scoped above.
