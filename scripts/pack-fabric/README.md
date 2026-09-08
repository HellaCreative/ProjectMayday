# Pack fabric (this iOS repo)

Build packs, publish to R2, deploy live `/api/route` — all from here.

Before creating or publishing a region, follow the canonical
[Pack Factory contract](../../docs/PACK-FACTORY.md). The accepted
NS/NB/PE/NL/QC/ON V3 bytes are frozen reference moulds; ordinary factory work
must not rebuild them.

```
node --max-old-space-size=8192 scripts/pack-fabric/scripts/build-region-graph-v3.js bc
node scripts/pack-fabric/scripts/pack-region-fuel.js bc
node scripts/pack-fabric/scripts/ship-routing.js --candidate <release-id> --pack bc
```

GIS extracts go in `data-raw/` (gitignored), e.g. `data-raw/bc-dra/capillary.geojsonseq`.

Foundational province/state packs are OSM-only. Provincial adapters and source
files remain on disk for later controlled comparisons; do not silently add an
overlay to an OSM baseline.

Live API: `scripts/pack-fabric/api/route.js` +
`scripts/pack-fabric/vercel.json`. From the repository root, deploy with
`node scripts/pack-fabric/scripts/ship-routing.js --live`.

Bare `--pack` is forbidden. After candidate acceptance, promote the recorded
bytes, update both V3 registries, redeploy LIVE, and verify with
`node scripts/pack-fabric/scripts/ship-routing.js --assert --region <id>`.

## Search-law lockstep

Routing search, costs, variety seeds, forward progress, retrace rejection, and
fuel-replacement ranking are one JavaScript/Swift contract. Every behavioural
change here must land with its on-device twin and a shared non-zero-seed
fixture; a live-only or phone-only change is a defect.

Routing-evolution tests currently use only sealed DEV V4 release
`fabric-v4-20260907-01`. Never rebuild, edit, upload, restamp, or silently
replace those bytes; never fall back to V3 or runtime OSM for a V4 result. Vercel
deployments contain API code only.
