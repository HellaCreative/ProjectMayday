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

## Routing recovery — September 7, 2026

The failed routing evolution commits `e92584d` and `106f5a5` were reverted
locally. Product intent remains in `docs/ROUTING-EVOLUTION-SPEC-2026-09-07.md`,
with recovery clarifications taking precedence. The prior implementation is
not qualified for launch. Sealed DEV V4 `fabric-v4-20260907-01` and catalogs
remain read-only; no V3 substitution, pack rebuild, or production publication.
Routing search, costs, variety seeds, forward progress, retrace handling, and
fuel-replacement ranking are one JavaScript/Swift contract. Implement behavioral
changes together and verify both runtimes; automated passes do not replace
White-device acceptance. Android must reproduce the accepted rider outcome,
but no Android implementation or qualification is claimed here.
