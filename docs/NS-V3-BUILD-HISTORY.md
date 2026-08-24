# DIRT — How Nova Scotia v3 Was Built (detailed build history)

A precise, commit-by-commit record of how the NS routing pack went from the coarse v2 format
to v3 (leaf-preserving), and every change that evolved it afterward. Written 2026-08-24.

---

## 0. The data-flow pipeline (so the phases make sense)

```
OSM Geofabrik extract  →  osm-roads.js adapter  →  intermediate JSON graph  →  pack-v2.js
(raw ways + tags)         (normalize, classify)    (canonical edges)           (binary .bin)
                                                                                    │
                                              graph.v3.bin + geometry.v1.bin  ──────┤
                                                                                    │
                          ┌─────────────────────────────────────────────┐         │
                          │  ONE pack, TWO readers (must stay lockstep)  │◄────────┘
                          │  • JS engine (Vercel /api/route)             │
                          │  • Swift on-device (GraphV2Pack.swift)       │
                          └─────────────────────────────────────────────┘
```
The pack is the single source of truth for both the live API and the on-device router. Publish
is `ship-routing.js --promote <releaseId> --pack ns` → `npx wrangler r2 object put --remote` to
the Cloudflare R2 bucket `dirt-packs`.

## 1. The problem v3 solved

The on-device edge record was a **single fully-allocated 16-bit integer**:
```
bit 0–2  surface (3b, max 8) | bit 3–5 access (3b) | bit 6–8 structure (3b)
bit 9–10 confidence (2b)     | bit 11 seasonal (1b) | bit 12–15 roadClass (4b, max 16)
```
Surface capped at 8 families, so `osm-roads.js` crushed every OSM `surface=` value
(asphalt/concrete/cobblestone/gravel/fine_gravel/dirt/sand/mud/…) into ~6 coarse families and
threw the raw leaves away at pack time. No room for `tracktype`, `smoothness`, or the raw
strings. **v3 preserves the OSM leaf values; bucketing into families becomes a read-time job.**

Safety before starting: restore floor `7cd5a40` (the 85–90% baseline); checkpoint tags
`pre-v3-decompression-dirt` (`58fb468`) and `pre-v3-decompression-packrebuild`.

---

## 2. Build order — phases A → G (commit by commit)

### Phase A — audit (read-only)
Extended `audit-osm-surface-normalization.js` to measure NS edge-length across every distinct
`surface`, `highway`, `tracktype`, `smoothness`, `layer`, `bridge`, `tunnel`, `ford` value.
Findings that shaped everything: 60,992 km / 141,022 ways; `surface=unpaved` alone = **49%**
(30,004 km); all tag cardinalities fit a 1-byte index (surface 38 distinct max); tracktype/
smoothness ~99% missing. Two follow-up audits (A2/A3) measured ATV tagging: 350.7 km carry
positive `atv=` but were excluded by `motorcycle=no`.

### Phase B1 — adventure-network membership + ATV access (`be74518`)
In `osm-roads.js`: dropped `cycleway`; kept `track`; kept `path` (initially only atv-positive).
**ATV rule:** positive `atv ∈ {yes,designated,permissive}` overrides a vehicle-type deny
(`motorcycle=no`, `motor_vehicle=no`) — but NOT a hard land deny (`access=private/no`). This is
because a dual-sport is an off-road vehicle allowed on ATV trails; `motorcycle=no` there means
"street bikes can't handle it," not a legal bar.

### Phase B2 — carry leaves through the schema (`7d6cc66`, no `.bin` change)
Added first-class edge fields end-to-end (adapter → `edge.js` schema → intermediate JSON):
`surfaceLeaf`, `roadClassLeaf`, `tracktype`, `smoothness`, `layer`, `structureLeaf`,
`accessLeaf`, `atv`, `atvDesignated`. The existing coarse fields stayed byte-identical (proven
over 199,724 edges) — leaves were added alongside, nothing perturbed.

### Phase C — the v3 binary format (`8eec02e`)
In `pack-v2.js`: `GRAPH_VERSION 2 → 3`; header grew **72 → 100 bytes** (7 new u32 section
offsets appended at bytes 72–96; v2 offsets 24–68 unchanged); flags bit1 = `FLAG_V3_LEAVES`.
JS encode + decode; the u16 coarse record kept as a **derived fast-costing cache** regenerated
from the leaves. Round-trip proved 199,724/199,724 edges exact. Builds a local candidate only
(`graph.v3.candidate.bin`), never overwrites shipped bytes.

**The v3 per-edge record (7 new bytes) + dictionaries:**
| Section | Type | Meaning |
|---|---|---|
| `edgeSurfaceLeaf` | u8 | index into `surfaceLeafNames` (raw `surface=`) |
| `edgeRoadClassLeaf` | u8 | index into `roadClassLeafNames` (raw `highway=`) |
| `edgeGrade` | u8 | tracktype (nibble, grade1–5) + smoothness (nibble, 8 values) |
| `edgeLayer` | i8 | signed OSM `layer=` (overpass >0 / underpass <0) |
| `edgeStructureLeaf` | u8 | index into `structureLeafNames` (bridge/tunnel/ford/ferry/…) |
| `edgeAccessLeaf` | u8 | index into `accessLeafNames` (incl. atv_permitted) |
| `edgeFlags` | u8 | bit0 = `atvDesignated`, bit1 = `seasonal` |

Dictionaries live in the `enumsJson` section (index 0 = untagged sentinel); builder **fails
closed** if any exceeds 255 entries. Magic unchanged (`0x32473244`); geometry stays `geometry.v1`.

