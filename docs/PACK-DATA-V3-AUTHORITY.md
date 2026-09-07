# DIRT — Graph V3 pack-data authority

> **Status: AUTHORITY for the Graph V3 binary/data model.** Ride-mode and routing
> laws remain governed by `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`.
> Regional replication and release now follow `docs/PACK-FACTORY.md`. The V3
> implementation is complete; the dated phase sequence below is retained only as
> design rationale and must not be rerun as a new migration.

**Supersedes the framing of `PACK-DATA-RECOVERY-V3.md`.** That doc correctly wanted
honesty and independent dimensions, but its edge contract (`surfaceFamily =
paved/unpaved/unknown`) *compressed harder*, and it deferred exactly the leaf detail
this app is built on. This doc corrects that: **the pack's job is to preserve OSM's
leaf granularity; bucketing into cheap families is the router's job, done at read
time from the preserved leaf.**

The format was proved through the promoted NS, NB, PE, NL, QC, and ON reference
packs. Their accepted bytes are frozen in
`docs/ROUTING-FREEZE-2026-09-03.md`. New regions copy that mould one at a time;
they do not restart the original Nova Scotia migration.

**DEFINITION OF DONE (every phase): DEPLOYED LIVE + VERIFIED — not "committed."** The app
routes via the live Vercel engine (`selected=live`), so a phase is only testable once BOTH
the code and the pack are live. Every phase gate MUST end with: (1) deploy the live engine
at the phase HEAD commit; (2) publish/replace any changed pack; (3) verify against the live
endpoint that the route-identity `build=` stamp equals the HEAD commit (NOT an older one)
and the pack hash is the new one. Nothing is "ready to test" until that stamp check passes.
Never leave code committed-but-undeployed.

---

## 0. Root cause (verified in code, 2026-08-23)

**The loss is a 4-link chain, not the binary alone. Widening the u16 by itself would
recover nothing.** Leaf detail dies at each step: (1) the OSM adapter maps leaves to
coarse families; (2) the canonical schema (`edge.js`) only formalizes those coarse
categories; (3) the regional packager discards the `meta` bag that holds the raw
leaves; (4) the on-device record is a full 16-bit int with no room for more anyway.
All four links must change — this is why it's a build-order, not a one-file fix.

The on-device edge record is a **single `UInt16`**, fully allocated:

```
bit 0–2  surface     (3 bits → max 8 values)
bit 3–5  access      (3 bits)
bit 6–8  structure   (3 bits)
bit 9–10 confidence  (2 bits)
bit 11   seasonal    (1 bit)
bit 12–15 roadClass  (4 bits → max 16 values)
```

Consequences, all confirmed:
- **Surface caps at 8 families** → `osm-roads.js` collapses every OSM `surface=`
  value (asphalt, concrete, cobblestone, sett, paving_stones, gravel, fine_gravel,
  compacted, dirt, sand, mud, grass, clay…) into paved / gravel / resource /
  double_track / track / unknown. Ride-critical distinctions (fine_gravel vs sand vs
  mud) are destroyed at build time.
- **No bits for `tracktype` (grade1–5) or `smoothness`** — the core dual-sport
  ride-quality signal is absent entirely.
- **Leaves are read, then discarded.** `osm-roads.js` (~L427) stashes raw
  `surface` / `tracktype` / `layer` in `meta`, but `meta` is not serialized into the
  `.bin`. The detail exists at parse time and is thrown away at pack time.
- **Structure is under-decoded (not un-handled).** `layer`/`bridge`/`tunnel` already
  drive node separation at build time (`grade-bucket.js`, `regional/package.js`), so
  overpass topology is correctly separated — it is NOT flattened. What's missing is
  richer structure tags in the adapter (it reads only `bridge=yes`/`tunnel=yes`) and
  on-device decode (`GraphV2Pack.swift` has no `unpackStructure`). This is a real gap
  but a lesser, separate workstream (§G) — not the surface/Clean root cause.

Fixing this requires a **versioned format change** (`GRAPH_VERSION 2 → 3`) decoded
identically by the JS engine (`routing/lib/pack-v2.js`, live `api/route.js`) and the
Swift engine (`Routing/OnDevice/GraphV2Pack.swift`). Both engines must stay in
lockstep (there is already `scripts/assert-live-pack-lockstep.js`).

