# How you map a province (DIRT fabric model)

Living product doc. Companion: [DIRT-ROUTING-SYSTEM.md](./DIRT-ROUTING-SYSTEM.md).  
Updated: 2026-07-22.

## Purpose

Replicate the **Nova Scotia gold fabric** across Canada, then US states.

Gold = one rider-facing corridor network: white OSM roads everyone can use, purple provincial capillary gated by Allow. No source switches in the UI. No free-space teleports in the pack.

NS is the reference build. Every next province copies the *model*, not the NS filenames.

---

## Locked fabric layers

| Layer | Role | Access | Map paint (intent) |
| --- | --- | --- | --- |
| **1. OSM driveable highways** | Base fabric — essentially every motorized road on the basemap | `motorized_permissive` | White / road fabric. Allow does **not** gate these. |
| **2. Provincial capillary** | Fills *between* OSM roads (forest / resource / TRACK) | Mostly `motorized_unknown` | Purple. **Allow-gated.** |
| **3. NRN** | National backbone **only where still needed** (inter-province / legacy packs) | Usually permissive on inventory roads | Not part of the adventure gold story. |

### Product locks (do not regress)

1. **NS adventure fabric = OSM + NSTDB/STDB. No NRN.** Locked in registry, build scripts, longhaul meta, and `GET /api/route` note.
2. **NB adventure fabric = OSM + Forest Roads. No NRN.** Same `--osm-plus-provincial` / keep-provincial longhaul pattern as NS (capillary quality: see assessment).
3. **QC = OSM-only today.** No NRN in the routing pack. Provincial chemins adapter exists but is **not** in the live QC stack (`--osm-only`).
4. **Elsewhere:** many packs still ship **NRN (+ OSM gap-fill) ± provincial**. That is **current shipping state**, not the end state. Intent is to graduate provinces toward OSM fabric + provincial capillary (NS pattern), keeping NRN only where inter-province identity or size still forces it.

### Honest current state vs intent

| Region | Shipping fabric (now) | Intent |
| --- | --- | --- |
| **NS** | OSM + NSTDB; longhaul keeps provincial; `dropNrn: true` | Done — gold reference |
| **NB** | OSM + NB Forest Roads; longhaul keeps provincial; `dropNrn: true` | Done — same pattern as NS (capillary weaker than NSTDB on class/surface — see assessment) |
| **QC** | OSM-only longhaul + regional | Add QC capillary later if it earns its place; still no NRN |
| **ON / AB / BC** | Registry: NRN+provincial (adapters ready) | Validate OSM-as-fabric path; don’t assume NRN forever |
| **SK / MB / PE / NL / YT / NT / NU** | Mostly NRN backbone artifacts | Need OSM extract + capillary candidate before “gold” |

**Doc/code drift to watch:** older comments and `routing/conflation/conflate.js` still say “NRN owns national identity.” Prefer this doc + `routing/registry/sources.json` notes + `scripts/build-ns-regional-graph.js` / `--osm-plus-provincial` when they conflict. README still documents NRN ingest as the default path for many provinces — true for *shipping*, not for *gold intent*.

---

## Province data assessment

Before locking a province to OSM+provincial (or OSM-only), run this checklist against the capillary candidate. **NSTDB is the successful reference** — score honesty, then pick a ship path.

### Checklist questions

| Gate | Ask | Pass looks like |
| --- | --- | --- |
| **Connectivity** | Do features share / near-touch OSM endpoints? Orphan rate? Soft-stitch viable (~≤100 m)? | Capillary islands near-touch the OSM giant; not free-floating spaghetti |
| **Access tagging** | Can we default TRACK/resource → `motorized_unknown` without inventing legality? Restricted filtered? | Allow gates purple; Clean never sees unknown as the story |
| **Surface / class** | Enough paved / gravel / track / resource signal for paint + Dirt% costing? | Class mix usable; not one bucket for everything |
| **Gap-fill** | Does it sit *between* OSM roads (capillary), not duplicate the fabric? | Conflation adds capillary; duplicates skipped; `freeSpaceConnectors = 0` |
| **Legal / quality** | Open licence, live download, attribution clear? Schema stable? | OGL (or equivalent) + documented limitations |

### Decision tree

```
Capillary candidate exists?
  ├─ No  → ship OSM-only (QC pattern); hunt later
  └─ Yes → score gates above
        ├─ Connectivity + access + gap-fill strong;
        │  surface/class at least usable
        │     → ship OSM + provincial, drop NRN
        │       (--osm-plus-provincial). Longhaul: keep
        │       provincial if Allow must work cross-border
        │       (NS / NB).
        ├─ Capillary weak on class/surface but still
        │  Allow-gated gap-fill
        │     → ship OSM + provincial best-effort;
        │       document honesty in this section
        │       (NB Forest Roads).
        └─ Capillary fails connectivity or invents
           access / is legally murky
              → do NOT ship it; OSM-only or seek
                alternate capillary (better portal /
                layer / federation data).
```

