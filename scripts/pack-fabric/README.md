# Pack fabric (this iOS repo)

Build packs, publish to R2, deploy live `/api/route` — all from here.

```
cd scripts/pack-fabric
node scripts/build-region-with-supplement.js ns --osm-only
node scripts/ship-routing.js --pack bc --live --assert
```

GIS extracts go in `data-raw/` (gitignored), e.g. `data-raw/bc-dra/capillary.geojsonseq`.

Foundational province/state packs are OSM-only. Provincial adapters and source
files remain on disk for later controlled comparisons; do not silently add an
overlay to an OSM baseline.

Live API: `api/route.js` + `vercel.json`. Deploy with `node scripts/ship-routing.js --live`.
