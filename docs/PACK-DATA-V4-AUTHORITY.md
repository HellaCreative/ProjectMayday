# DIRT — Graph V4 pack-data authority

**Status:** AUTHORITY for `graph.v4.bin`, `pack-manifest.v2`, and capability
`legal-topology.v1`.

Ride-mode costs remain `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md` and
`docs/ROUTING-FREEZE-2026-09-03.md`. Factory procedure is `docs/PACK-FACTORY.md`.
V3 byte layout remains `docs/PACK-DATA-V3-AUTHORITY.md` for rollback readers
only. Do not identify V4 safety fields as ordinary V3.

## 1. Objects

| File | Magic / version |
| --- | --- |
| `graph.v4.bin` | magic `0x34545244` (`DRT4` LE), version `4` |
| `geometry.v1.bin` | existing `GEOM` v1 sidecar; SHA-256 stored in the graph |
| `pack-manifest.v2.json` | JSON catalog row |
| `fuel.v1.json` | unchanged sidecar |

V3 magic `0x32473244` version 2–3 must be rejected by a V4 legal-topology
identity loader (`GraphV4Pack`). The on-device CSR decoder (`GraphV2Pack`)
loads V4 when magic, capability `legal-topology.v1`, and safety sections are
present; it still rejects truncated or capability-missing V4 bytes. A V3-only
reader must not treat V4 as V3.

Required capability string: `legal-topology.v1`.

## 2. `pack-manifest.v2`

```json
{
  "schema": "pack-manifest.v2",
  "fabricReleaseId": "ns-v4-legal-topology-YYYYMMDD-NN",
  "regionId": "ns",
  "capabilities": ["legal-topology.v1"],
  "graph": { "name": "graph.v4.bin", "bytes": 0, "sha256": "" },
  "geometry": { "name": "geometry.v1.bin", "bytes": 0, "sha256": "" },
  "fuel": { "name": "fuel.v1.json", "bytes": 0, "sha256": "" },
  "sourceEpoch": "",
  "timezone": "America/Halifax"
}
```

A V4 router loading two regions must require identical `schema`, intersecting
capabilities, and the same `sourceEpoch`. Mixed V3+V4 is corrupt.

## 3. `graph.v4.bin` header (140 bytes)

Little-endian.

| Offset | Field |
| --- | --- |
| 0 | magic u32 `0x34545244` |
| 4 | version u16 `4` |
| 6 | flags u16: bit0 from/to, bit1 leaves, bit2 crossing-seconds, bit3 legal-topology (**required**), bit4 derived edge IDs |
| 8 | nodeCount u32 |
| 12 | undirectedEdgeCount u32 |
| 16 | directedArcCount u32 |
| 20 | headerSize u32 `140` |
| 24–103 | CSR / leaf / crossing offsets (same meaning as V3 crossing header) |
| 104 | osmNodeIds offset (Int64[nodeCount]) |
| 108 | osmWayIds offset (Int64[undirectedEdgeCount]) |
| 112 | edgeAccess offset (u8[undirectedEdgeCount * 2]) forward then reverse |
| 116 | barriers offset |
| 120 | restrictions offset |
| 124 | conditionals offset |
| 128 | provenanceJson offset |
| 132 | capabilitiesJson offset |
| 136 | geometrySha256 offset (32 bytes) |

Flag bit3 `FLAG_V4_LEGAL_TOPOLOGY = 8` must be set. Any of offsets 104–136
equal to 0 is corrupt.

New V4 writers set bit4 `FLAG_V4_DERIVED_EDGE_IDS = 16`. These packs omit the
redundant UTF-8 edge-ID table and derive the exact stable identifier as
`w<osmWayId>:<fromNodeIndex>:<toNodeIndex>` from fields already stored for every
edge. Readers remain backward-compatible with the original explicit-ID V4
layout. This is lossless packing: graph topology, geometry, access, barriers,
restrictions, seam identities, and route costs do not change.

`edgeAccess` codes:

| Code | Meaning |
| --- | --- |
| 0 | through allowed |
| 1 | unknown (Allow Unknown may open; never opens 2–5) |
| 2 | denied |
| 3 | endpoint destination only |
| 4 | endpoint customers only |
| 5 | fail-closed conditional/seasonal |

## 4. Barrier section

u32 count, then records of 16 bytes:

- osmNodeId i64
- graphNode u32
- decision u8 (`0` allow, `1` block, `2` fail-closed ambiguous)
- pad 3 bytes

## 5. Restriction section

u32 count, then variable records:

- osmRelationId i64
- kind u8 (see table)
- fromEdge u32
- toEdge u32
- viaNode i32 (`-1` if via-way only)
- viaWayCount u16
- exceptMask u16
- vehicleMask u16 (bit0 motorcycle, bit1 motor_vehicle, bit2 all)
- conditionalIndex i32 (`-1` none)
- flags u8 (bit0 fail-closed unused, bit1 only-*, bit2 malformed rejected — rejected rows must not appear; they go to provenance `rejected`)
- viaWayIds Int64[viaWayCount]
- viaEdgeIndexes Int32[viaWayCount] (`-1` if the via way is not an encoded edge)

Kind: `0` no_left_turn, `1` no_right_turn, `2` no_straight_on, `3` no_u_turn,
`4` only_left_turn, `5` only_right_turn, `6` only_straight_on, `7` only_u_turn,
`8` no_entry, `9` no_exit.

Search applies these using incoming undirected edge + via-way progress.

## 6. Conditional section

u32 count, then JSON UTF-8 blob of normalized rules (shared JS/Swift/Kotlin
object). Each rule:

```json
{
  "id": 0,
  "tag": "motorcycle:conditional",
  "outcomeOpen": false,
  "evaluable": true,
  "timezone": "America/Halifax",
  "windows": []
}
```

Unevaluable rules are not encoded as open. The edge access code is `5`.

## 7. Provenance JSON (required)

Must include: `sourceUrl`, `sourceBytes`, `sourceSha256`, `osmTimestamp`,
`clipPolygonId`, `clipPolygonSha256`, `haloMeters`, `toolVersions`,
`factoryCommit`, `sourceEpoch`, `rejected` (grouped by reason),
`counts`, `unprovenStitches` (must be `0`).

## 8. Geometry identity

Bytes at offset 136 are the SHA-256 of the paired `geometry.v1.bin`. Decode
must hash the loaded geometry and reject mismatch.

## 9. Node identity

`osmNodeIds[i]` is the original 64-bit OSM node id for graph node `i`.
`0` is illegal except for a virtual snap node, which is not stored in the
pack (virtual nodes are runtime only and carry `parentEdge` + `fraction`).

Two graph nodes with equal coordinates and different OSM ids are different
nodes.

## 10. Kotlin / Swift / JS

All three must:

- reject the conditions in `docs/PACK-FACTORY.md` §2
- expose `hasDirectedArc`, `turnAllowed`, `edgeAccess`, `barrierDecision`
- refuse mixed-contract region sets
- **search** V4 with turn-aware hops, motorcycle access, heading-safe snap,
  zoom-aware tap radius (2000 m cap), connectivity pair selection that keeps
  V4 scores, and destination-pin move to the snapped point
  (JS `find-path-v4` / Swift `OnDeviceRouter` / Kotlin `FindPathV4` + `LegalSnap`)
  — decoding the header is not routing parity
