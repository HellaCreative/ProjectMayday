# Native fuel preparation candidate

Private continuation of the device-first GraphHopper–DIRT experiment. The physical
White road checkpoint remains `4693beaab672cb84d96ded047fd3d07c56f7556b`.
This subsequent candidate is measured on macOS, not on White. No accepted app,
server, published pack, download policy, or Android product behavior changes.

## Measured problem and implementation

The actual native `PackRoutingSource.fuelChain` method is extracted byte-for-byte
from the main checkout into an instrumented single-installed-NS facade. The
facade calls the real pinned Swift router. This exercises fuel ranking and all
its actual road/reachability calls, rather than substituting a toy fuel solver.
The build receipt records the captured method and source hashes.

The first Clean request, 120-mile range and one required stop, exceeded a
45-second external guard. It had finished its initial road search and was still
matching fuel stations. A bounded stack sample located all worker samples in
`reachableGraphMeters → nearestEdgeSnaps`, dominated by geometry projection and
CoreLocation distance/allocation. The internal deadline did not cover that work.
The geographic station prefilter retained 486 of the 671 NS stations for this
specific itinerary. A separate whole-pack match comparison covers all 671.

The private generated-source patch:

- Indexes complete source-geometry bounds, including curves outside endpoint
  boxes. Conservative geographic query bounds precede the existing detailed
  projection and distance calculations. No road costs or access rules change.
- Keeps unusually broad edges in a small overflow list instead of duplicating
  them into thousands of cells. Every query can still discover them.
- Caches completed fuel matches by immutable pack/geometry instance, exact
  coordinate bits, profile and unknown-access policy. The default limit is 1,024
  point/profile entries, at most 12 directed matches each. Eviction causes
  rematching, never removal of roads. The smaller 64-entry test forces eviction.
- Checks cancellation during index building, station iteration and geometry
  projection. An interrupted index or match is not cached or published.
- Resolves equal-distance/equal-score ties by edge index and direction. The
  original dictionary iteration could select different coincident roads at the
  12-candidate cutoff. This is a disclosed behavior refinement, not byte-exact
  preservation of every original capped match list.

The cache limits apply to **station matching results**, not road topology,
geometry residency or spatial cells. The full NS graph remains decoded. Testing
5,000/10,000/30,000-road working sets would not describe this implementation.
The index retains bounds/buckets; it does not retain decoded road polylines.
Both caches retain metadata for one pack instance and invalidate when the graph
or geometry object changes. Immutable input bytes are a required contract.

## Evidence

The first continuity rerun exposed a diagnostic weakness: the synthetic
`restriction:motor_vehicle` case was expected to fail closed, but the probe's V2
reader path did not expose that vehicle mask to the publication gate. That result
was rejected. The corrected fresh `native-fuel-v7` build exposes the decoded
restriction masks and passes **22/22** isolated continuity checks, including
unsupported-scope rejection. The spatial-index fixture rerun passes **12/12**.

Initial isolated matching comparison, all 671 NS stations:

| Mode | First pass | Repeat in same process |
| --- | ---: | ---: |
| Original broad search, with diagnostic cancellation/metrics | 65.211 s | Not repeated |
| Geometry index, no match cache | 0.838 s | 0.709 s |
| Geometry index and bounded match cache | 0.805 s | 0.073 s |

The broad pass projected 9,039,024 edges / 54,193,489 segments. The indexed pass
projected 111,683 edges / 419,572 segments. First cached pass had 57 hits from
duplicate station coordinates; the repeat had 671 additional hits. Match timing
includes JSON evidence serialization, but excludes pack validation/decode.

The final filter verification projected the broad reference area as well as the
indexed area: **zero qualifying reference segments omitted**, across all 671
stations and 54,242,539 projected reference segments. This is stronger than
comparing only the top 12 matches. It is still a finite regional check, not a
proof for all data. The reference verification is intentionally slow (74.546 s).
Final telemetry-only build changes do not alter the verified routing/index source.

