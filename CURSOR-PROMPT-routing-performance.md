# Cursor prompt: routing performance, Stage 2 authorized

Paste this into Cursor:

---

Stage 0 and Stage 1 are accepted per `AUDIT-2026-07-21-routing-performance.md` and the code review. Before starting Stage 2, do two closeout items:

1. Re-run the Stage 0/1 benchmarks as median of three runs per config and update the audit table (single-run numbers showed noise: warm slower than cold, searchMs drift on an unchanged path).
2. If the median-of-three confirms parity and the wins, flip defaults on for `ROUTING_CHAIN_CACHE`, `ROUTING_BIDIR_ASTAR`, and `ROUTING_ELLIPSE_PRUNE`. `ROUTING_ELLIPSE_DIRT` stays off. Note the flips in the audit. Also correct the audit label: the implementation is bidirectional Dijkstra (g-ordered, no heuristic), which is correct and exact; name it accurately.

Then Stage 2 is authorized: binary packs with geometry split out, per `ROUTING-PERFORMANCE-ADDENDUM.md` (rev 2) section Stage 2, as amended by `ROUTING-PERFORMANCE-REV-2.1.md`. The 2.1 delta wins on conflict.

Stage 2 requirements:

- New `graph.v2` per-region format: flat binary typed arrays, CSR layout (nodeOffsets, edgeTargets, bit-packed edgeAttrs, quantized edge lengths, nodeCoords for heuristics/pruning only). Raw ArrayBuffers with a small header; load by slicing typed-array views, zero JSON parse.
- Stable segment IDs preserved via parallel array or sidecar index. Rider reports, `avoidEdgeIds`, and the confidence engine depend on them.
- Geometry sidecar `geometry.v1` per region: polylines removed from routing packs entirely, loaded only for drawing and corridor rendering. The router never reads it.
- Profile costs derived from neutral edge facts at load or in the relax loop; the four profile weight tables live in one config file. No per-profile stored graphs.
- While rewriting the relax path, eliminate the per-relaxation object allocation and coordinate array copy/reverse in `neighbors()` (identified in review as the dominant search-time constant). Geometry materialization happens once at path reconstruction, not per relaxation.
- Migration safety: `graph.v2` behind flag `ROUTING_PACKS_V2` (default off). `graph.v1` path remains until parity is proven across all fixtures and a full-chain benchmark, then remove it in a follow-up commit.
- Parity definition: fixture route costs identical to the `graph.v1` derivation under the same profile. Equality surface per rev 2.1 item 1 for chain routes.
- Benchmark protocol per rev 2.1: short, mid, full NS-BC; cold and warm; median of three; report pack load ms separately from search ms.

Scope: Stage 2 only. No backbone tier, no shortcut tables, no hop-streaming UI, no vercel.json changes. Do not modify NRN ingest, adapters, conflation, or schema semantics; the pack format is the serialization of existing semantics, not a schema change. If anything in the specs conflict with the codebase, stop and report rather than improvising.

Append a Stage 2 section to the same audit file: files changed, format header spec, flag state, fixture parity results, benchmarks, and anything blocked.

No em dashes anywhere, including code comments.
