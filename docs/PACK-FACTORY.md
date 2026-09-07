# DIRT Pack Factory

**Status:** canonical legal-topology migration contract.

**Halt production:** Do not stamp, overwrite, or promote V1/V2/V3 packs. Public
`dirt-packs/{id}/graph.v3.bin` and `manifest.json` stay untouched. The authorized
work is one source-locked V4 fabric covering all 13 Canadian regions and all 50
US states. Nova Scotia is built and verified first as the mould; the factory
then continues through all 63 regions without an intermediate production switch.

**Not a V3 restamp.** Directed travel in the NS V3 canary
`ns-v3-dir-20260906-01` is preserved in the dirty tree. It is not the mould.

Workspace: `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt`
Branch: `feature/routing-itinerary-rebuild`
Production LIVE: `https://dirt-mayday.vercel.app/api/route` (do not point at V4)
DEV LIVE: `https://pack-fabric.vercel.app/api/route` (V4 NS canary only)

Frozen search/cost mould: `94b467a11375e3ea3233c127b07af2ef039d0658`. Fuel
selection is out of scope. This migration changes **legal topology**, not Dirt /
Balanced / Clean costs.

If a skill or older prompt conflicts with this file, this file wins after
`AGENTS.md` and `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`.

---

## 0. Uncommitted work preserved (2026-09-06)

Do not reset, stash, or overwrite. Present before this migration:

- Directed-travel JS/Swift (`travel-direction`, CSR arcs, virt links, Hwy 104 proof)
- Factory pause (`us-v3-pause.js`)
- Android parity notes for directed travel
- NS V3 directed canary record `ns-v3-dir-20260906-01`
- Oneway fixtures and tests
- Dirty V3 US seam JSON / Montana staging (unpublished; do not promote)

---

## 1. What a complete pack is

Rider-facing V4 objects (DEV namespace until national atomic switch):

| File | Role |
| --- | --- |
| `graph.v4.bin` | Legal topology. Version 4 + capability `legal-topology.v1`. |
| `geometry.v1.bin` | Paired polylines. Identity hashed into the graph. |
| `fuel.v1.json` | Verified regional fuel sidecar from the same locked OSM source. |
| `cross-pack-seams.v2.json` | Exact legal border/ferry proofs for this region. |
| `pack-manifest.v2.json` | Catalog row: files, SHA-256, capabilities, provenance. |

Public V1/V3 catalog and objects remain the rollback fabric.

Camping, lodging, and liquor stay in rider-services data. They never enter
routing-pack activation. No runtime Overpass.

`directedArcCount` is legal arcs, not `2 × undirectedEdgeCount`.

---

## 2. Reader rejection (JS, Swift, Kotlin)

Fail closed on:

- graph version ≠ 4 for a V4 loader
- missing capability `legal-topology.v1`
- missing or corrupt restriction, barrier, or access sections
- graph SHA / geometry SHA mismatch
- mixed-contract cross-region routing (V3 pack + V4 pack in one search)
- unsupported or empty provenance

A reader must never silently ignore safety data. V3 loaders must reject V4
bytes (unsupported version / magic). V4 loaders must reject V3 bytes when
legal-topology routing is required.

Byte contract: `docs/PACK-DATA-V4-AUTHORITY.md`.

---

## 3. Extract (lossless OSM identity)

Replace highway-LineString GeoJSONSeq as the legal source.

Keep a reference-complete PBF (or OPL) that retains:

- 64-bit OSM node IDs
- ordered way-node references
- OSM way IDs
- restriction relation IDs and complete ordered members
- access, direction, condition, layer, bridge, tunnel tags
- barrier/access nodes on retained ways

Coordinates are geometry, not topology identity. Do not use `coordKey5` or
`vertex:<coordinate>` as OSM identity. Coincident coordinates connect only
when source topology shares an OSM node or way-node membership.

Halo: clip with a buffered admin polygon so border restrictions keep all
members. Provenance must record source URL, bytes, SHA-256, OSM replication
timestamp, clip polygon identity, tool versions, factory commit, and the
global source-epoch policy for the later all-region fabric.

GeoJSON is diagnostic only.

---

## 4. Legal topology laws

**Direction.** `oneway=yes|true|1` forward; `-1`/`reverse` reverse; `no` both;
untagged motorway / motorway_link / roundabout / circular imply forward.
Direction-specific access tags can close one side. Reversible, alternating, or
unevaluable `oneway:conditional` is **closed**, not two-way.