### Phase D — Swift v3 decode + lockstep (`f9f5c2d`)
`GraphV2Pack.swift` accepts version 3 (branches header size 72 vs 100), reads the 7 leaf arrays
+ dictionaries, adds accessors mirroring JS exactly. Proven by a golden-fixture test: JS decodes
the NS candidate and dumps leaf values for 847 sampled edges; Swift reads the same bytes and
asserts identical values (incl. atvDesignated). Byte-for-byte lockstep confirmed.

### Phase E1 — honest Dirt% (`4b433a2`, stats only)
Shared `surface-family.js` / `SurfaceFamily.swift` + `surfaceFamilyMap` embedded in `enumsJson`
so both engines derive families identically from `surfaceLeaf`. No route-selection change.

### Phase E2 — Clean consumes leaves (`7676bc1`)
`road-tier.js` / `RoadTier.swift`: Clean routes on road-class tiers (collector = backbone,
arterial = connector, residential = destination-access-only via `isBlockedForCleanLeaf`,
motorway/trunk avoided) + surface families (prefer paved).

### Phase E3 — debug layers + version badge (`93c5be9`)
Surface / road-class / access debug map layers; a pack-version badge.

### Phase E4 — split highway controls (`d205479`)
"Avoid motorways" (motorway+trunk) vs "Prefer back roads" (penalize arterial) as independent
Clean controls. (`5ac9845` fixed a `cleanMetroPenalty` crash on non-Clean profiles in metro.)

### Phase G1 — ferries (`c9c5813`)
`ferry.js`: `route=ferry` ways included as timed connectors (`crossingSeconds` from OSM
`duration=` or estimated at 18 km/h; cost at a 50 km/h reference), terminals snapped to road
nodes within 500 m, labeled "Ferry crossing", excluded from Dirt% / paved% denominators.

### Phase G2 — richer structure (`a88e151`)
`structure.js`: fords, tunnels, culverts, viaducts, low-water-crossings, and `layer`-separated
overpasses/underpasses — packed, labeled, and water-crossing-flagged (ford wins precedence).

---

## 3. Locked taxonomy (Rick's decisions, read-time family map)

**Surface families (4):**
- **Paved** — asphalt, paved, concrete, chipseal, paving_stones, cobblestone, sett, brick, metal, wood
- **Gravel** — gravel, compacted, fine_gravel, pebblestone, **+ unpaved (the 49% leaf)**
- **Loose/technical** (switch-governed) — dirt, ground, earth, grass, mud, sand, rock, natural, woodchips
- **Unknown** (switch-governed) — missing + compound/oddball values

**Road tiers (Clean):** motorway/trunk → avoid; arterial (primary) → connector-only;
collector (secondary) → backbone; local paved (tertiary/unclassified) → preferred;
residential/living_street → destination-access-only; track → adventure.

**Membership:** all track + all path (see release 05); cycleway dropped.
**Dirt%:** counts everything NOT paved as dirt (gravel + loose + unknown) — matches the orange
map paint (`1ec57dd`).

---

## 4. NS pack release lineage

| Release | Graph SHA (prefix) | Bytes | Created (UTC) | Contents |
|---|---|---|---|---|
| `ns-v3-20260823-03` | `555034df` | 14,668,092 | 08-23 22:40 | v3 leaves + G1 ferries; **path REMOVED** (atv-path only) |
| `ns-v3-20260823-04` | `8a17f47a` | 14,668,932 | 08-23 23:23 | + G2 structure (candidate) |
| `ns-v3-20260823-05` | `c2d7b2c6` | 15,570,904 | 08-24 01:32 | + **`highway=path` RESTORED** (edgeCount 199,724 → **212,041**, +~0.9 MB) — CURRENT LIVE |

Geometry stayed `96492e37…` through 03/04, refreshed to `6405e718…` in 05. Fuel sidecar
`999e1cbd…` unchanged throughout.

---

## 5. Post-v3 routing evolution (fixes on top of the pack)

- `216991c` — per-profile toggles scoped correctly (Clean = avoid-motorways only; others = allow-unknown only).
- `1ec57dd` — rider Dirt% counts gravel as dirt (number now matches the orange route on the map).
- `92a8112` — Dirt stops scoring province-wide corridors (compare 60/120 km; 180/240 km = connectivity fallback only). Killed the 2,708 km sprawl.
- `f6f5e4c` — **Clean arterial 5.5 → 1.4** (mild connector, not a metro-detour tax). Halifax→Porters Lake Clean 162 → 46 km.
- `58f9bc9` — Allow Unknown wired as an eligibility gate (not just a cost) on dirt/balanced.
- `93e6912` — **restored `highway=path`** on the NS graph → this is what produced release 05 and brought back the Myra-area trails.
- `df02213` — hide the "NS · no pack" test badge when no pack installed.
- `8898d8d` — **removed the Direct profile** (redundant with Balanced; legacy "direct" → Balanced via the unknown-profile default). Now Clean / Balanced / Dirt only.
- `d43f02e` / `0b6d114` / `5a8ffdc` — **fuel comfort window**: refuel in the 50–80% tank band, not at the 94% wall (Sydney stop 79.9%, was 99.9%).
- `9cfb5c2` — **gas-station waypoint = live refuel point** (recomputed on every itinerary edit).
- `c781ec3` — fuel continuity after waypoint edits.

## 6. Current state (2026-08-24)
- Live `serviceBuild` ≈ `c781ec3`/`5a8ffdc` (verify via curl); NS pack = release **05** (`c2d7b2c`).
- Only NS is v3; the other 62 regions are still v2 (the pack format reads both).
- Known-open: Dirt/Balanced still route on the COARSE record, not the leaves (only Clean was
  migrated); fuel gap look-ahead on empty dirt spurs; fuel-leg backtrack (Dirt reversing to
  dodge pavement). See `HANDOFF-TO-CODEX-2026-08-24.md` for the forward plan.
