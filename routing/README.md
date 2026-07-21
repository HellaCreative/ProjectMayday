# Routing data plane (Canada foundation)

Offline regional graphs + Node A* via `POST /api/route`.

## Mental model (live)

1. **OSM road fabric** — essentially all driveable roads on the basemap (paved,
   gravel, dirt, service). Included in the routing graph as
   `motorized_permissive`. Surface/class drive visuals and costing, **not** the
   unknown-access toggle. Shortbread tiles remain display-only; the graph is a
   separate Geofabrik extract of motorized highways.
2. **NRN** — Canadian national identity / backbone where it overlaps OSM. Owns
   identity in conflation; must not block yellow OSM roads.
3. **Provincial capillary** — gov forest / resource layers that fill *between*
   OSM roads (NB Forest Roads, QC chemins multiusages, NSTDB, …). Default
   `motorized_unknown`; gated by “Allow unknown access.”
4. **Conflation** — NRN → OSM fabric → provincial capillary. No free-space
   connectors.
5. **Regional packages** — `routing/data/regions/<id>/graph.v1.json.gz`.
   Vercel longhaul packs ship **OSM+NRN fabric only** (no provincial) so
   ordinary basemap roads snap and route with unknown off.

Riders never see source switches. The map paints a single corridor network.

## Canonical schema

- `routing/schema/enums.js` — surface / access / structure enums
- `routing/schema/edge.js` — normalized edge factory

## Adapters

- `routing/adapters/contract.js` — shared report contract
- `routing/adapters/nrn.js` — National Road Network
- `routing/adapters/osm-roads.js` — OSM motorized road fabric (Geofabrik)
- `routing/adapters/ns-nstdb.js` — Nova Scotia NSTDB
- `routing/adapters/nb-forest-roads.js` — New Brunswick Forest Roads
- `routing/adapters/qc-multiusage.js` — Québec chemins multiusages

```bash
# OSM fabric extract (once per province), then rebuild:
bash scripts/extract-osm-roads.sh new-brunswick
bash scripts/extract-osm-roads.sh quebec
bash scripts/extract-osm-roads.sh nova-scotia
node scripts/build-region-with-supplement.js nb
node scripts/build-region-with-supplement.js qc
node scripts/build-region-with-supplement.js ns

# Vercel longhaul fabric packs (NS/NB + QC quadrants):
node scripts/build-longhaul-region-packs.js ns nb
node scripts/build-qc-quadrant-packs.js
```

## Registry

`routing/registry/sources.json` lists all 13 provinces/territories with NRN +
provincial supplemental status.

## Build regional graphs (all provinces)

```bash
# Requires: curl, unzip, GDAL/ogr2ogr, node
# One province/territory at a time (deletes raw zip/seq after pack):
./scripts/ingest-nrn-region.sh pe
./scripts/ingest-nrn-region.sh bc   # etc.

# Nova Scotia with NSTDB supplement (existing):
node scripts/build-ns-regional-graph.js

# Optional provincial supplements (BC FTEN / Alberta Access):
node scripts/build-region-with-supplement.js ab
```

Cross-province routes (e.g. Halifax → Vancouver) merge corridor regional packs
with southern highway anchors and border-node stitching (no free-space connectors).

NS-only production requests still default to the legacy NS graph unless
`ROUTING_USE_REGIONAL=1`.

## Tests

```bash
node routing/test/adapters/canada-pipeline.test.js
node routing/test/run-fixtures.js
node routing/test/stages.test.js
node routing/test/roadbook-curves.test.js
node app/test/group-sharing.test.js
```

## API

`POST /api/route` — existing request shape. Region is selected from locations
(or optional `regionId`). Cross-province multi-graph merge returns a clear error
until boundary-node joining ships.