Cross-process CoreLocation distance values varied by up to 0.037 m for matching
distance and 0.076 m along-edge among common candidates in the initial comparison.
Common source projections were identical. Some capped lists chose different
coincident source edges; the tie-break refinement addresses that instability.
Do not describe all original match JSON as exact. Full route comparisons and
their practical limits are recorded in the accompanying evidence.

Twelve index fixture checks pass, covering curved geometry, polar longitude
extent, broad-edge allocation and empty matches across legacy/indexed/cached
modes. The improved index discovers nearby roads missed by the original index
in the curve and polar fixtures. These are isolated synthetic OSM bytes, not
rebuilt published packs.

## Fuel continuity gate

The native planner passes prior roads and arrival edge as backtracking penalties.
That does **not** preserve legal incoming turn state between separately searched
legs. The private Swift publication gate replays the selected ordered source walk
through one V4 turn automaton, with zero resets at fuel stops. It checks source
identity, directed access, connectivity, source-bound distances, full and reduced
starting range, required/excluded stations, and supported request fields. A
same-edge partial traversal split at a refill is coalesced into one traversal.

The corrected v7 gate passes twenty-two fixture checks, including node and
via-way restrictions split across refills, an allowed alternative arrival,
only-turn continuation, one-way and private-road rejection, short-distance
forgery, unsupported vehicle scope, unsupported history and unmapped pump
approaches. The independent JavaScript V4 oracle shows that the
forbidden node/via-way/only-turn cases are individually legal when each leg's
history is reset, but illegal as a continuous journey.

The gate is deliberately conservative: a synthetic road-to-pump line is not
certified physical access. Unproved mid-edge turnaround/rejoining is incomplete.
Rider endpoint approaches remain explicit. Pump existence in a pack does not
establish availability, hours, physical entrance or guaranteed fuel stock. This
gate checks a candidate; it does not make the heuristic planner complete or
automatically repair an invalid continuation.

## Reproduction and boundaries

Tooling is under `scripts/routing-architecture/device-workload/fuel/`:
`build-fuel-probe.py`, `run-matrix.py`, `check-matching-index.js`,
`check-continuity.js`, and `audit-native-fuel.py`. Builders and fixture runners
require new output directories. The builder starts from the content-verified
`native-v6-cancel` snapshot; it never patches main app files.

Full local evidence root:
`/Users/richardsmith/.codex/experiments/routing-architecture-20260911/device-workload`.
Use `native-fuel-v7`, `fuel-matrix-v5`, `matching-legacy-v3.guard.*`,
`matching-verify-v4.guard.*`, `index-fixtures-v8` and `continuity-v8`.
Build receipts pin the compiler invocation, source inputs, generated Swift and
unchanged captured fuel method. Compact committed evidence pins artifact hashes.

All performance is local, serial and limited to NS. A fresh process is not an
OS-storage-cold test. Resident memory, physical footprint, retained caches and
input-block counters are reported separately; block counts are not exact bytes
read or an assurance that mapped pages were never reread. The original published
graph/geometry/fuel files are read and decoded once per process by the diagnostic;
the validation/decode phase still performs duplicate preparation. No hosted
capacity or iPhone fuel result is claimed.

The indexed/cached matching comparison remains the verified v5 result: broad
matching took 65.211 s for all 671 stations, indexed matching 0.838 s on its
first pass, indexed plus bounded caching 0.805 s on its first pass and 0.073 s
on repeat. The broad-area verification omitted zero qualifying reference
segments. The corrected v7 build changes only continuity diagnostics; it does
not change the captured router, matching index or cache source hashes. Clean
fuel candidates in the local matrix complete in 3.34–3.86 s; Dirt and Balanced
still exhaust their 30 s diagnostic budget after repeated road calls.

Cancellation remains cooperative. Pack decode, whole-graph allocations and some
other preparation paths are not fully interruptible. Unsupported settings and
incomplete results must retain the last valid itinerary and must not trigger an
automatic server request. The accepted app has not yet adopted this gate or patch.
Full native/server preference, waypoints, fuel-history, larger/multi-region and
device qualification remain open. No production-qualified device record is added.

Rollback is simply leaving this private candidate unintegrated. Preserve the
White milestone and server checkpoint `e211ea9b88d8224bea45aab303ca86af2828a791`.
