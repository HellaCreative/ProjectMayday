# Quebec restriction and large-region audit

September 8, 2026. Local, read-only pack investigation alongside the From Here
integration. No restriction was removed, no pack rebuilt, and nothing deployed.

## Two independent findings

The preparation limit is genuinely a larger-graph issue. Quebec, Ontario and
California all exceed the experimental six-million-operation request allowance
before finishing their spatial index. Reusing completed preparation works, but
its initial cost and resident memory must be accommodated explicitly.

The Quebec restriction is a separate source/representation ambiguity. Ontario
has no equivalent ambiguous via-way entry; California has 25 packed records
across four relation IDs. Region size increases exposure to unusual records; it
does not establish one universal underlying mapping defect.

## Fresh-process measurements

Each region ran in its own Node process against existing local packs. The OS
file cache was not cleared. After a failed six-million-operation preparation,
an explicit 50-million-operation prewarm ran, followed by a normal-budget cache
hit. These are single-run engineering measurements, not latency percentiles.

| Region | Edges | Load/decode | Full preparation | Preparation work | Warm lookup | Process peak |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Quebec candidate02 | 1,469,141 | 106 ms | 791 ms | 11.22 M | <1 ms | 310 MiB |
| Ontario candidate03 | 1,948,176 | 154 ms | 919 ms | 12.14 M | <1 ms | 709 MiB |
| California candidate03 | 6,905,252 | 677 ms | 3,395 ms | 46.22 M | <1 ms | 1,071 MiB |

Peak memory includes all attempts within that regional process. Ontario's peak
includes reverse-bound construction; Quebec and California stop at their
restriction error before bounds. These memory numbers are therefore not
like-for-like bounds comparisons, nor steady-state or concurrency limits.
California already exceeds one GiB before an actual route search.

Ontario permits a separate bounds measurement with all restrictions retained.
Reverse bounds targeting the reproducibly selected highest-degree graph node
used 8.85 M operations and 1,399 ms, reaching 1,246,776 nodes. The same operation
with the six-million allowance stopped incomplete after 1,128 ms. Reusing the
spatial index alone does not solve this per-destination whole-graph work.
No rider route or fuel plan is qualified by this audit.

## Quebec source evidence and handoff

[Relation 7111448 version 1](https://api.openstreetmap.org/api/0.6/relation/7111448/1.json)
used approach way 134811809, via way 111771059, and exit way 465413249.
[Version 2](https://api.openstreetmap.org/api/0.6/relation/7111448/2.json), edited
August 17, 2025 in changeset 170566798, replaced the approach with 111771059 but
retained that same way in the via role. The tag remains `only_straight_on`.
The [current approach geometry](https://api.openstreetmap.org/api/0.6/way/111771059/full.json)
is an open Rue Sherbrooke Ouest segment, not a closed loop. The
[exit way](https://api.openstreetmap.org/api/0.6/way/465413249/full.json) shares its
end node 26233234. Current API data is evidence about source history, not an
assertion that it is byte-identical to the pack's source snapshot.

Inference: a way edit likely left a stale relation role. It is not defensible to
interpret the repeated packed edge as a mandatory out-and-back, silently drop
it, or restore the old approach ID without checking the source topology.
The [OSM restriction specification](https://wiki.openstreetmap.org/wiki/Relation:restriction)
defines via members as the connection between approach and exit and requires
mandatory turns to follow the relation geometry; it does not authorize such a
repair by guesswork.

Concrete pack-agent investigation:

- Compare the locked-source relation and changeset 170566798 with the way merge/
  split history, including old way 134811809.
- Recover the directed approach and intended junction from source evidence. A
  node-based only-straight relation at the final junction may be the intended
  result, but that is a hypothesis, not an implemented fix.
- Check packed approach/via edge 318695, exit 547118, via node 1113889 and edge
  endpoints 1113889/164. Preserve the original record and provenance in any
  versioned correction and provide explicit permitted/prohibited turn fixtures.
- Do not simply discard the record to make validation pass. A rebuild using the
  unchanged relation would reproduce this problem.

The reader still returns `ambiguous_via_way_entry` for Quebec. No successful
Quebec route is claimed.

## California handoff

The audit found these distinct cases, all left intact:

- Relation 10646119: distinct approach/via edges 4654654 and 4654658 share both
  endpoints 3420027/3420028. Source uses distinct ways 767571159/767571161/767571163
  and `no_left_turn`. This needs directed full-sequence attachment analysis; it
  must not be treated as the same stale-member case as Quebec.
- Relation 11282204: approach and first via both source way 1368740459;
  packed repeated edge 6497867; `no_u_turn`.
- Relation 12475588: approach and first via both source way 303435697;
  twenty packed records with repeated approach/via edges; `no_u_turn`.
- Relation 16658296: approach and first via both source way 1221449098;
  three packed records with repeated approach/via edges; `no_right_turn`.

Raw current relation snapshots and detailed per-record edge IDs are preserved
in the audit artifacts. Repeated source roles can have different topology;
these California records require their own source-resolution checks.

## Next implementation priority for scale

1. Make preparation an explicit revision-owned lifecycle, with bounded regional
   cache residency and measured cold-start cost. Existing cache correctness is
   useful, but increasing its entry count blindly would multiply memory.
2. Replace the temporary reverse adjacency's per-node arrays and per-arc objects
   with a compact representation or reuse eligible reverse topology. Measure
   target-bound construction independently from endpoint-independent work.
3. Preserve honest request deadlines and incomplete results while qualifying
   adaptive/on-demand search bounds. Do not replace a computational limit with
   a geographic corridor that silently removes worthwhile dirt routes.
4. Run identical projected rider requests with fuel on Ontario, then California
   after the relevant restriction mapping is resolved. Measure concurrent memory
   before deciding service capacity or claiming the small-region timings scale.

Replay: `node --expose-gc scripts/pack-fabric/bench/run-large-graph-audit.js` with
`REBUILD_PACK_ROOT` and `REBUILD_REGION` set. Output defaults to
`routing/candidates/rebuild-large-audit/{region}.json`. All inputs remain read-only.
