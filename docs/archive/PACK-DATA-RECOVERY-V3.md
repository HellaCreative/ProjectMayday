ARCHIVED 2026-08-23 — superseded by docs/PACK-DATA-V3-AUTHORITY.md

# DIRT — Pack Data Recovery (Pack v3): Step-by-Step for Cursor

Purpose: fix the foundational pack-data mistake so Clean works and the dirt/paved
percentages become trustworthy — by correcting the DATA MODEL, not by adding more
Clean cost weights. Do this **Nova Scotia only** first.

## 0. The mistake (why we're here)

OSM `highway=*` classifies *function* (motorway, residential, track, path…), NOT
surface. `surface=*`, access, and track quality are **separate** attributes. Our
pack collapsed them: untagged roads became "unknown," and the router then treats
unknown as **dirt** (inflating Dirt%) and as **impassable for Clean** (deleting the
real paved back-road network). That double error is the whole Clean failure.

**The one rule that fixes the most:** *Unknown surface must never secretly count as
dirt or as pavement.*

## 1. The v3 edge contract (keep these INDEPENDENT — never collapse)

Every routable edge stores, as separate fields:

| Field | Values | Used for |
|---|---|---|
| `roadClass` | motorway, trunk, primary, secondary, tertiary, unclassified, residential, service, track, path, road | major-road avoidance + hierarchy |
| `surfaceFamily` | paved, unpaved, unknown | dirt vs pavement % + Clean eligibility |
| `surfaceSource` | tagged, inferred | so we know our confidence |
| `access` | permitted, unknown, restricted, excluded | legal use by a motorcycle |

Keep road class as its TRUE OSM value — do not lump trunk with primary, or tertiary
with unclassified. Encode compactly (enums/bitfields — a few bytes/edge, not strings).

**Defer to a later v3.1** (do NOT build now): surface *detail* (asphalt/gravel/dirt/
sand), `tracktype` grade1–5, `smoothness`, and context (bridge/tunnel/ferry). Those
are for ride-quality and richer visual mapping once v3 ships.

## 2. Normalization rules (in the OSM adapter, `osm-roads.js`)

- **Explicit `surface=*` wins**, always → `surfaceFamily` = paved/unpaved from the tag, `surfaceSource=tagged`.
- **Missing surface → infer a family from road class, but MARK it inferred:**
  - motorway, trunk, primary, secondary, tertiary, **unclassified**, residential, service → `surfaceFamily=paved`, `surfaceSource=inferred`.
  - track, path → `surfaceFamily=unpaved`, `surfaceSource=inferred`.
  - `highway=road` (truly unknown class) → `surfaceFamily=unknown`.
- **`track` is NOT automatically dirt** and **primary/secondary are NOT automatically paved** — an explicit `surface=*` on any of them overrides the inference.
- `access` is normalized on its own precedence (`motorcycle`→`motor_vehicle`→`vehicle`→`access`) and is **never** merged into surface or class.

This is where the in-flight `unclassified→paved` change belongs — it's correct, just
make it part of this consistent inference layer and record `surfaceSource=inferred`.

## 3. How the router uses v3 (rules, not guesses)

**Dirt % (all profiles):** count as "dirt" ONLY `surfaceFamily=unpaved`. `inferred`
paved counts as paved. `unknown` counts as neither — show it as its own small bucket
or omit, but never as dirt. (This alone makes Dirt's % honest and will likely drop
inflated numbers slightly — expected, not a regression.)

**Clean tiers (route on ACCESS, prefer PAVED):**
1. Paved (tagged or inferred), motorcycle-accessible, outside urban cores, excluding
   motorway + trunk.
2. Prefer tertiary / unclassified / rural residential / appropriate service; permit
   secondary/primary as connectors when needed.
3. Permit motorway/trunk ONLY when the lower network can't complete the route (label it).
4. Permit a minimal unpaved connector or urban passage ONLY when no fully-paved
   non-urban route exists (label it). Never a routine fallback.

**Split the old "Avoid Highway & Motorway" slider into two:**
- **Avoid motorways:** motorway + trunk (strong).
- **Prefer back roads:** progressively *penalize* primary + secondary — **never delete
  them from the graph** (hard-exclusion destroys connectivity between rural networks).

## 4. Recovery sequence (NS only, in order)

1. **Freeze** Clean cost/city/motorway tuning against the current compressed pack.
2. **Audit** the raw NS OSM extract: total edge length across `highway × surface ×
   access`. Know what you actually have before rebuilding.
3. **Define + version the v3 edge contract** (§1) as a written schema.
4. **Rebuild NS only** with the v3 adapter (§2).
5. **Add graph-debug display modes:** Access, Surface family, Road class as separate
   layers — so you can visually confirm a road you KNOW is paved is normalized paved.
6. **Validate visually:** known paved roads, forestry tracks, restricted paths,
   unknown-surface edges — spot-check on the map.
7. **Fixed-pin test** Dirt / Balanced / Direct / Clean on identical pins; confirm each
   behaves per spec (Dirt high real dirt, Balanced ~50%, Direct ≥60%, Clean ~0% dirt
   on a sane paved back-road route).
8. **Physically test NS** on device.
9. Only then, **reuse the exact same builder + gates** for every CA/US pack.

## 5. Guardrails

- **Do NOT** repair this with more Clean weights or slider values — that teaches the
  router to guess data the pack discarded. Fix the pack + the honest rules.
- **Do NOT** boil the ocean: v3 = roadClass + surfaceFamily + surfaceSource + access.
  Ship that, then add detail/tracktype/smoothness as v3.1.
- Rebuild is NS-only until it's proven; publish live + downloadable as the same bytes;
  keep the prior NS bytes so you can roll back.
- Every route result already logs its pack revision — keep that, so a bad rebuild is
  obvious.

## 6. Definition of done (NS)

- A rural road you've physically ridden as pavement shows `paved` in the Surface
  debug layer and is usable by Clean.
- Clean produces ~0% dirt on a sensible paved back-road route, no pathological detour,
  no routine unpaved fallback.
- Dirt/Balanced/Direct unchanged in character; Dirt's % is honest (real unpaved only).
- The same builder is ready to run for the remaining packs.