## 1. Target v3 edge model (preserve leaves; derive families at read time)

**Two primary dimensions, each with a distinct job — never collapse either:**
- **Surface leaf** drives **Dirt / Balanced / Clean** (the real dirt↔paved
  spectrum; makes Dirt% honest).
- **Road-class leaf** drives **Clean specifically** — so Clean can read road nuance and
  prefer rural paved ancillary roads while avoiding highways/freeways.
Structure (tunnel/overpass) rides the same rails but is secondary to these two.

**Do NOT preserve the old `UInt16` coarse record as the model** — it is a ~2-month-old
guess (likely a file-size hedge) and it is not working; it is the thing being replaced.
A v3 reader must still *load* v2 packs for rollback, but v3 does not carry the coarse
integer forward as its source of truth. Design the v3 record to hold the leaves
directly. Store per-edge leaf values as 1-byte indices into per-pack string
dictionaries carried in `enumsJson` (mirror the existing `accessNames` pattern — do not
store repeated strings per edge). Recommended sections:

| New section | Type | Meaning |
|---|---|---|
| `edgeSurfaceLeaf` | `Uint8` | index into `surfaceLeafNames` (raw OSM `surface=`, normalized token; `0` = untagged) |
| `edgeRoadClassLeaf` | `Uint8` | index into `roadClassLeafNames` (raw OSM `highway=`; `0` = unknown) |
| `edgeGrade` | `Uint8` | **nibble each**: tracktype in bits 0–3 (0 = none/missing, 1–5 = grade1–5), smoothness in bits 4–7 (0 = missing, 1–8 = excellent…impassable). Smoothness has 8 OSM values + missing = 9 states → needs a full nibble, not 3 bits. |
| `edgeLayer` | `Int8` | OSM `layer=` (signed; distinguishes overpass `>0` from underpass `<0` from at-grade `0`) |
| `edgeStructureLeaf` | `Uint8` | index into `structureLeafNames` (bridge/tunnel/viaduct/culvert/ford/ferry/…; `0` = none) — supersedes the 3-bit coarse field for reading |
| `edgeAccessLeaf` | `Uint8` | index into `accessLeafNames` (raw effective access value incl. an `atv_permitted` entry; `0` = unknown) — parallels the existing `accessNames`; keeps access independent of surface |
| `edgeFlags` | `Uint8` | per-edge bit flags. **bit 0 = `atvDesignated`** (atv ∈ {yes,designated,permissive}; switch-governed routing input — the ATV-trail recovery); bit 1 = `seasonal`; bits 2–7 reserved (0) |

Total new per-edge cost = **7 bytes** (surfaceLeaf, roadClassLeaf, grade, layer, structureLeaf, accessLeaf, flags). For NS post-B (~199,724 edges) ≈ **+1.4 MB** against the ~13 MB graph — still modest. `atvDesignated` gets its own flag bit (not a dictionary) because the router reads it on the hot path as a boolean; `layer` stays `Int8` (no dictionary). All string dictionaries (`surfaceLeafNames`, `roadClassLeafNames`, `structureLeafNames`, `accessLeafNames`) live in `enumsJson`, index 0 = untagged/unknown sentinel, builder fails closed if any exceeds 255. Fail-closed if any region's dictionary exceeds 255 entries — do not let an NS-only assumption ship a broken national pack; widen the index type or split the dictionary if a region overflows.

**Compound surfaces** (e.g. `surface=asphalt;gravel`): the contract stores the
**normalized full compound value as a single dictionary token** (`asphalt;gravel` is
its own entry). Read-time family logic may split it; the pack does not pre-decide. This
keeps encoding lossless and the index one byte. (Confirm compound frequency in Phase A.)

**The u16 is not deleted — it is demoted.** Leaves are authoritative. The existing
16-bit record stays only as a **derived fast-costing cache, regenerated from the leaves
at build time** — never the source of truth, never hand-maintained. This satisfies both
constraints: the broken lossy value is no longer authoritative, and graph expansion
(hundreds of k edge relaxations per route) still gets O(1) coarse costing without
touching the dictionaries on the hot path.