### Reference scores

| Province | Capillary | Verdict | Notes |
| --- | --- | --- | --- |
| **NS** | NSTDB / STDB | **Gold — OSM+provincial** | Topology + TRACK unknown + surface/class rich; longhaul keeps purple |
| **NB** | Forest Roads (DNR-ED FeatureServer) | **Ship OSM+provincial (best-effort)** | Connectivity + unknown access + gap-fill OK; **surface/class weak** (all `resource` / sparse attrs). Keep provincial on longhaul so NS↔NB Allow works. Not NSTDB-quality on paint/cost signal — don’t pretend it is |
| **QC** | chemins multiusages (adapter ready) | **OSM-only today** | Capillary not locked into shipping stack yet |

---

## What makes STDB / NSTDB usable

Provincial capillary is only worth shipping if it earns four things:

1. **Topology / connectivity** — native endpoints that can join OSM (or soft-stitch within ~100 m when Allow is on). Orphan spaghetti that never touches fabric is dead weight.
2. **Access tagging** — TRACK / resource default `motorized_unknown`; do not invent “legal for motorcycles” from sparse gov attributes. Restricted stays out.
3. **Surface / class** — enough signal to paint and cost (paved vs gravel vs track/access). Dirt% and map paint use the same classes ([routing doc](./DIRT-ROUTING-SYSTEM.md)).
4. **Gap-fill capillary** — sits *between* OSM roads. Duplicates of OSM/NRN get conflation-skipped (~28 m midpoint heuristic). No free-space connectors in the pack.

**NS proof** (regional meta ~2026-07-22): ~134k OSM edges (all permissive) + ~239k NSTDB edges in the merged pack; access mix ~223k permissive / ~149k unknown; **~67k components** — capillary is island-heavy by design; soft-stitch (Allow on, non-Clean) bridges near-touch gaps at route time.

**NB** uses the same OSM+provincial / no-NRN stack with Forest Roads as capillary. Expect unknown-gated purple and soft-stitch; do not expect NSTDB-grade surface/class diversity (live layer is OBJECTID/length-sparse).

---

## Build pipeline pointers

```bash
# 1) OSM fabric extract (Geofabrik → geojsonseq)
bash scripts/extract-osm-roads.sh nova-scotia   # also: new-brunswick, quebec, …

# 2) NS / NB gold pattern (OSM + provincial, no NRN)
node scripts/build-ns-regional-graph.js
# equivalent:
node scripts/build-region-with-supplement.js ns --osm-plus-provincial
node scripts/build-region-with-supplement.js nb --osm-plus-provincial

# 3) QC shipping stack
node scripts/build-region-with-supplement.js qc --osm-only

# 4) Default (legacy) stack where NRN still in play
node scripts/build-region-with-supplement.js on   # NRN → OSM → provincial

# 5) What Vercel ships (thinned longhaul)
node scripts/build-longhaul-region-packs.js ns nb qc
```

**Outputs**

- Full regional: `routing/data/regions/<id>/graph.v1.json.gz` + `.meta.json`
- Longhaul: `routing/data/regions/<id>/longhaul.v1.json.gz` — NS/NB = full OSM+provincial thinned geometry (purple kept); QC = OSM-only; others often OSM+NRN with provincial dropped for size
- Registry: `routing/registry/sources.json` — per-province status, adapters, `routingMode`
- API truth: `GET /api/route` → `NS: OSM+NSTDB (no NRN). NB: OSM+Forest Roads (no NRN). QC: OSM-only…`

Riders never pick a source. The map paints one network. Shortbread tiles remain display-only; the graph is a separate extract.

---

## Conflation, giant component, islands, soft-stitch

**Conflation (pack build)**  
Backbone + supplement; skip geometric duplicates; **zero free-space connectors**. Provincial adds capillary, does not replace OSM identity on overlaps.

**Giant vs islands**  
Component 0 (or largest) is the driveable “giant,” mostly OSM permissive fabric. NSTDB TRACK lands as many small components that near-touch the giant but don’t share nodes.

**Soft-stitch (route time, not pack)**  
When **Allow is on** and profile is **not Clean**, the router may add short real-meter virtual legs (~≤100 m) island→giant and island→island so Direct/Dirt can cut through purple instead of hugging pavement and nibbling spurs.  
**Clean never soft-stitches.** Soft-stitch is Allow-only and adventure-only. **Hard ban:** dead-end ↔ dead-end gap spans are never created (no gray connectors between capillary tendrils). Only near-touch joins onto through giant fabric (degree ≥ 2) are allowed. See [DIRT-ROUTING-SYSTEM.md](./DIRT-ROUTING-SYSTEM.md).