**Motorcycle access.** Evaluate `access` → `vehicle` → `motor_vehicle` →
`motorcycle`, including `:forward` / `:backward` and `:conditional`. More
specific wins. `motorcycle=no|private` is a hard denial. Positive `atv` must
never override `motorcycle=no` or `motor_vehicle=no`. ATV is a separate
profile. Allow Unknown never reopens an explicit denial.

Endpoint-only: `destination` only when the route endpoint lies on that edge;
`customers` only for an intentionally selected service POI. Never through.
`private`, `no`, `permit`, `delivery`, `agricultural`, `forestry` stay denied.
`smoothness=impassable` is a hard block. `very_horrible` is preserved as a
leaf; frozen costs are unchanged.

**Barriers.** Every relevant barrier/access node is an exact graph node; split
the way there. Explicit motorcycle/access/locked/conditional tags win. Do not
universally block or allow every gate. Ambiguous barriers fail closed and are
counted. Barriers cannot be bypassed by snap, stitch, seam, or a parallel road.

**Turn restrictions.** Via-node, via-way, multiple-via-way; `no_left_turn`,
`no_right_turn`, `no_straight_on`, `no_u_turn`; all `only_*`; `no_entry` /
`no_exit`; vehicle-specific forms; `except`; conditionals. Resolve members by
original OSM IDs. Malformed relations are rejected and reported, never guessed.
Search is turn-aware: state includes the incoming directed arc and via-way
progress. Node-only visited state is illegal on V4. Virtual snap arcs keep
parent directed-arc and restriction identity.

**Conditional / seasonal.** Normalize the supported subset of
`access|vehicle|motor_vehicle|motorcycle:conditional`, directional variants,
`oneway:conditional`, `restriction*:conditional`, `seasonal`, `winter_road`,
`ice_road`. Same representation in JS, Swift, and Kotlin. Use the edge local
timezone when needed (`America/Halifax` for NS). Unsupported, conflicting, or
unevaluable relevant conditions fail closed and are reported. Never hardcode
`seasonal: false`. Allow Unknown cannot reopen a known seasonal/conditional
closure.

**No invented connectivity.** Zero unproven runtime stitches. Remove Swift
~150 m permissive stitches and ~100 m unknown-island stitches, and the JS
twins, for V4. LIVE and offline may not join nearby roads because the graph is
disconnected. Any source repair is build-time only, deterministic, proven by
OSM identity, compatible with way continuity / grade / direction / access /
barriers / restrictions, and fixture-covered.

**Snap.** Zoom-aware tap radius from screen/map resolution (28-point finger ×
Web Mercator meters/point). Safe upper bound is **2000 m** on V4 (covers the
Yarmouth harbour coarse-zoom miss of ~1.7 km). V3 stays capped at 750 m.
Score distance, local tangent, device course when reliable, and A→B / arrival
intent. Those V4 scores stay on each directed candidate through final pair
selection — do not collapse to an edge-index set and revert to distance-first.
Evaluate multiple legal directed candidates for route connectivity (weak
components). Prefer a connected candidate that can produce the requested route.
Reject a snap that needs a connector across a median, barrier, water gap, grade
separation, prohibited direction, or inaccessible road. Unknown trails stay
out unless Allow Unknown is on, and that flag is logged on route-first and
fuel-combined requests. Move the destination pin to the selected snapped point.
Diagnostics record raw/snapped coordinates, distance, candidate count, OSM way,
access class, component, and rejection reasons.

**Seams.** Shared OSM node and way identity only. Eligible only when identity,
way continuity, grade/layer, bridge/tunnel, direction, access, barriers, and
restrictions agree, including boundary-spanning restrictions. Build all
regions from one source-epoch, generate the seam matrix, then seal. Never
rebuild a graph after hashing its seam identity. Do not promote mixed V3/V4
public fabric.

**Grade.** Bridge / tunnel / layer from OSM tags. Distinct OSM nodes that
happen to share coordinates stay distinct.

---

## 5. Automated gates (must be green before NS bytes)

Fixtures live under `scripts/pack-fabric/routing/fixtures/legal-topology/`
and `DirtTests`. Highway 104 proof coordinates:

- Start: `45.390440, -63.201514`
- Westbound way `537982310` (north carriageway)
- Eastbound way `537982311`
- MacDonald Road probe: `45.8071, -64.1885`

