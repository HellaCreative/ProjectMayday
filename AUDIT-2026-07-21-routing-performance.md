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

## Stage 1a: bidirectional A*

### Implementation

- Flag: `ROUTING_BIDIR_ASTAR=1` (default off).
- Dual-frontier Dijkstra (heap ordered by g). Stop only when `peekFwd.g + peekRev.g >= mu` (best meeting cost). Do not stop on first frontier contact.
- Undirected edges: reverse relaxation uses the same profile cost as forward.
- Engine debug label when on: `dirt-node-bidir-astar`.

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