(Per-edge cost and edge count: see the 7-byte / ~199,724-edge / ≈ +1.4 MB / 4 dictionaries figure above. The "base OSM extract" is multi-GB, but that is the raw input, not the shipped pack — do not compare against it.)

### Graph v3 byte layout (Phase C / Phase D contract — exact)

All multi-byte integers are **little-endian**. Magic and geometry format unchanged from v2.

**File:** `graph.v3` binary (same `GRAPH_MAGIC = 0x32473244`). Geometry remains `geometry.v1`.

| Offset | Type | Field |
| --- | --- | --- |
| 0 | u32 | magic `0x32473244` |
| 4 | u16 | `version` = **3** (decoder also accepts **2**) |
| 6 | u16 | `flags`: bit0 = `edgeFrom`/`edgeTo` present; **bit1 = v3 leaf sections present** (`FLAG_V3_LEAVES=2`); bits 2–15 reserved 0 |
| 8 | u32 | `nodeCount` |
| 12 | u32 | `undirectedEdgeCount` |
| 16 | u32 | `directedArcCount` |

`directedArcCount` is the number of **legal travel arcs**, not `2 × undirectedEdgeCount`. Bidirectional edges emit two CSR arcs; one-way edges emit only the permitted arc. Snap/virtual entry must follow those arcs.
| 20 | u32 | `headerSize` = **100** for v3 (v2 was 72) |
| 24 | u32 | off `nodeOffsets` (Int32 × nodeCount+1) |
| 28 | u32 | off `edgeTargets` (Int32 × directedArcCount) |
| 32 | u32 | off `edgeUndirectedIndex` (Int32 × directedArcCount) |
| 36 | u32 | off `edgeAttrs` (Uint16 × undirectedEdgeCount) — **derived coarse cache** |
| 40 | u32 | off `edgeMeters` (Uint32 × undirectedEdgeCount) |
| 44 | u32 | off `nodeCoords` (Float32 × nodeCount×2) |
| 48 | u32 | off `idOffsets` (Int32 × undirectedEdgeCount+1) |
| 52 | u32 | off `idBlob` (utf8) |
| 56 | u32 | off `enumsJson` (utf8 JSON) |
| 60 | u32 | off `metaJson` (utf8 JSON) |
| 64 | u32 | off `edgeFrom` (Int32 × undirectedEdgeCount) when flags bit0 |
| 68 | u32 | off `edgeTo` (Int32 × undirectedEdgeCount) when flags bit0 |
| **72** | u32 | off **`edgeSurfaceLeaf`** (Uint8 × undirectedEdgeCount) — **appended** |
| **76** | u32 | off **`edgeRoadClassLeaf`** (Uint8 × …) |
| **80** | u32 | off **`edgeGrade`** (Uint8 × …) |
| **84** | u32 | off **`edgeLayer`** (Int8 × …) |
| **88** | u32 | off **`edgeStructureLeaf`** (Uint8 × …) |
| **92** | u32 | off **`edgeAccessLeaf`** (Uint8 × …) |
| **96** | u32 | off **`edgeFlags`** (Uint8 × …) |

**Payload order:** existing v2 sections first (same relative order as today), then
`enumsJson`, `metaJson`, then the seven leaf arrays in the order above. `metaJson` ends
at `edgeSurfaceLeaf` offset (not EOF) when bit1 is set.

**`edgeGrade` (Uint8):** bits 0–3 = tracktype code (0=none, 1–5=`grade1`…`grade5`);
bits 4–7 = smoothness code (0=missing, 1=`excellent`, 2=`good`, 3=`intermediate`,
4=`bad`, 5=`very_bad`, 6=`horrible`, 7=`very_horrible`, 8=`impassable`).

**`edgeFlags` (Uint8):** bit0=`atvDesignated`; bit1=`seasonal`; bits 2–7 = 0.

**`enumsJson` dictionaries** (arrays of strings; index 0 = sentinel):
`surfaceLeafNames` (0=`""`), `roadClassLeafNames` (0=`"unknown"`),
`structureLeafNames` (0=`""`), `accessLeafNames` (0=`""`), plus existing
`SURFACE`/`ACCESS`/`STRUCTURE`/`*_NAME` maps. Builder **fails closed** if any leaf
dictionary length > 255.

