# ROUTING PERFORMANCE ADDENDUM (rev 2)

Companion to `routing/README.md`. Incorporates the implementation review of rev 1.

Note on `ROUTING.md`: treat it as historical product intent (Valhalla-era). The live stack is the custom Node A* over NRN/provincial packs. This addendum is the implementation source of truth for performance work.

## Purpose

Cross-province routes (NS to BC) take on the order of one to two minutes through the current `canada-chain` path. Target: under one second, on-device, offline. This document specifies the path. Each stage is independently shippable.

## Where the time actually goes (revised diagnosis)

Production long-haul currently runs `canada-chain` with thinned longhaul packs, calls `clearGraphCache()` between hops, and fetches packs remotely per request. The cost is therefore a mix of:

1. Pack I/O and re-inflation on every hop (cache cleared, remote fetch, gz decompress, JSON parse).
2. JSON pack format: object-per-node/edge allocation and GC pressure.
3. Flat A* over full-detail graphs within each hop.

Stage 0 attacks (1) directly. Stage 1 attacks (3). Stage 2 attacks (2) and most of (1). Stages 3 and 4 restructure long-haul so the problem largely disappears.

## Profile name mapping

Docs may say Clean / Balanced / Dirt / Direct. Code uses `cleanest | balanced | dirt | direct`. The code identifiers are canonical everywhere in this addendum.

## Sequencing

The AB/BC/ON/QC NRN conflation work is merged. Nothing in that pipeline blocks any stage. Implement one stage at a time, prove parity, then move on. Stage order: 0, 1, 2, 3, 4.

---

## Stage 0: Cache and fetch hygiene in the chain path (do this first)

Smallest change, targets the largest current cost. No algorithm or format changes.

- Stop calling `clearGraphCache()` between chain hops. Retain loaded graphs across hops within a single route request, bounded by a simple memory cap with LRU eviction if needed.
- Cache fetched pack bytes for the lifetime of the request at minimum; add cross-request caching where the runtime allows.
- Do not change route results in any way. This stage is pure I/O and lifetime management.

Acceptance:
- Route results byte-identical to current production for the same requests.
- Full-chain NS-to-BC wall time drops materially; report before/after.

---

## Stage 1: Search-level wins (no data changes)

### 1a. Bidirectional A*

Run the search from both ends. Correct termination is required: do NOT stop at first frontier contact. Stop only when the best known meeting cost is provably minimal under the profile's cost function. Profile costs are asymmetric-capable and surface-weighted; the reverse search must use the reverse edge relaxation of the same cost model.

Parity definition for fixtures: replacement route cost must be less than or equal to the current route cost under the same profile. Geometry may legitimately differ at equal cost; fixtures should assert cost, not exact polyline.

### 1b. Ellipse pruning (bounded heuristic, not exact)

Exactness statement, resolving the rev 1 conflict: the "no approximate routing" rule in this addendum applies to Stages 0, 2, 3, and 4, which are exact. Stage 1b is explicitly a bounded heuristic and is documented as such.

Mechanics:
- Skip expanding any node where `dist(A,node) + dist(node,B) > detourFactor * dist(A,B)` (haversine).
- Escalation: if no route is found, or the found route's cost exceeds a sanity bound, automatically widen `detourFactor` and retry; final fallback is an unpruned search. Escalation must be automatic and invisible to the rider.
- Per-profile configuration:
  - `direct`: tight factor (1.15 to 1.25). The corridor bias IS the product intent of this profile.
  - `cleanest`: moderate (around 1.4).
  - `balanced`: moderate-loose (around 1.5).
  - `dirt`: DISABLED by default. Dirt corridors bow (for example, routing around Lake Superior); pruning here risks cutting the routes the profile exists to find. May be enabled later with a loose factor only after fixture evidence.
- All factors live in one config block, flagged.

Acceptance for Stage 1:
- All fixtures pass under the parity definition above.
- Long-route search time drops materially with escalation rate reported (how often widen/fallback triggered across fixtures).

---

## Stage 2: Binary packs, split geometry from topology (the iOS unlock)

Unblocked (conflation merged). Migration risk is the main risk; keep `graph.v1` behind a flag until parity is proven.

### 2a. `graph.v2`: flat binary typed arrays, CSR layout

- `nodeOffsets`: Int32Array, length nodeCount + 1.
- `edgeTargets`: Int32Array.
- `edgeAttrs`: bit-packed per edge: surface class (3 bits), access (2 bits), structure flags (2 bits), provenance (2 bits), extending as `routing/schema/enums.js` requires.
- Edge length stored once (quantized metres); per-profile costs are DERIVED (see 2c), not stored four times.
- `nodeCoords`: Float32Array (lon, lat) pairs for heuristics and pruning only.
- Stable segment IDs preserved via a parallel array or sidecar index, because rider reports, `avoidEdgeIds`, and the confidence engine attach to segment IDs.