Required proofs:

1. Forward / reverse / explicit two-way / motorway / roundabout direction
2. Highway 104 both ways; median-safe snap with heading, conflicting heading, no heading
3. no-left, no-right, no-straight, no-U-turn, only-turn, no-entry, no-exit
4. Via-node, via-way, multiple-via-way
5. Motorcycle-specific restrictions, `except`, malformed-relation rejection
6. `motorcycle=no` defeating positive ATV tags
7. Directional motorcycle access
8. Destination/customer endpoint-only at the actual endpoint
9. Allowed / blocked / type-default / ambiguous fail-closed gates
10. `smoothness=impassable` blocked
11. Supported conditional open/closed; unsupported fail-closed
12. Seasonal, winter-road, ice-road
13. Bridge/tunnel/layer and coincident-but-distinct-node crossings never joined
14. No barrier / one-way / restriction / median bypass via snap, virt, seam, or stitch
15. Deterministic identical hashes from identical inputs
16. Corruption, missing capability, mixed-contract rejection
18. Zoom-aware tap radius; Yarmouth harbour coarse-zoom prefers connected town road
19. Divided highway heading scores survive final candidate selection
20. Disconnected service road rejected when a connected candidate exists
21. Unknown trail skipped unless Allow Unknown
22. Barrier-blocked / no valid road within the 2000 m bound is a snap failure
23. Allow Unknown logged through route-first and fuel-combined requests

JS, Swift, and Kotlin must agree. Kotlin sources live at
`scripts/pack-fabric/routing/kotlin/` until an Android app tree exists.

---

## 6. NS V4 mould, then the complete candidate (only after §5)

```sh
node --test scripts/pack-fabric/routing/lib/legal-topology/*.test.js \
  scripts/pack-fabric/routing/lib/pack-v4.test.js \
  scripts/pack-fabric/routing/lib/pack-manifest-v2.test.js \
  scripts/pack-fabric/routing/lib/find-path-v4.test.js
node scripts/pack-fabric/scripts/build-region-graph-v4.js ns
```

Then:

1. Build graph, fuel, and Rider Services from the one locked source epoch.
2. Report restriction / barrier / directional-access / endpoint-only /
   conditional / impassable / grade-non-join / seam-candidate / rejected counts.
3. Assert zero unproven stitches.
4. Verify NS locally as the mould before continuing the same factory run.
5. Build all 63 regions; then generate every per-region seam sidecar and the
   complete topology index. A full release cannot seal with a missing seam file,
   mixed source epoch, unproven advertised border, or mismatched hash.
6. Candidate-upload only to `dirt-packs/v4/candidates/<release>/`; point only
   pack-fabric DEV at the complete immutable candidate.
7. Do not alter production or the public V1/V3 catalog before owner acceptance.

---

## 7. Device test card (NS V4)

Online on DIRT Dev (DEV LIVE at pack-fabric). Offline: DIRT Dev overlays the
Nova Scotia PACKS download onto `v4/candidates/ns-v4-legal-topology-20260906-02`
(`graph.v4.bin`). Install NS from PACKS, then airplane mode for the last two.
Production binaries keep the public V1/V3 catalog.

1. Highway 104 westbound from the Truro start through MacDonald Road — way 537982310, never 537982311.
2. Highway 104 eastbound the other way — 537982311, never 537982310.
3. A signed no-left or no-U-turn the pack encoded — search must not take it.
4. A gated or conditional road — blocked when closed/ambiguous; open when tagged open.
5. Destination-only access — reachable as the endpoint, not as a through shortcut.
6. Grade-separated crossing — no invented turn from the overpass onto the road below.
7. Same route offline from the installed V4 pack.
8. Same route with no network.

---

## 8. Candidate completion and later promotion

Build order is deterministic by region ID and resume-safe. One source epoch.
Build every region, generate the complete seam matrix, seal one fabric-release
manifest, upload immutable candidate objects, and verify every remote identity.
Only after device acceptance may the versioned pointer switch atomically. Leave
V1/V3 in place for rollback. Never promote a mixed public fabric.

---

## 9. Access-law note (not a cost change)

V4 road-legal motorcycle access does **not** let `atv=yes` override
`motorcycle=no` or `motor_vehicle=no`. That differs from the locked V3 ATV
override. Costs, search widths, and fuel ranking are unchanged. This is
eligibility, recorded here because the V3 authority said the opposite.
