# AUDIT 2026-07-21: routing performance

Amends authority: `ROUTING-PERFORMANCE-ADDENDUM.md` (rev 2) + `ROUTING-PERFORMANCE-REV-2.1.md` (wins on conflict). Scope this pass: Stage 0, then Stage 1a, then Stage 1b.

Environment for all Stage 0 numbers below: local Node `v22.17.0`, `VERCEL=1` (canada-chain path for NS-BC), `--max-old-space-size=2048`. Profile: `cleanest`.

---

## Stage 0: chain pack cache

### Policy implemented (exact, no third policy)

- Flag: `ROUTING_CHAIN_CACHE=1` (default off).
- When off: clear inflated pack cache between every canada-chain hop (legacy behavior).
- When on: retain inflated packs for the duration of one `routeCanadaChain` request; do not clear between hops.
- LRU cap: 3 inflated packs in `packCache` and 3 in `dataCache` (`routing/lib/graph.js`).
- No `vercel.json` memory changes. No OOM observed in Stage 0 benches; stop-and-report threshold not triggered.

### Equality surface (parity)

Compared baseline (flag off) vs candidate (flag on) on: `status`, `distanceMeters`, geometry head/tail + length, segment signatures `(edgeId, surfaceClass, distanceMeters)`, and profile/hop stats. Excluded: timing, `loadMs`, `debug`, wall-clock fields.

Result from `scripts/bench-stage0-routing.js` with `STAGE0_BASELINE_FILE`:

```
PARITY_VS_BASELINE {"short-ns":true,"mid-hfx-yarmouth":true,"ns-bc":true}
```

### Fixtures

- Flags off: `node routing/test/run-fixtures.js` - 12/12 PASS.
- Flags on (`ROUTING_CHAIN_CACHE=1`): 12/12 PASS.
- Adapter/conflation: `node routing/test/adapters/canada-pipeline.test.js` - 19 PASS.

### Instrumentation (NS-BC chain, cold run)

| Metric | Flag off | Flag on (`ROUTING_CHAIN_CACHE=1`) |
| --- | ---: | ---: |
| hops | 15 | 15 |
| pack loads / cache hits | 22 / 0 | 8 / 14 |
| inflateMs (sum) | 10720 | 5068 |
| searchMs (sum of A* across hops) | 2466 | 3069 |
| end-to-end cold ms | 23951 | 20367 |
| end-to-end warm ms | 24571 | 22761 |
| distance km | 6510 | 6510 |

Notes:

- Short and mid suites are single-pack / non-chain; `packLoads`/`inflateMs` stay unset on those responses (expected).
- Bench clears cache at the start of each request, so "warm" is process warm, not cross-request pack retention. Retention is request-lifetime within the chain, as specced.
- searchMs variance between off/on is not a Stage 0 acceptance signal; Stage 0 win is inflate/load reduction and e2e.

### Stage 0 verdict

Stage 0 accepted: parity on equality surface, policy matches rev 2.1, instrumentation shows inflate/load cut roughly in half on NS-BC, e2e cold improved ~15% locally. Default later flipped on after median-of-three (see bottom of this audit).

---

## Stage 1a: bidirectional Dijkstra

### Implementation

- Flag: `ROUTING_BIDIR_ASTAR=1` (env name retained; implementation is bidirectional Dijkstra).
- Dual-frontier Dijkstra (heap ordered by g, no heuristic). Stop only when `peekFwd.g + peekRev.g >= mu` (best meeting cost). Do not stop on first frontier contact.
- Undirected edges: reverse relaxation uses the same profile cost as forward.
- Engine debug label when on: `dirt-node-bidir-astar` (legacy name; search is g-ordered Dijkstra).

### Parity (cost ≤ under same profile)

In-region fixtures (porters, hfx-yar, direct-short, dirt-short): candidate profileCost identical to baseline (delta 0). Fixtures 12/12 PASS flags off and `ROUTING_BIDIR_ASTAR=1`.

### Benchmarks (local Node v22.17.0, NS-BC cleanest, cold, cache off)