Serialize as raw ArrayBuffers with a small header (magic, version, counts, offsets). Load by slicing typed-array views, zero parse. Browser: fetch + ArrayBuffer. iOS: memory-mapped files. Same bytes both places.

### 2b. Geometry sidecar

Remove polylines from routing packs. Per-region `geometry.v1` sidecar (delta or polyline5 encoded), loaded only for drawing and corridor rendering. The router never reads it.

### 2c. Profile costs as derivation

Neutral edge facts stored once; the four profile cost functions live in one config file and are applied at load into cost views or inline in the relax loop. Tuning a profile never rebuilds packs.

Acceptance:
- Pack load drops from seconds to tens of milliseconds.
- Fixtures pass with costs identical to `graph.v1` derivation.
- `graph.v1` path removed only after parity across all fixtures and a full-chain benchmark.

---

## Stage 3: National backbone tier (replaces canada-chain)

Explicit supersession: the backbone tier REPLACES the `canada-chain` hop model and the thinned longhaul packs. It must not sit beside them indefinitely. Plan: land backbone behind a flag, prove parity and speed, then delete the chain path and thinned packs in the same release cycle. Three parallel long-haul systems is a failure state.

### 3a. Backbone extraction

During the national build:
- All NRN edges of highway / arterial / major collector classes.
- Dirt trunks: maximal connected chains of unpaved edges above a length threshold (start 15 km, tune). Conflation already provides surface class; this is a filter plus connectivity pass.
- Boundary nodes: backbone-to-region-boundary intersections plus dirt-trunk-to-paved-backbone connection points.

Ship as a single `backbone.v1` binary pack bundled with the app, small enough to stay resident (tens of MB max).

### 3b. Hierarchical query flow

Routes above a straight-line threshold (start 150 km, tune):
1. Snap A and B to containing regions.
2. Full-detail local search inside only those two region packs for exit/entry candidates.
3. Backbone-only solve for the middle.
4. Splice head + middle + tail; report achieved surface mix from edge attrs.

Shorter routes stay within one or two region packs as today.

Acceptance:
- NS-to-BC in roughly 1 to 2 seconds end to end.
- `dirt` routes measurably dirtier than `cleanest` on identical A/B pairs.
- Memory bounded: backbone + two region packs resident for a long route.
- Chain path deleted after flag flips.

---

## Stage 4: Per-profile boundary shortcut tables (sub-second, full offline)

At build time, per region and per profile (`cleanest`, `balanced`, `dirt`, `direct`), precompute least-cost paths between the region's boundary nodes (many-to-many Dijkstra restricted to the region). Store as compact matrices plus path-unpacking data (`shortcuts.v1` section of the pack).

Query-time crossing of an intermediate region becomes a table lookup. Live search only in origin and destination regions. Unpacking reconstructs edges for drawing and surface stats. Shortcuts are exact for the given profile weights; profile tuning re-runs only the shortcut pass.

Acceptance:
- NS-to-BC well under one second on laptop; low single-digit seconds on-device target.
- Results byte-identical to Stage 3 full computation for the same profile weights.

---

## Benchmark protocol (applies to every stage)

Every before/after report must state exactly what was timed:
- Short in-region route, mid-length route, and full end-to-end NS-to-BC.
- NS-to-BC must be timed as the complete user-facing operation (all hops / full hierarchy, request to route-ready), not a single hop.
- Report cold (no caches) and warm (second identical request) separately.
- State the environment (local Node version, or deployed runtime).

## How this aligns with the rest of the product

- Offline downloads become corridor ribbons: backbone ships with the app; a planned route determines exactly which region packs and geometry sidecars to download.
- Rider reports and the segment confidence engine attach to stable segment IDs (preserved in Stage 2) and act as cost adjustments in the derivation layer, never graph surgery. `avoidEdgeIds` applies at the relax step in every stage.
- `direct` mode is a tight ellipse factor plus dirt-preferring cost, not a separate algorithm.

## Non-goals

- No Valhalla / GraphHopper dependency for the client path. Server-side routing is a possible future, not this work.
- No contraction hierarchies over the full national detail graph; boundary shortcuts give most of the benefit with simpler builds and per-profile flexibility.
- No silent approximation: the only heuristic component is Stage 1b, and it is documented, escalating, and per-profile controllable.

## House rules

- No em dashes anywhere, including code comments. (Process rule only, no functional meaning.)
- Each stage lands behind a flag, proves parity on fixtures, then becomes default.
