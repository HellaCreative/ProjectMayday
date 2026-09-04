# Cursor prompt — run DIRT Pack Factory

Use the complete prompt below in Cursor. Cursor may use its existing **Pack
Factory** skill, but the checked-in repository contract is authoritative.

---

You are producing the remaining DIRT regional routing packs from the frozen
routing release candidate.

Work only in:
`/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt`

Use branch:
`feature/routing-itinerary-rebuild`

Invoke your Pack Factory skill, then read these files completely before making
changes:

1. `AGENTS.md`
2. `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`
3. `docs/ROUTING-FREEZE-2026-09-03.md`
4. `docs/PACK-FACTORY.md`
5. `docs/PACK-DATA-V3-AUTHORITY.md`
6. `.cursor/rules/live-and-pack-lockstep.mdc`

The frozen routing implementation is
`94b467a11375e3ea3233c127b07af2ef039d0658`, tagged
`routing-rc1-2026-09-03`. Do not change route costs, profile objectives, search
widths/budgets, fuel thresholds/ranking, stage-edit ownership, warning
semantics, or app UI as part of pack production.

The accepted V3 mould is Nova Scotia, New Brunswick, Prince Edward Island,
Newfoundland and Labrador, Quebec, and Ontario. Their exact immutable release
IDs and graph/geometry/fuel hashes are in the freeze document. Treat those
bytes as read-only. Every new pack must use the same OSM-only V3 builder,
lossless leaf schema, topology/membership laws, fuel sidecar format, release
record, and guarded candidate/promote workflow.

First, audit the public R2 manifest and both V3 registries. Produce an ordered
list of regions that still require V3 packs. Do not bulk-promote. Work one region
at a time through the full loop in `docs/PACK-FACTORY.md`:

- register deliberate acceptance routes;
- build `graph.v3.bin` and its paired `geometry.v1.bin` from the clipped
  Geofabrik OSM source;
- build the matching OSM `fuel.v1.json`;
- fail closed on dictionary overflow or identity mismatch;
- run the shared test suite and local region audit;
- create and upload an immutable region-only candidate without changing the
  public manifest;
- add both V3 registries and commit the release record, fixtures, reports, and
  registries so deployment has a real source identity;
- deploy LIVE against the recorded candidate override;
- run LIVE route, profile, urban, seam, ferry where applicable, and fuel
  acceptance probes;
- confirm no accepted reference regression changed;
- promote the exact tested bytes;
- add the region to both V3 registries;
- redeploy LIVE from committed source without a candidate override; and
- run `ship-routing.js --assert --region <region>`.

For every region, report the OSM source provenance, release ID, node/edge counts,
dictionary cardinalities, byte counts, SHA-256 values, local/LIVE acceptance,
seam/fuel probes, `serviceBuild`, `serviceContract`, and lockstep assertion.

Never use bare `--pack`, replace the remote catalog with the checked-in seed
manifest, publish a local-only pack, add provincial supplements, use longhaul,
invent connectors, or change an accepted neighbouring pack. If a region appears
to require a router change, stop that region and present the reproduction and
evidence; do not hide the change inside Pack Factory.

Begin by showing the manifest/registry audit and proposed region order. Then
start the first region. Keep a concise checkpoint after each region so a failed
candidate can be abandoned without disturbing the currently promoted fabric.

---
