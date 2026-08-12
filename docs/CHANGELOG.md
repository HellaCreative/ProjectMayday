# Mayday — Changelog & discoveries

Living log for agent handoffs (backend / packs / live `/api/route`). Prefer this over chat archaeology.

**Last updated:** 2026-08-12

---

## 2026-08-12 — Durable canada-chain seam snap (pack-resilient)

### Problem
Cross-province `canada-chain` hops failed with `match_failed` when hard-coded `ADVENTURE_CHAIN_JOINTS` landed kilometres off thinned longhaul fabric after province pack rebuilds. Example: AB↔BC seed `-116.4/51.2` → `endMatch.nearestMeters ~4490` while hop match soft-expand caps at 750 m.

### Fix (not another one-off lat/lon nudge)
- After `corridorLocationsForRoute(..., { forChain: true })`, `routeCanadaChain` runs `resolveChainSeamWaypoints`: each **intermediate** seam/spine pin is snapped onto an eligible longhaul edge within **12 km** (prefer dual-province coverage + paved when clean/spine).
- Seam seeds keep `role` / `between` metadata from `merge.js`. AB↔BC seed updated toward Hwy 1 / Lake Louise band as a better *seed*; snap remains source of truth.
- Seam probes use `forceCorridorClip` so they do not inflate full province packs into Hobby RSS before hops.
- Failed snaps return clear `seam_snap_failed` + `nearestMeters`. No free-space connectors; soft-stitch policy unchanged (near-touch gaps only).
- Seam endpoints on chain hops may match up to **600 m** after snap; user pin hard cap stays **750 m**.

### Files
- `routing/lib/router.js` — seam resolver + chain wiring
- `routing/lib/graph.js` — `forceCorridorClip` for seam probes
- `routing/regional/merge.js` — seam metadata + AB↔BC seed
- `routing/test/adapters/canada-pipeline.test.js` — seam metadata + fabric snap coverage

### Deploy
Push to `main` (Vercel `dirt-mayday`) so `/api/route` picks up `router.js`.

