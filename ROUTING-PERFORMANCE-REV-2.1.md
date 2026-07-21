# ROUTING PERFORMANCE ADDENDUM: REV 2.1 DELTA

Amends `ROUTING-PERFORMANCE-ADDENDUM.md` (rev 2). Where this delta conflicts with rev 2, this delta wins. Scope of this pass: Stage 0, then Stage 1. Stages 2 to 4 are not authorized.

## 1. Stage 0 identity: equality surface

Replace "byte-identical" with: identical route result body for the same request, compared on `status`, `distanceMeters`, `geometry`, `segments` (ids, surfaces, lengths), and profile stats. Explicitly excluded from comparison: timing fields, `loadMs`, `debug`, and anything wall-clock derived.

## 2. Stage 0 memory policy (default, not improvised)

- Retain inflated packs for the duration of one `routeCanadaChain` request.
- LRU cache capped at 3 inflated regional/longhaul packs per isolate.
- No `vercel.json` memory changes unless Stage 0 benchmarks demonstrate OOM, in which case stop and report; do not tune memory unilaterally.
- Implement exactly this policy and record it in the audit. Do not invent a third policy.

## 3. Stage 0 instrumentation (required in benchmarks)

Per chain run, report: hop count, pack loads vs cache hits, and a best-effort split of inflate/parse ms vs search ms. This determines whether Stage 0 consumed the two minutes or Stages 1 and 2 still carry weight.

## 4. Stage 1 benchmarks: two measurements

- Full end-to-end NS-to-BC (user-facing, request to route-ready).
- Search-only: sum of A* time across hops (per-hop `searchMs` in debug output is acceptable).
Stage 1 acceptance is judged on the search-only number; the end-to-end number is reported for context.

## 5. Bidirectional A* on undirected edges

For edges with `direction: "both"`, reverse relaxation uses the same profile cost as forward. A distinct reverse cost applies only to genuinely one-way edges. Do not invent a separate reverse cost model.

## 6. `direct` profile correction

`direct` is surface-neutral in code and stays that way. `direct` = tight ellipse factor + length-dominant, corridor-biased costing. Dirt preference belongs to `dirt` only. Rev 2's "dirt-preferring cost" language for `direct` is struck.

## 7. Flags and defaults

- `ROUTING_CHAIN_CACHE=1` (Stage 0). Default off. Flip default on only after the Stage 0 audit section shows parity on the equality surface plus benchmark numbers.
- `ROUTING_BIDIR_ASTAR=1` (Stage 1a). Default off until fixtures pass under the parity definition (cost less than or equal, same profile).
- `ROUTING_ELLIPSE_PRUNE=1` (Stage 1b). Default off. Even when on, `dirt` remains unpruned unless `ROUTING_ELLIPSE_DIRT=1` is also set (separate, default off).

Fixtures run twice: flags off (baseline) and flags on (candidate). Defaults change only after audit numbers land.

## 8. Scope freeze for this pass

Stage 0, report, then Stage 1. Additionally out of scope: hop-streaming UI, longhaul pack rebuilds, `vercel.json` changes (except the OOM stop-and-report above), and anything from Stages 2 to 4.

## 9. Audit

File: `AUDIT-<date-work-starts>-routing-performance.md` at repo root. The Stage 0 section must be complete (parity result, policy implemented, instrumentation numbers, benchmarks cold and warm) before any Stage 1 code lands. Append the Stage 1 section to the same file.

## Sequencing confirmation

Stage 0 → full Stage 0 audit section → Stage 1a → Stage 1b → Stage 1 audit section. Nothing else.