**v2 rollback:** version=2 packs omit offsets 72–96 and bit1; JS/Swift readers use coarse
`edgeAttrs` only (no error).

**Phase A results (NS, 2026-08-23 — confirmed against `roads.geojsonseq`, 60,992 km /
141,022 ways):** cardinality per tag fits `Uint8` with wide headroom (surface 38 → 217
spare; highway 17; tracktype 6; smoothness 9; layer 6; bridge 11; tunnel 4; ford 4) —
`Uint8` locked for NS, fail-closed >255 stays for national. Compound surfaces negligible
(~5 km / 0.01%). `edgeGrade` nibbles confirmed (smoothness needs 4 bits). `layer` → `Int8`
directly (6 values), no dictionary. Coverage is sparse for enrichment tags: tracktype
~1,012 km, smoothness ~741 km, layer/bridge/tunnel/ford 99% missing — read-time logic must
treat these as *refinements where present*, never required.

**Key policy finding (drives Phase E, not the data plan):** `surface=unpaved` alone is
**49% of the network (30,004 km)** and is OSM's *deliberately vague* "not-paved,
unspecified" value — it is NOT technical dirt/sand/mud (those total only ~800 km).
Therefore: (1) `unpaved` must be preserved as its own leaf, distinct from the granular
resource surfaces (raw-leaf preservation does this) and read-time family logic must not
equate "unspecified unpaved" with technical resource; (2) with 49% `unpaved` + 16%
`missing` (highway-inferred), the **road-class leaf carries more of the Clean signal than
surface does** — confirming road-class as a co-equal dimension.

**LOCKED TAXONOMY (Rick, 2026-08-23) — the read-time family map + graph membership.**
Leaves are always preserved in the pack; these are the top-level families leaves roll up
into at read time, plus build-time membership changes.

*Surface families (4):*
- **Paved:** asphalt, paved, concrete, chipseal, paving_stones, cobblestone, sett, brick,
  metal, wood — Clean target, never switch-gated.
- **Gravel:** gravel, compacted, fine_gravel, pebblestone, **+ `unpaved` (the 49% leaf)**.
  Rationale: `unpaved` is "unspecified, not technical" → a usable unpaved surface, so it
  rolls under Gravel, NOT Loose/technical.
- **Loose / technical (switch-governed):** dirt, ground, earth, grass, mud, sand, rock,
  natural, woodchips.
- **Unknown (switch-governed):** missing (16%) + compound oddballs (gravel,earth; trail;
  rocky; marsh; mowed_grass/dirt; dirt/loose_rock; …).
The mode switch (Dirt↔Clean) governs tolerance of Loose/technical + Unknown. **Dirt%
(E1, locked):** share of route distance whose surface family ∈ {Loose/technical,
Unknown}. **Gravel does not count as dirt.** Paved and Gravel are reported separately;
Unknown is also a distinct `unknownSurfacePercent` bucket and is never silently folded
into paved.

*Road tiers (Clean):*
- Motorway (motorway/_link) → avoid hard. Trunk (trunk/_link) → avoid.
- **Arterial = primary/_link → CONNECTOR ONLY.**
- **Collector = secondary/_link → Clean's backbone / primary road type.**
- Local paved through-routes: tertiary, unclassified (+ links).
- **Residential + living_street → DESTINATION-ACCESS ONLY** — never used as a through-
  route; routable only when a waypoint is placed on them (reach a specific street).
- track → adventure/dirt (kept).

*Graph membership (build-time):*
- **Keep all `track`. Keep all `path`. Drop all `cycleway`.** Untagged `path` is
  `motorized_unknown` and is search-gated by Allow unknown. Positive
  `atv ∈ {yes, designated, permissive}` still marks the edge `motorized_permissive`
  (and still overrides vehicle-type deny). Cycleway stays out (zero `atv=`). All other
  non-motoring ways (footway/pedestrian/steps/bridleway/busway/corridor…) stay excluded
  by the allowlist.