| Config | searchMs (sum) | e2e ms | km |
| --- | ---: | ---: | ---: |
| baseline (all flags off) | 2604 | 27037 | 6510 |
| `ROUTING_BIDIR_ASTAR=1` | 2086 | 24042 | 6510 |

Search-only drop vs baseline: about 20%. Acceptance judged on search-only per rev 2.1.

Mid-route (Halifax-Yarmouth): baseline searchMs 170, bidir 133 (cost identical).

---

## Stage 1b: ellipse prune

### Implementation

- Flag: `ROUTING_ELLIPSE_PRUNE=1` (default off).
- Factors: `direct` 1.2, `cleanest` 1.4, `balanced` 1.5, `dirt` 2.2 but dirt stays unpruned unless `ROUTING_ELLIPSE_DIRT=1`.
- Escalation: initial → widen 1.25x → widen 1.6x → unpruned fallback. Sanity cost bound rejects over-tight results and widens.
- `direct` costing remains surface-neutral; ellipse is the corridor bias only.

### Parity

Same cost-parity pairs as Stage 1a: delta 0 vs baseline with ellipse on (and bidir+ellipse). Dirt escalation label `dirt_disabled` when ellipse on without `ROUTING_ELLIPSE_DIRT`. Fixtures 12/12 PASS for ellipse alone and bidir+ellipse.

### Benchmarks (NS-BC cleanest, cold)

| Config | searchMs | e2e ms | km |
| --- | ---: | ---: | ---: |
| ellipse only | 2174 | 24455 | 6510 |
| bidir + ellipse | 1996 | 24649 | 6510 |
| cache + bidir + ellipse | 2251 | 19085 | 6510 |

Escalation on short/mid fixtures: `initial` (no widen needed). Dirt: `dirt_disabled`.

Search-only vs baseline: bidir+ellipse about 23% faster. Combined with Stage 0 cache, e2e cold NS-BC about 19s locally (vs ~27s baseline).

### Stage 1 verdict

Stage 1a and 1b accepted behind flags. Fixtures pass both ways. Cost parity holds (≤ / identical on measured pairs).

---

## Default flip (2026-07-21 median-of-three)

Protocol: three paired runs each for porters (balanced), Halifax-Yarmouth (cleanest), NS-BC (cleanest). Candidate = `ROUTING_CHAIN_CACHE` + `ROUTING_BIDIR_ASTAR` + `ROUTING_ELLIPSE_PRUNE` on. `ROUTING_ELLIPSE_DIRT` left off.

| Suite | costOk | distOk | off search median | on search median | off e2e median | on e2e median |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| porters-balanced | true | true | 22 | 27 | 3142 | 2615 |
| hfx-yar-cleanest | true | true | 173 | 125 | 3023 | 2537 |
| ns-bc-cleanest | true | true | 2606 | 2523 | 23030 | 18019 |

NS-BC hopKm identical (15 hops, same per-hop km). Equality-surface byte match is exact on in-region suites; NS-BC shows equal-cost geometry variance (geomLen 31174 vs 31167, +1 segment) which Stage 1 explicitly allows. Pack loads on NS-BC candidate: 8 loads / 14 hits; inflateMs median roughly 3.9s vs ~9.8s off.

**Defaults flipped on:** `ROUTING_CHAIN_CACHE`, `ROUTING_BIDIR_ASTAR`, `ROUTING_ELLIPSE_PRUNE` (unset = on; set `0` to disable).

**Remains default off:** `ROUTING_ELLIPSE_DIRT` (waits for fixture evidence on bowing corridors such as Superior).

---

## Stage 2: binary packs (`graph.v2` + `geometry.v1`)

### Spec conflicts resolved in implementation (reported)

1. Addendum bit widths (2 bits access/structure) cannot encode current enums (5 access, 7 structure). Implemented as 3+3+3+2+1 in `u16` (`routing/lib/pack-v2.js`).
2. "Router never reads geometry sidecar" conflicts with snap matching and route geometry output. Interpretation: sidecar is **not** read during relax; it **is** read for snap + path reconstruction only. Documented here so Stage 3 does not re-litigate.
3. Multi-pack corridor merge/clip still requires v1 JSON edge polylines. `ROUTING_PACKS_V2` applies to **single-pack** loads (regional fixtures + per-hop longhaul). Multi-pack merge stays on `graph.v1` until a follow-up.

