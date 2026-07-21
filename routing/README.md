# Routing data plane (Canada foundation)

Offline regional graphs + Node A* via `POST /api/route`.

## Architecture

1. **OSM** — basemap tiles + rider-service POIs; also **gap-fill routing edges**
   (motorized highways unmatched by NRN) for proven provinces (NB, QC).
2. **NRN** — national paved/gravel road backbone (per province GeoPackage); owns identity.
3. **Provincial datasets** — resource roads / tracks / access detail (NS = NSTDB,
   NB = Forest Roads, QC = chemins multiusages, …); default `motorized_unknown`.
4. **Conflation** — NRN → OSM gap-fill → provincial. No free-space connectors.
5. **Regional packages** — `routing/data/regions/<id>/graph.v1.json.gz` (never one
   Canada-wide browser graph).

Riders never see source switches. The map paints a single corridor network.

## Canonical schema

- `routing/schema/enums.js` — surface / access / structure enums
- `routing/schema/edge.js` — normalized edge factory

## Adapters

- `routing/adapters/contract.js` — shared report contract
- `routing/adapters/nrn.js` — National Road Network
- `routing/adapters/osm-roads.js` — OSM motorized gap-fill (Geofabrik)
- `routing/adapters/ns-nstdb.js` — Nova Scotia NSTDB
- `routing/adapters/nb-forest-roads.js` — New Brunswick Forest Roads
- `routing/adapters/qc-multiusage.js` — Québec chemins multiusages

```bash
# OSM gap-fill extract (once per province), then rebuild:
bash scripts/extract-osm-roads.sh new-brunswick
bash scripts/extract-osm-roads.sh quebec
node scripts/build-region-with-supplement.js nb
node scripts/build-region-with-supplement.js qc
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
