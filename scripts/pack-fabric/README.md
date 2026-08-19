# Pack fabric (this iOS repo)

Build packs, publish to R2, deploy live `/api/route` — all from here.

```
cd scripts/pack-fabric
node scripts/build-region-with-supplement.js bc --osm-plus-provincial
node scripts/ship-routing.js --pack bc --live --assert
```

GIS extracts go in `data-raw/` (gitignored), e.g. `data-raw/bc-dra/capillary.geojsonseq`.

`bc-ften.js` is on disk but **not wired**. Do not add it to SUPPLEMENTS.

Live API: `api/route.js` + `vercel.json`. Deploy with `node scripts/ship-routing.js --live`.
