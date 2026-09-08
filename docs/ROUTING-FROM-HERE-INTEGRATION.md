# From Here integration checkpoint

The replacement now builds a single-region route from two fixed rider pins,
using actual Nova Scotia roads and the canonical fuel-station catalog. Station
matching, fuel-aware search, exact route geometry and destination fuel checks
run together. This is an isolated local implementation, not the app's live engine.

## Repeated real-map tests

Three fresh processes each ran these six cases. All 18 produced complete road
geometry and their expected fuel outcome; repeated geometry and selected stops
were identical. Timings include matching, search, geometry and fuel arithmetic,
but exclude pack loading. Later cases reuse road preparation. These three-sample
medians are not live-service percentiles.

| Case | Route | Planned stops | Median | Fuel outcome |
| --- | ---: | ---: | ---: | --- |
| Southwest NS, 300 km full range / 10% reserve | 480.9 km | 1 | 0.959 s | Provisional station access |
| Same ride, 180 km full range / 10% reserve | 480.9 km | 3 | 0.629 s | Provisional station access |
| Nearby destination | 23.6 km | 0 | 0.461 s | Provisional destination fuel access |
| Original selected station record removed | 480.9 km | 2 replacements | 0.633 s | Provisional station access |
| Station catalog deliberately empty | Road preserved | No verified plan | 0.233 s | Explicit missing station bindings |
| Starting fuel deliberately unknown | Road preserved | No verified plan | 0.511 s | Explicit unknown starting fuel |

The standard long ride plans Irving at Mahone Bay around route kilometre 235.8.
Its destination arrival retains 24.8 km of **usable** range, with a matched onward
pump 5.8 km away by the directed road graph. The protected 30 km reserve is not
spent in that calculation. These figures remain conditional on station access.
The benchmark deliberately supplies a full starting tank; the actual product's
unknown estimate is never silently converted to full.

## What the larger batch caught

- Free refills initially scheduled ten stops along the standard ride. Fewer
  refills now break otherwise equal route costs, yielding one necessary stop
  without changing its road geometry. Fuel remains part of search, not a later
  insertion/rebuild loop. The independent exhaustive oracle now checks refill
  count as well as feasibility and route cost.
- An empty catalog initially caused 18 seconds of futile fuel-state exploration
  and about 1.2 GiB peak process memory. A known-empty binding set now returns
  unverified fuel promptly after preserving road geometry. A separate experimental
  cap of 100,000 admitted fuel labels bounds further fuel-state growth and reports
  incomplete search instead of geographic scarcity. This is not a byte-memory
  guarantee or a cap on ride length. Peak process RSS in the final six-case batches
  was 382 MiB; service concurrency remains unqualified.
- All 671 station records found eligible road candidates. Ninety-four records
  shared an already represented road position. Their identities and match evidence
  remain visible as alternatives; they are not asserted to be the same physical
  facility. Removing one record is not complete real-world closure handling.

## Riding quality

The initial long ride contains 49.6% known dirt. Separate experimental preferences
found a 596.8 km route containing 60.6% known dirt, with three planned stops, in
about 0.9 seconds including cold preparation. Two stronger weights produced the
same route; that does not prove it is the best dirt ride available. No final
profile tuning was adopted from this comparison.

The audited long variants contain no repeated road intervals or revisited graph
nodes. The initial long ride's longest continuous dirt run is 64.8 km; the stronger
variant's is 39.4 km. The nearby ride contains only 13.9% dirt and its longest dirt
run is 685 m. These are useful quality flags, not acceptable Dirt results by fiat.
Coherent candidate generation/selection still needs improvement.

## Fuel-access boundary

A station POI matched to a legal road within the experimental 150 m search radius
is **not** a verified entrance/exit. No straight access road, midpoint turnaround
or inter-road connection is invented. Projected bindings retain
`legal_road_projection` evidence, and the resulting plan remains
`provisional_station_access`, even if its distance arithmetic passes. For example,
the selected Mahone Bay POI is 23 m from its matched road position. Unmapped
forecourt travel and current operation are not proved by that match.

Verified-only graph/proof behavior remains the default outside the explicit
experiment. Rider fuel anchors retain their original pins and are non-movable;
generated stops are identified separately. Materialized advisory geometry survives
fuel failure. Failures before any road is built cannot manufacture a complete route.

## Verification and next work

135 automated checks pass, including encoded-map integration fixtures, fuel-driven
road changes, fixed fuel destinations, missing/removed stations, unknown initial
fuel, one-way preservation, provisional-evidence handling and the fuel label cap.
The 250-network independent oracle makes 500 accelerated/plain comparisons.

The next priorities are station-access qualification and improved Dirt candidate
selection, then the live API adapter. Multi-region rides, Plan orchestration,
Loop generation, navigation and physical acceptance remain unfinished. Quebec
restriction investigation has resumed in a separate agent; see
[the large-graph audit](ROUTING-LARGE-GRAPH-AUDIT.md). No pack, deployment or phone change was
made for this checkpoint.

Code: `scripts/pack-fabric/routing/lib/adventure/from-here.js`.
Replays: `npm run bench:from-here` and `npm run bench:from-here-matrix`, with
`REBUILD_PACK_ROOT` pointing at the preserved candidate02 packs. Evidence:
`routing/candidates/rebuild-from-here-matrix/` (including `quality-audit.json`),
`rebuild-from-here-weight30/` and `rebuild-from-here-weight100/` within this worktree.
