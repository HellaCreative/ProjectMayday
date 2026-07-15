# Phase 2B routing service

Offline Nova Scotia graph + Node pathfinder served through `POST /api/route`.

## Why not Valhalla (this phase)

Valhalla remains the preferred long-term tiled engine, but this phase implements
**one** engine end-to-end:

1. NSTDB Phase 2A edges carry custom `accessClass` / `surfaceClass` / `edgeId`
   fields that require an OSM tagging translation pipeline before Valhalla tiles.
2. This environment has no Docker / Fly host for a persistent Valhalla process.
3. Vercel hosts a thin API that keeps a **warm in-memory copy** of the prebuilt
   graph (`routing/data/ns-graph.v1.json.gz`) instead of rebuilding the graph in
   the browser.

## Rebuild graph

```bash
node scripts/build-routing-graph.js
```

## Tests

```bash
node routing/test/run-fixtures.js   # offline graph routing fixtures
node routing/test/stages.test.js    # multi-stage trip model (aggregation, weighted %, serialize, transitions, stale tokens)
```

`routing/lib/stages.js` is a framework-free UMD module shared by the browser
planner (`app/index.html`) and the Node tests. It owns the multi-stage trip
model: stage status transitions, distance-weighted aggregation, saved-route
serialize/deserialize, gap detection (no invented connectors), and per-stage
stale-request tokens.

## API

`POST /api/route` — see `PHASE-2-BUILD-GUIDE.md` route contract.
