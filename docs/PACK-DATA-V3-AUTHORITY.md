# DIRT — Pack Data De-compression (Graph v3): Claude Build Order

> **Status: AUTHORITY for pack-data / Graph-v3 (approved 2026-08-23). Ride-mode and
> routing-law definitions remain governed by docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-
> TRUTH.md; this doc governs the pack data model and the v3 build order.** Reviewed by Codex 2026-08-23; corrections below are incorporated.

**Supersedes the framing of `PACK-DATA-RECOVERY-V3.md`.** That doc correctly wanted
honesty and independent dimensions, but its edge contract (`surfaceFamily =
paved/unpaved/unknown`) *compressed harder*, and it deferred exactly the leaf detail
this app is built on. This doc corrects that: **the pack's job is to preserve OSM's
leaf granularity; bucketing into cheap families is the router's job, done at read
time from the preserved leaf.**

Nova Scotia only until proven. One phase at a time. Physically test between phases.
Never stack. Restore floor stays commit `7cd5a40`.

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
- **Surface leaf** drives **Dirt / Balanced / Direct / Clean** (the real dirt↔paved
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

Dictionaries (`surfaceLeafNames`, `roadClassLeafNames`, `structureLeafNames`) live in
`enumsJson`, index 0 reserved for the untagged/unknown sentinel. NS dictionaries are
small (~30 / ~15 / ~8 entries), so `Uint8` indices are ample **for NS** — but the
builder MUST **fail closed** (hard error, no silent truncation) if any region's
dictionary exceeds 255 entries. Do not let an NS-only assumption ship a broken
national pack; widen the index type or split the dictionary if a region overflows.

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

Cost: ~5 bytes per undirected edge (`surfaceLeaf` + `roadClassLeaf` + `grade` + `layer`
+ `structureLeaf`). NS is **217,057 edges → ≈ +1.1 MB** against a **~13 MB** graph pack
(geometry ~22 MB, fuel ~140 KB) — a real but modest increase. (The "base OSM extract" is
multi-GB, but that is the raw input, not the shipped pack — do not compare against it.)

**Rule that must never be violated again:** no lossy bucketing at build time. The
adapter records the leaf; families are computed at read time by both engines from the
same leaf → family table (shipped in `enumsJson` so it can never drift between
engines).

## 2. Build order (each phase independently testable; NS only)

### Precondition — checkpoint the tree (before Phase B; Phase A is safe on a dirty tree)
The worktree is currently NOT clean: HEAD `aabbd64`, ~30 modified tracked files
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
  honest values; Dirt/Balanced/Direct route selection unchanged.
- **E2 — Clean behavior.** Clean reads surface leaf (prefer paved) + road-class leaf
  (prefer rural ancillary, avoid highway/freeway). **Gate:** Clean ~0% dirt on a sane
  paved back-road route; Dirt/Balanced/Direct do not regress.
- **E3 — Debug display layers.** Surface-leaf, Road-class-leaf, Access as separate map
  layers, to visually verify a road you KNOW is fine gravel reads as such. **Gate:**
  spot-checks match reality on the map.
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
- NS only until proven. Keep prior NS bytes for rollback. Both engines byte-identical.
- No lossy bucketing at build time — leaves preserved, families derived at read time
  from a shipped table.
- Don't boil the ocean beyond §1: surface leaf + road-class leaf + tracktype +
  smoothness + layer + structure leaf. That is the full useful set for routing, ride
  quality, and structure; further richness (e.g. width, incline) is a later add on the
  same rails.
- Every route result already logs pack revision — keep it; a bad rebuild stays obvious.