### Format header (`graph.v2.bin`)

Little-endian header (72 bytes):

| Offset | Field |
| ---: | --- |
| 0 | magic `0x32473244` |
| 4 | version `u16` = 2 |
| 6 | flags `u16` (bit0 = has edgeFrom/edgeTo) |
| 8 | nodeCount `u32` |
| 12 | undirectedEdgeCount `u32` |
| 16 | directedArcCount `u32` |
| 20 | headerBytes `u32` |
| 24..60 | section offsets: nodeOffsets, edgeTargets, edgeUndirectedIndex, edgeAttrs, edgeMeters, nodeCoords, idOffsets, idBlob, enumsJson, metaJson |
| 64..68 | edgeFrom, edgeTo |

CSR: `nodeOffsets` / `edgeTargets` / `edgeUndirectedIndex`. Attrs bitfield: surface3|access3|structure3|confidence2|seasonal1. Lengths quantized metres (`u32`). Stable IDs in UTF-8 blob. Enums/meta as small JSON tails (not topology).

`geometry.v1.bin`: magic `GEOM`, per-edge offsets into float32 lon/lat pairs. Built beside each pack via `node scripts/build-graph-v2.js`.

### Files changed

- `routing/lib/pack-v2.js` (encode/decode)
- `routing/lib/profile-costs.js` (Stage 2c weight tables)
- `routing/lib/find-path-v2.js` (CSR uni search, no per-relax geometry)
- `routing/lib/graph.js` (load path when `ROUTING_PACKS_V2=1`)
- `routing/lib/router.js` (dispatch v2; deferred geometry on v1 neighbors; profile-costs)
- `scripts/build-graph-v2.js`

Binary packs are **build artifacts** (not committed): `graph.v2.bin`, `geometry.v1.bin`, `longhaul.v2.bin`, `longhaul.geometry.v1.bin`. Generate with `node scripts/build-graph-v2.js --ns` or `--longhaul-corridor`.

### Flag

`ROUTING_PACKS_V2` default **off**. Explicit `1` enables. `graph.v1` path remains.

### Fixtures / parity

- Flags off: 12/12 PASS.
- `ROUTING_PACKS_V2=1` + `ROUTING_USE_REGIONAL=1` (and Stage 1 search flags off for apples-to-apples uni): 12/12 PASS.
- Porters balanced: same segment id head/tail; distance 17263 vs 17264 m (1 m access-leg float32 drift); profileCost delta ~1.7e-4.
- Halifax-Yarmouth cleanest: same km 332; profileCost delta ~3.8e-5.

### Benchmarks (median of 3, local Node v22.17.0)

| Suite | cfg | load median ms | search median ms | e2e median ms | km |
| --- | --- | ---: | ---: | ---: | ---: |
| porters balanced | v1 | 3266 | 26 | 3294 | 17 |
| porters balanced | v2 | 138 | 2 | 142 | 17 |
| hfx-yar cleanest | v1 | 3713 | 110 | 3818 | 332 |
| hfx-yar cleanest | v2 | 117 | 45 | 177 | 332 |
| ns-bc cleanest chain | v1 | (inflate 4170) | 2119 | 18683 | 6510 |
| ns-bc cleanest chain | v2 | (inflate 4015) | 1595 | 17647 | 6510 |

In-region pack load drops from seconds to ~100-200 ms. Search also faster on CSR uni path. Chain e2e improvement is smaller because hop I/O still dominates; v2 searchMs sum is lower.

### Blocked / follow-ups

- Port Stage 1 bidir + ellipse into `findPathV2` (currently unidirectional Dijkstra only when `ROUTING_PACKS_V2=1`).
- Multi-pack merge/clip on v2.
- Delta/polyline5 compression for geometry sidecars (float32 raw for now).
- Do not delete `graph.v1` until those land and defaults flip after another audit pass.
- `ROUTING_PACKS_V2` stays default off.
