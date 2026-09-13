# DIRT Rider Services freeze — 2026-09-05

**Status:** accepted iOS/shared-service release candidate

**Accepted app build:** `2 (14)` DIRT Dev on RED (iPhone 11)

**Accepted source:**
`9808936c1cdad627c1b55c2cb3ca23925345ee7d`

**Physical result:** Richard confirmed the Fuel, Campgrounds, Lodging, and
Liquor layers working on device on 2026-09-05.

This record covers Rider Services display/data only. Routing requirements and
fuel planning are maintained in [the routing source of truth](ROUTING-SOURCE-OF-TRUTH.md).

## Accepted contract

- Fuel has one source of truth: each region's `fuel.v1.json` routing sidecar.
  The same data serves route fuel proof and the Fuel map layer.
- Campground, lodging, and liquor are checksum-verified whole-region files in
  the separate Rider Services catalog. They never participate in graph-pack
  activation and cannot block Start Navigation.
- Rider Services display does not contact Overpass or another public OSM data
  server at runtime. Its OSM/Geofabrik input is prepared before publication.
- Online requests use the environment-selected DIRT `/api/poi`; the app retains
  verified regional files for offline display and falls back only to bytes that
  match the catalog size and SHA-256.
- Camera changes are debounced and overlapping work is coalesced. Fuel failure
  cannot suppress the other enabled layers, and an unavailable optional Rider
  Services file cannot affect routing.
- Visible bounds carry no DIRT account identifier.

## Frozen publication identities

- Road/fuel catalog SHA-256:
  `9f11c79e6a103329d83184eb1d5b440ae70671529dfcdb0b17aa1533d8d46ff1`
- Rider Services catalog SHA-256:
  `e17d1e485c986a0ebab994cd49e5637a44f6aa49fffdc19a6d6c1dbbc8117770`
- Development deployment: `dpl_AGi1sxNXx73B8RMdjLYmDjST9KM5`
  (`pack-fabric.vercel.app`)
- Production deployment: `dpl_fqgrapEVk7knc2Ft67MhjvkUgj34`
  (`dirt-mayday.vercel.app`)

The live audit verified all 252 advertised objects: 126 graph/geometry files,
63 fuel files, and 63 Rider Services files. The fuel publication changed no
graph or geometry catalog identity. No graph or geometry object was rebuilt.

The accepted regional data contains 191,234 fuel stations, 59,990 campground
records, 88,049 lodging records, and 21,443 liquor records. Every advertised
region has data in every category.

## Porters Lake acceptance fixture

The production viewport around Porters Lake returned:

- NSLC, OSM node `1934115098`, at `44.743306, -63.282089`;
- four raw campground records around Porters Lake Provincial Park, collapsed
  by the iOS 450-metre campground deduper to the appropriate map presentation;
  and
- 668 Nova Scotia fuel stations from the canonical fuel sidecar.

The observed production request completed in 542 ms from the packed R2 source
and 104 ms from the service memory cache. The fuel request completed in 393 ms.

## Verification record

- Backend suites: 263 passed, 0 failed, 4 intentionally skipped.
- iOS unit/integration target: passed.
- DIRT Dev physical-device build: passed and installed on RED.
- DIRT Production Release simulator build: passed.
- Frozen route-planning and shared-routing source directories have no changes
  in the accepted Rider Services commit.

## Change boundary

Do not casually replace these files or reintroduce a runtime Overpass fallback.
A future data refresh must build new immutable Rider Services objects, validate
all records, publish objects before the catalog, and preserve the separation
from graph activation. A behavioural change requires a focused DEV build,
physical layer test, Android contract reconciliation, and a new acceptance
record.

## Android status

The exact Android behaviour, storage, diagnostics, automation, and physical
test requirements are documented in [ANDROID-PARITY.md](ANDROID-PARITY.md).
Android implementation, automated testing, and physical qualification remain
unproven; the iOS pass must not be represented as Android completion.
