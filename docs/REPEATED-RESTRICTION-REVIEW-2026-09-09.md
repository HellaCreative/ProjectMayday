# Repeated restriction review — 9 September 2026

The proposed universal collapse of repeated from/via edges is not approved by this review. Explicit writer entry proves orientation, but does not prove that every Cartesian row represents the intended physical maneuver.

## Evidence

All 54 source relations were recovered from the locked source epoch. Pack way memberships match those sources. Full relation groups, rather than only rejected rows, are retained under the candidate restriction-classification/groups directory.

Executing the proposed adapter on the complete actual relation rows and endpoints reproduced:

- Saskatchewan 20961374 and 20961375: original no_u_turn, with the same way in from/via/to roles. Collapsing the repeated first edge prohibits continuation to the next edge on that source way as well as reversal.
- Ohio 12526146: original only_straight_on, with the same way in all roles. The proposed adapter permits immediate reversal as well as continuation.
- Alberta 9938613 has the same all-role pattern but road access is prohibited in both directions. Successful adapter construction cannot validate usable routing behavior here.

Machine-readable results and the exact reviewed adapter SHA are in scripts/pack-fabric/routing/candidates/fabric-v4-20260909-01/restriction-classification/prefix-collapse-counterexamples.json. These are isolated restriction transition checks using original group rows, not full hosted routes.

## Decision

Direction-aware matching and use of the explicit source-path entry are supported independently of universal overlap normalization. Preserve the narrowly proven Washington case. Treat repeated same-way roles, particularly all-three-role cases, as requiring maneuver-aware source interpretation and whole-relation tests. Do not declare all 63 regions semantically verified merely because their adapters construct successfully. Do not discard rules to obtain admission.

Findings were delivered to Routing Agent -08 before accepting the proposed normalization. No pack bytes, deployment aliases, or phone content were changed in this review.

## Implemented and published correction, pending live routing acceptance

Factory commit `3c03c17` resolves repeated roles at source-way level. The full locked source ways establish unique member junctions for 28 relations. One two-way approach (NJ9902543) is disambiguated by a clear left turn (+86.43 degrees); the opposite approach is a right turn and remains unaffected. Two source prohibitions have an already prohibited one-way approach: their correctly located rule is retained rather than inventing a legal arrival.

Four all-role sources do not identify a unique junction. Their original relations and all expanded rows are retained in graph provenance. The executable ambiguity is replaced by explicit exclusion of only the implicated source way: Alberta201m already excluded, Saskatchewan152m+161m, Ohio60m. Newly excluded travel is373m. None of these way IDs occurs in the original regional seam proofs. This is a conservative temporary quarantine, not a claim that OSM marks those roads closed. Source clarification is needed to remove it.

The correction touches19graphs. Every unrelated restriction, road section, geometry, fuel record, and border connection proof remains unchanged; only restriction rows, specified access bytes, provenance and necessary header offsets change. All19 corrected graphs round-trip through the V4 decoder.25 factory tests pass, including full approach-way overlap, intermediate-junction scope, left-versus-right approach, quarantine scope, one-way rules, toll passage, compaction, and mixed-contract rejection.

Release `fabric-v4-20260909-02` is fully published and verified:465 storage SHA checks and465 public availability checks pass; both catalogs match their expected SHA256. Region seam files and shared topology carry the new release label; all connection proof bytes remain identical. Service and app activation remain with Routing Agent -08. Final evidence: `scripts/pack-fabric/routing/candidates/fabric-v4-20260909-02/publication/handoff.json`. Factory code is integrated into the main project as `9eff5dd`. Streaming storage patches independently reproduce the exact local SHA256 of all19 graphs without allocating entire graphs in the publishing worker.

All63 regions pass reader construction and factory assembly checks.32 targeted restriction transition/exclusion cases pass. These checks do not claim device acceptance or simultaneous-user capacity. No phone installation, service alias change, or GitHub push was performed by this pack task.
