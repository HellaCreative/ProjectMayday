# Cursor prompt: routing performance (rev 2.1)

Paste this into Cursor:

---

Read `ROUTING-PERFORMANCE-ADDENDUM.md` (rev 2) and `ROUTING-PERFORMANCE-REV-2.1.md` in the repo root. The 2.1 delta wins wherever they conflict. It resolves your nine review items: equality surface for Stage 0 parity, a fixed cache policy (request-lifetime retention, LRU cap 3 inflated packs, no vercel.json changes except OOM stop-and-report), required cache instrumentation, split end-to-end vs search-only benchmarks for Stage 1, undirected-edge reverse costing, the `direct` profile corrected to surface-neutral corridor costing, named flags with defaults, the scope freeze, and the audit convention.

You are authorized to execute Stage 0 now. Complete the Stage 0 audit section (parity on the equality surface, policy as specced, instrumentation numbers, cold and warm benchmarks) before any Stage 1 code. Then execute Stage 1a, then 1b. No Stages 2 to 4. No hop-streaming UI, no longhaul pack rebuilds.

Flags: `ROUTING_CHAIN_CACHE`, `ROUTING_BIDIR_ASTAR`, `ROUTING_ELLIPSE_PRUNE`, `ROUTING_ELLIPSE_DIRT`. All default off. Fixtures run flags-off (baseline) and flags-on (candidate). Defaults flip only after audit numbers.

Audit file: `AUDIT-<date-work-starts>-routing-performance.md` at repo root, appended per stage.

Do not modify NRN ingest, adapters, conflation, or schema code unless the specs explicitly require it. Do not touch route colors, navigation cues, POI behavior, or map styling. If the specs conflict with the codebase, stop and report rather than improvising.

No em dashes anywhere, including code comments.
