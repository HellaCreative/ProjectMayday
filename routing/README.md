# Routing data plane (Canada foundation)

Offline regional graphs + Node A* via `POST /api/route`.

## Architecture

1. **OSM** — basemap tiles + rider-service POIs only (not routing edges).
2. **NRN** — national paved/gravel road backbone (per province GeoPackage).
3. **Provincial datasets** — resource roads / tracks / access detail (NS = NSTDB).
4. **Conflation** — NRN owns road identity; provincial data supplements unmatched
   resource/track detail and may enrich NRN edges whose pavement status is unknown.
5. **Regional packages** — `routing/data/regions/<id>/graph.v1.json.gz` (never one
   Canada-wide browser graph).

Riders never see source switches. The map paints a single corridor network.

## Canonical schema

- `routing/schema/enums.js` — surface / access / structure enums
- `routing/schema/edge.js` — normalized edge factory

## Adapters

- `routing/adapters/contract.js` — shared report contract
- `routing/adapters/nrn.js` — National Road Network
- `routing/adapters/ns-nstdb.js` — Nova Scotia NSTDB

## Registry

`routing/registry/sources.json` lists all 13 provinces/territories with NRN +
provincial supplemental status.

## Build Nova Scotia regional graph

```bash
# Requires: curl, unzip, ogr2ogr, node
# 1) Download NRN NS GeoPackage → data-raw/nrn/ns/nrn-roadseg.geojsonseq
# 2) Ensure app/data/ns-gov-chunks exist (NSTDB pack)
node scripts/build-ns-regional-graph.js
```

Outputs:

- `routing/data/regions/ns/graph.v1.json.gz`
- `routing/data/regions/ns/graph.v1.meta.json`
- `routing/data/reports/ns-nrn-nstdb-build.json`
- `routing/data/reports/ns-graph-comparison.json`

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