- **ATV access rule (LOCKED, Rick 2026-08-23): positive `atv` overrides a vehicle-type
  deny.** Rationale: a dual-sport is an off-road vehicle allowed on ATV trails; `motorcycle=no`
  on such a trail means "street bikes can't handle it," not a legal bar. So for the access
  model, an edge with `atv ∈ {yes, designated, permissive}` is treated as **permitted and
  routed as an adventure/ATV trail (switch-governed like Loose/technical)**, overriding
  `motorcycle=no` / `motor_vehicle=no`. **Guardrail:** `atv` does NOT override a hard land
  deny (`access=private` / `access=no`) — private property stays excluded. NS impact
  (audit 2026-08-23): recovers all **350.7 km** (100% was `motorcycle=no`, 0 km hard-denied;
  94% is `highway=path` + `atv=yes`). These atv-positive paths are therefore KEPT by the
  membership rule above AND rescued from access-exclusion. B2 preserves `accessLeaf` + raw
  `atv` and derives `atvDesignated` (lossless marking + debug layer).
- **Ferries: INCLUDE (new).** Currently fully excluded (adapters reject `route=ferry`;
  the `structureType=ferry` enum slot is unused). Add a `route=ferry` inclusion path →
  `structureType=ferry` + crossing time/cost. Essential for cross-province (NL Country
  Harbour, BC). Belongs to §G structure workstream but **elevated priority**.

**Rule that must never be violated again:** no lossy bucketing at build time. The
adapter records the leaf; families are computed at read time by both engines from the
same leaf → family table (shipped in `enumsJson` so it can never drift between
engines).

## 2. Historical implementation order (completed; do not execute as factory instructions)

### Historical precondition — checkpoint the tree
At the time of the original migration the worktree was not clean: HEAD `aabbd64`, ~30 modified tracked files
(including the source of truth, public manifest, NS fuel sidecar, JS + Swift routing,
and tests), 9 untracked files, 3 stashes, plus the separate `Dirt-pack-rebuild`
worktree. **No binary-format migration begins on top of uncommitted work.** Phase A is
read-only and safe as-is. Before Phase B: identify and preserve the current changes
(commit or stash with a labelled checkpoint), and reconcile which of the two v3 docs is
live (this one supersedes `PACK-DATA-RECOVERY-V3.md`). Rick makes the git call.

### Phase A — Audit (no format change)
Extend `scripts/audit-osm-surface-normalization.js` to report, for the raw NS extract,
**included routable** edge-length (km) distribution across **distinct** `surface=`,
`highway=`, `tracktype=`, `smoothness=`, `layer=`, `bridge=`, `tunnel=`, `ford=` — the
actual leaf values and how much network each covers. Also report, per tag: **missing/
untagged km**, **compound values** (e.g. `asphalt;gravel`) and their frequency,
**dictionary cardinality** (distinct-value count → confirms Uint8 headroom), and the
**current coarse-category mapping** (which family each leaf collapses into today). No
schema or pack changes. **Gate:** we can see, e.g., "X km of `fine_gravel`, Y km of
`sand`, Z km of untagged `track`" that today all read as one bucket, plus the exact
dictionary sizes and compound-value share.

### Phase B — Capture leaves in the schema (no `.bin` change)
In `routing/schema/edge.js` + `routing/adapters/osm-roads.js`: carry `surfaceLeaf`,
`roadClassLeaf` (raw `highway`), `tracktype`, `smoothness`, `layer`, and a richer
`structureLeaf` (read `bridge`/`tunnel`/`ford`/`layer` — not just `=yes`) as
first-class edge fields through `createNormalizedEdge` and the intermediate JSON graph.
Do **not** remove the existing coarse fields. **Gate:** the JSON graph + audit counts
show leaves preserved end-to-end; existing tests still green; coarse fields unchanged.

### Phase C — Format v3 encode + JS decode
In `routing/lib/pack-v2.js`: bump `GRAPH_VERSION` to 3; add the five sections from §1 +
the dictionaries in `enumsJson`; set a flags bit signalling leaf sections present.
Update **both** the encoder and the JS reader; a v3 reader must still read v2 packs
(absent sections → coarse fallback). Update `convertV1FileToV2` path as needed. **Gate:**
round-trip test (encode→decode) recovers every leaf; `assert-live-pack-lockstep.js`
passes; v2 packs still load.