Do not “fix” islands by baking free connectors into the pack. Health = giant usable + capillary near-touch rate + soft-stitch success on smoke ODs — not a single connected component count of zero islands.

---

## Acceptance smoke ODs (per province)

Fix a small set of origin→destination pairs that prove fabric, not UI.

| Province | Smoke OD (examples) | Expect |
| --- | --- | --- |
| **NS** | **Myra corridor** (and existing fixtures: Porters–Musquodoboit, Halifax–Yarmouth) | Clean ≈ pavement; Allow off ignores purple; Allow on opens capillary for Direct/Dirt/Balanced; Dirt dirt% ≫ Clean |
| **QC** | City↔region pairs on OSM fabric | Completes without NRN; islands handled by snap/rematch |
| **NB** | In-province forest OD + **NS↔NB** (e.g. Amherst area → Moncton / Saint John) | Allow on uses unknown capillary; Balanced Allow off/on completes; adventure stays [A,B] (no Halifax city chain) |
| **Next province** | One highway OD + one dirt-corridor OD that needs capillary | Run [Province data assessment](#province-data-assessment); OSM alone fails or is silly; OSM+provincial succeeds with Allow |

Every smoke OD should assert: complete status, rough length band, dirt%/paved% direction vs profile, and whether unknown-access meters appear only when Allow is on (and never as the Clean story).

---

## How to onboard the next province

Checklist — copy NS gold, don’t invent a new stack.

1. **Assess capillary** — run [Province data assessment](#province-data-assessment); write the verdict (gold / best-effort / OSM-only / seek alternate).
2. **Extract OSM fabric** — `extract-osm-roads.sh <geofabrik-slug>`; confirm motorized highways land as `motorized_permissive`.
3. **Adapter** — normalize to schema (`routing/schema/*`); TRACK/resource → mostly `motorized_unknown`.
4. **Build** — prefer `build-region-with-supplement.js <code> --osm-plus-provincial` once OSM extract exists. Use `--osm-only` only if capillary isn’t ready (QC pattern). Avoid NRN in the adventure pack unless you have a written reason.
5. **Conflation report** — backbone kept, supplement added, duplicates skipped, freeSpaceConnectors = 0.
6. **Health** — edge/node counts, accessCounts, surfaceCounts, componentCount; spot-check giant vs purple islands on map.
7. **Longhaul pack** — **keep provincial** when riders must Allow-on across borders (NS/NB); omit-for-size only with an explicit honesty note. Document in longhaul meta `mentalModel` / `extractMode`.
8. **Registry** — update `routingMode`, osm role, NRN notes (“omitted from fabric” when locked).
9. **Smoke ODs** — highway + capillary corridor (+ cross-border if adjacent gold province); run profile matrix with Allow on/off.
10. **Ship** — regional + longhaul on `main` (production). Preview branches don’t update live POC.

US states later: same three-layer model (OSM fabric + state resource/forest capillary; no Canadian NRN).

---

## Open questions / risks

- **NRN sunset path** — which provinces keep NRN for inter-province stitching vs drop it like NS/NB/QC?
- **Longhaul size** — NS/NB keep provincial on Vercel; larger provinces will hit Hobby limits. Capillary-on-longhaul vs in-province-only packs.
- **QC capillary** — adapter ready; product hasn’t locked it into the shipping stack.
- **NB class poverty** — Forest Roads have no surface/class attrs; Dirt% paint signal is coarser than NSTDB.
- **Island density** — NS ~67k components; soft-stitch cost/latency on big Allow-on Direct/Dirt searches.
- **Licence / portal blockers** — SK, MB, NU historically hard; NL/YT/NT verified REST but no adapter yet.
- **Conflation comments still NRN-first** — code comments can mislead the next agent; treat product locks above as higher priority.
- **Clean + Allow** — product law is Clean immune to Allow; verify engine never paints Clean as purple. Details in routing doc.

---

## Insights / next direction

- **Treat NS OSM+NSTDB as the gold template; NB is the same pattern with a weaker capillary** — next province work is “assess → `--osm-plus-provincial` or OSM-only,” not “ingest more NRN.”
- **Write smoke ODs before more adapters** — Myra-style A→B per profile locks product law better than another registry row.
- **Longhaul purple is required for Allow-on cross-border** — NS and NB keep provincial; don’t strip purple and then wonder why Allow is useless.
- **Kill NRN-first doc drift in comments/README** as you touch files — living docs win until code comments catch up.
- **QC capillary is the next fabric experiment** — OSM-only is honest today; don’t pretend chemins are live.
- **Giant-component count is a health signal, not a fail** — optimize soft-stitch + near-touch, don’t force one component in the pack.
