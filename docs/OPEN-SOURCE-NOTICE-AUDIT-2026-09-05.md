# iOS open-source notice audit — 2026-09-05

This is an engineering inventory, not legal advice. It records what the
reviewed production Release build contains and the evidence used to assemble
the notice distributed with the app.

## Result

- The prior Release app did not contain a third-party software notice.
- `Dirt/ThirdPartyNotices.txt` now reproduces the applicable license and
  NOTICE text and is bundled automatically by the synchronized Xcode group.
- `scripts/verify-ios-release.sh` now fails if that file is missing or empty.
- The MapLibre attribution control remains enabled. The bundled map style also
  declares OpenStreetMap attribution.
- Two asset-provenance questions remain for the product/legal owner before
  submission; they do not justify changing the routing or map-pack code.

## Shipped dependency inventory

The versions below come from the checked-in
`Dirt.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
Shipping status was then checked against the Release target dependency graph,
link file list, app executable, embedded frameworks, and resource bundles.

| Package | Version | Release disposition | License evidence | Notice action |
| --- | ---: | --- | --- | --- |
| MapLibre Native Distribution | 6.28.0 | Embedded dynamic framework | Exact resolved artifact `LICENSE.md`: BSD 2-Clause | Full BSD notice bundled |
| Supabase Swift | 2.53.0 | Statically linked, including Auth, Functions, PostgREST, Realtime, Storage, and Helpers | Exact checkout `LICENSE`: MIT, Copyright 2021 Supabase | Full MIT notice bundled |
| Swift Clocks | 1.1.0 | Statically linked | Exact checkout `LICENSE`: MIT, Copyright 2022 Point-Free | Full MIT notice bundled |
| Swift Concurrency Extras | 1.4.1 | Statically linked | Exact checkout `LICENSE`: MIT, Copyright 2023 Point-Free | Full MIT notice bundled |
| XCTest Dynamic Overlay | 1.11.0 | Statically linked, including Issue Reporting | Exact checkout `LICENSE`: MIT, Copyright 2021 Point-Free, Inc. | Full MIT notice bundled |
| Swift Crypto | 4.5.1 | Statically linked; privacy resource bundle also ships | Exact checkout `LICENSE.txt` and `NOTICE.txt`: Apache 2.0 | Apache license and upstream NOTICE bundled |
| Swift HTTP Types | 1.6.0 | Statically linked | Exact checkout `LICENSE.txt` and `NOTICE.txt`: Apache 2.0 | Apache license and upstream NOTICE bundled |
| Swift ASN.1 | 1.7.1 | Resolved transitively, but not linked or copied into the Apple Release product | Exact checkout `LICENSE.txt` and `NOTICE.txt`: Apache 2.0 | Not represented as shipped software |

Apple SDK frameworks supplied by iOS are outside this third-party distribution
inventory.

## Map and data attribution evidence

- `Dirt/Map/MapLibreMapView.swift` leaves the MapLibre attribution button
  enabled and positions it at the lower left.
- `Dirt/Map/shortbread-style.json` declares
  `© OpenStreetMap contributors` with the OpenStreetMap copyright URL.
- Runtime map-manifest validation also requires an OpenStreetMap attribution
  string before accepting a remote style manifest.

An owner should visually confirm on the final archive/device that app overlays
do not make the attribution control unreachable. This audit did not change map
rendering or device state.

## Remaining owner gates

1. **SVWD03 style and sprites:** the source and exact sprite revision are now
   traced in
   `docs/SVWD03-STYLE-SPRITE-PROVENANCE-2026-09-05.md`. The bytes came through
   Andy Townsend's `SomeoneElse-vector-web-display` project; its pinned root
   license is GNU GPL version 3 text and its SVWD03 scripts state GPL version 3
   or later. DIRT also records an OSM Bright-derived visual restyle, whose
   pinned upstream license separates BSD 3-Clause code from CC BY 4.0 visual
   design. This is no longer an unknown-source question, but it remains an
   owner/legal release gate: obtain a written obligations decision and add the
   required notices/source mechanism, permission, or known-provenance
   replacement before submission.
2. **Store-facing location:** the notice is now distributed inside the app
   bundle, which closes the objective binary-redistribution gap. Legal/product
   should decide whether to add a human-readable “Open Source Licenses” screen
   or publish the same notice on DIRT's legal site. That is a product/legal
   decision and was intentionally not added here.

## Repeatable verification

Build the production Release configuration, then run:

```sh
scripts/verify-ios-release.sh /absolute/path/to/Dirt.app
```

The verifier requires `ThirdPartyNotices.txt`, the reviewed privacy
manifests/resources, the production identity, and the expected embedded
framework set. Dependency upgrades require rerunning this audit and updating
the notice before release.