### Phase D — Swift decode v3
In `Routing/OnDevice/GraphV2Pack.swift`: accept version 3; read the new sections and
dictionaries (extend the existing `accessNames` dictionary mechanism); add
`surfaceLeaf`, `roadClassLeaf`, `unpackTracktype`, `unpackSmoothness`, `layer`. Keep a
v2 fallback path. **Do not alter routing yet.** (Structure decode is deferred to the
separate structure workstream, §G.) **Gate:** device loads a v3 NS pack; a spot-checked
edge exposes the same leaf values the JS decoder sees (byte-identical lockstep).

### Phase E — Consume, split into independent gates
Phase E is intentionally split — each sub-gate is separately testable and must not
regress the others. Do them in order:
- **E1 — Statistics only.** Router reads leaves for honest Dirt% (count real unpaved
  leaves only; untagged `unknown` is its own bucket, never silently dirt or paved —
  identical in both engines). No route-selection change yet. **Gate:** Dirt% shifts to
  honest values; Dirt/Balanced route selection unchanged.
- **E2 — Clean behavior.** Clean reads surface leaf (prefer paved) + road-class leaf
  via shared `roadTierMap` (collector = backbone; arterial = connector; motorway/trunk
  avoided; residential/living_street = destination-access only). **Gate:** JS↔Swift
  identical Clean path on NS v3; Clean ~0% honest dirt on a sane paved back-road;
  Dirt/Balanced selection unchanged.
- **E3 — Debug display layers.** Surface-leaf, Road-class-leaf, Access as separate map
  layers (GRAPH debug paint modes) plus an always-visible pack version badge
  (`NS v3 · <revision>` / `v2`). **Gate:** spot-checks match known roads; badge reads
  v3 with leaves pack and v2 on fallback; no routing change.
- **E4 — Split the "Avoid Highway & Motorway" control** into **avoid motorway/trunk**
  vs **prefer back roads (penalize primary/secondary — never delete)**. **Gate:** the
  two controls behave independently; connectivity preserved.

### Phase F — Rebuild NS + version-safe rollout + ride test
Rebuild NS with the v3 adapter into an **immutable v3 candidate**; keep prior v2 bytes.
`assert-live-pack-lockstep.js` green. **Rollout is version-gated, NOT same-bytes:**
installed v2 clients hard-reject v3, so the download catalog must serve v2 bytes to v2
clients and v3 bytes only to v3-capable clients — never overwrite the public pack in
place. Test on White, then physical NS ride test. Only then template the exact builder
for other packs (each with the fail-closed dictionary check, §1).

### §G — Structure / topology (SEPARATE, lesser workstream — not in the critical path)
`layer`, `bridge`, and `tunnel` already drive node separation at build time
(`grade-bucket.js`, `regional/package.js`) — overpass topology is NOT flattened today;
only on-device *decode/presentation* of structure is missing. So richer structure
(overpass/underpass/tunnel modelling + Swift `unpackStructure`/`structureLeaf` decode)
is worthwhile but runs on its own track, after the surface/Clean repair lands. Do not
couple it to Phases A–F.

## 3. Guardrails
- Treat the promoted NS/NB/PE/NL/QC/ON set as read-only reference bytes. New
  regions are built and accepted one at a time. Both engines remain byte-identical.
- Legacy CanVec `track` and `service` ways without explicit motor-access evidence
  encode as `motorized_unknown`; the source tag is provenance, never permission.
- Access-only repairs to a frozen pack must begin with checksum-verified live
  bytes and preserve topology and geometry. Use the independently classified
  build only as an edge-ID oracle, then patch only access/confidence fields via
  `reclassify-legacy-canvec-v3.js`; publish candidate, benchmark those remote
  bytes, and promote the identical release.
- No lossy bucketing at build time — leaves preserved, families derived at read time
  from a shipped table.
- Don't boil the ocean beyond §1: surface leaf + road-class leaf + tracktype +
  smoothness + layer + structure leaf. That is the full useful set for routing, ride
  quality, and structure; further richness (e.g. width, incline) is a later add on the
  same rails.
- Every route result already logs pack revision — keep it; a bad rebuild stays obvious.
