# DIRT — Pack catalog (CDN)

SoT: R2 `https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/manifest.json`  
(`AppConfig.packCDNBaseURL`). **63 regions** as of 2026-08-12: every Canadian
province/territory and every US state. Each region is `graph.v2.bin` +
`geometry.v1.bin`. That object is PACKS download **and** live `/api/route`.

Do not treat this file as the catalog. If a row here disagrees with the
manifest, the manifest wins.

Publish: `scripts/pack-fabric/scripts/publish-packs-cdn.js` (merge, never
overwrite the whole manifest with one region).

## Still Soon (product, not “missing from CDN”)

| Item | Status |
| --- | --- |
| NS stitch freeze | Leave NS as-is unless a seam bug |
| Overlay lenses | Paint the **installed pack**. No second gov-chunk CDN. BC network lens is parked in Layers. |
| Auto-download next region | Opt-in, default **off** |
| Rich basemap JSON | `shortbread-rich-style.json` is missing; Rich falls back to Standard |

## Do not write here

- “US is catalog only” — false; states are on R2.
- Overlay gov-chunk paths as live routing. Overlays paint the installed pack.
