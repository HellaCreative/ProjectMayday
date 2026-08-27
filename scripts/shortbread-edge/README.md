# Dirt Shortbread delivery

This Cloudflare Worker serves immutable Shortbread MVT tiles from a PMTiles
archive stored in the existing `dirt-packs` R2 bucket. The app activates a
release only after its manifest and sample tile pass validation. Public OSM
Shortbread remains the automatic fallback and emergency rollback path.

## Release contract

- Object: `shortbread/v1/releases/<release-id>/<region>.pmtiles`
- Tiles: `/shortbread/v1/releases/<release-id>/tiles/{z}/{x}/{y}.mvt`
- Manifest: `/shortbread/v1/manifest.json`
- Health: `/shortbread/v1/health`
- Archives are immutable. A data refresh receives a new release ID and URL.
- Schema-major changes require a new cache namespace and an app compatibility
  review. A provider change with the same Shortbread major reuses cached z/x/y
  tiles.

## Build and publish

Install the checksum-pinned VersaTiles CLI, then build the regional archive:

```sh
./install-versatiles.sh
VERSATILES_BIN=artifacts/tooling/versatiles-4.9.1/versatiles ./build-region.sh \
  maritimes maritimes-20260607 -69,43,-59,49 \
  https://download.versatiles.org/osm.versatiles

npx wrangler r2 object put \
  dirt-packs/shortbread/v1/releases/maritimes-20260607/maritimes.pmtiles \
  --file artifacts/maritimes-20260607/maritimes.pmtiles \
  --content-type application/vnd.pmtiles

npm run check
npm run deploy:dry
npm run deploy
npm run verify
```

`npm run verify` checks the manifest, health, an R2-backed sample tile, an
outside-archive fallback tile, attribution, cache headers, and CORS before a
new release ID is promoted.

## Rollback

The iOS client falls back to public OSM unless the manifest and sample tile are
healthy. For an immediate release-wide rollback, set the client preference
`dirt.shortbread.forcePublicFallback` to true in a patched build. A tile release
can also be rolled back by restoring the previous immutable `RELEASE_ID` and
`ARCHIVE_KEY` in `wrangler.jsonc` and redeploying the Worker.
