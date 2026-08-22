# DIRT — Map refinement (locked)

> **Authority boundary:** this document remains locked for road eligibility,
> surface, access, corridor, urban, stitch, and seam laws. Current online/offline
> source policy, release state, and work priority live in
> [`00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`](00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md).
> Later rider decisions supersede the older source-selection tables below.

How Dirt chooses roads, what Layers may paint, how packs are joined, and how
profiles cost a ride. These laws apply identically to live and on-device routing.
Do not re-open these laws to chase a dirt% number.

**Last confirmed:** 2026-08-19 (R2 catalog = all CA + US; Vercel = API only; develop in iOS Dirt only).
**Next confirm:** BC DRA `resource` test under those laws. Nova Scotia stays frozen.

---

## Verdict: 67% vs 37%

Chilliwack→Enderby, Dirt profile:

| Allow unknown | Typical dirt% | What the router can use |
| --- | ---: | --- |
| Off (default) | ~35–37% | Permissive OSM only (yellow / white / track / resource) |
| On | ~62–67% | Same, plus purple `motorized_unknown` |

That gap is the **legal gate working**, not a failed cost table.

Dirt already taxes pavement harder than Balanced, but **not** so hard that a
200 m paved connector to an FSR is refused. Dijkstra will take any *connected*
permissive dirt that still progresses toward B. The remaining Allow-off
ceiling is **connectivity of permissive OSM**, not “turn the paved tax up
again.”

**Do not** try to make Allow-off look like Allow-on. Purple Access stays
opt-in. **Do not** default Allow unknown on. **Do not** stitch
`motorized_unknown` at pack time. **Do not** bring Wander back — Dirt /
Balanced / Direct / Clean *are* the dial.

Alberta is the check: prairie OSM grid should connect better than BC
mountains. If Allow-off dirt% on a long AB hop is already in the 40s–50s,
the BC 37% was terrain. If AB still jumps ~30 points when Allow turns on,
that is provincial Access Roads sitting in `motorized_unknown` — same law.

---

## Product intent

Dirt is **the ride, not the ETA**.

| Profile | Intent |
| --- | --- |
| **Clean** | Pavement first. Every recognized urban core is a wall unless A/B is inside it. Before crossing one, permit rural tagged dirt while keeping every wall intact. Relax a wall only after both searches prove no route exists; never on timeout. Label the fallback. Avoid major highways. Allow forced off. |
| **Direct** | Same dirt fabric as Dirt. Follow the A→B crow-flies line with a narrow corridor and minimal lateral journey. |
| **Balanced** | Dual-sport mix (~50/50 when fabric allows). |
| **Dirt** | Meander on tagged gravel / track / resource toward B. Pavement last resort. Untagged yellow/white OSM roads count as paved. |

The rider judges passability and reroutes. A line on Layers is not a
guarantee the router can use it.

---

## 1. OSM fabric (routing)

Adapter: `scripts/pack-fabric/routing/adapters/osm-roads.js`.

**In (motorized + dual-sport):**

1. Major roads — motorway … unclassified (Carto “major”)
2. City roads — residential / living_street / service
3. Agricultural / forestry — `highway=track`
4. Adventure candidates — `highway=path` and `highway=cycleway`

**Out (always):** `footway` / `pedestrian` / `steps`, `access=no|private`,
abandoned / disused.

**Access class:**

| Way | Default access |
| --- | --- |
| motorway … track, service, residential | `motorized_permissive` |
| path / cycleway with motor tag yes/designated/permissive/destination | `motorized_permissive` |
| path / cycleway otherwise | `motorized_unknown` (Allow-gated) |

**Surface honesty:** explicit OSM `surface` wins. Motorway / trunk / primary /
secondary / tertiary with no `surface` retain the conventional paved default.
Untagged unclassified / residential / service / track / path / cycleway stay
`unknown` in the pack. Their separate road class may guide route selection,
but normalization never invents a known dirt surface. Rider paint treats
unknown conventional road classes as paved so asphalt snippets do not show as
dirt in navigation.

**Access precedence:** `motorcycle` overrides `motor_vehicle`, which overrides
`vehicle`, which overrides `access`. Known private/customers/delivery/forestry/
agricultural/destination restrictions are not through-routing fabric. An OSM
source label never bypasses the packed access class or the Allow Unknown gate.

**Packed road class (Carto → pack):**

| OSM highway | Pack `rt` |
| --- | --- |
| motorway (+link) | freeway / ramp |
| trunk / primary | arterial / ramp |
| secondary | collector / ramp |
| tertiary / unclassified / road | local |
| residential / living_street / service | service |
| track / path / cycleway | track |

Provincial datasets follow **§1a** (identity) and **§1b** (hops). They are
**not** automatically rideable: capillary stays `motorized_unknown` unless a
later, explicit access review says otherwise. Do not stitch unknown at pack
time. Alberta Access Roads already follow this (Allow-gated). BC DRA
`resource` is the test of the same recipe — not a BC-only exception.

---

## 1a. Core vs capillary (church and state)

These two laws are the recipe for every province and state if the BC DRA
`resource` test passes. Source never wins a fight with OSM identity.
Surface costing is a different layer.

### Rule 1 — OSM is the core road stack

OSM is the through-network from motorway down to the smallest OSM road and
track (highway → ATV/path, no footway). If OSM already mapped the line,
**OSM owns it** — including OSM dirt, OSM tracks, OSM gravel.

A provincial overlay (DRA, FTEN, Access Roads, MNRF, NSTDB, …) does **not**
outweigh OSM. Duplicate geometry is dropped. We do not replace an OSM edge
with a provincial centerline, even when the overlay looks “more FSR.”

**Same physical road:** OSM identity. Drop the overlay copy.

**Different physical road** (a forestry spur OSM never drew): overlay may
add it as capillary. Dirt profile may then prefer that spur over OSM
pavement because it is *dirt*, not because it is DRA.

### Rule 2 — OSM is the only hop stack

Province-to-province and state-to-state joins use **OSM edges only**.
Provincial capillary does not exist on the other side of the border.
Seam snaps (12 km today) must not lock onto a BC FSR island that Alberta
cannot continue.

Same-region rides may use capillary. Leaving the region may not.

### How OSM connects to DRA dirt (the join)

Routing OSM → DRA is a **shared node**, not a source takeover.

| Step | Law |
| --- | --- |
| Keep | Overlay `resource` / forestry / FSR (dirt). No highway → ancillary. No paved. |
| Drop | Overlay within **28 m** of OSM (duplicate). Conventional overlay next to **OSM paved** within **90 m** (OSM owns the corridor). |
| Join | Overlay tips that land within **~18 m** of an OSM node **reuse that OSM node**. Grade-gated. No free-space connectors. |
| Island | If it does not meet OSM, it stays an island. Do not invent a forest shortcut. |
| Access | Capillary is `motorized_unknown`. Allow off cannot traverse it. Allow on may. Pack-time stitches stay permissive-OSM-only. |
| Cost | After a shared node exists, profiles cost **surface + class**, not dataset name. |

**Will OSM→DRA routing break?** Only if we skip the shared-node join and
dump islands. Costs cannot hop a gap. Identity must not merge two different
roads into one edge.

**Allow-off honesty:** adding DRA does not raise Allow-off dirt%. That gap
is the legal gate. The BC test’s Allow-on ride is where unique FSR dirt can
show; Allow-off remains OSM permissive dirt.

**Hard bans:** do not default Allow on; do not stitch unknown at pack time;
do not let capillary participate in seams; do not replace OSM with overlay
geometry; do not load overlay highway→local.

### BC DRA `resource` test (2026-08-13) — **not on R2, so not on the phone**

A local experiment packed unpaved DRA `resource` onto OSM BC. That file was
never published. Xcode / PACKS / live routing still use the R2 OSM pack.
**Do not treat this as a tested ride.** Pack changes that should be verified
on device must go to R2.

Measured locally (not device-tested): 655,926 features in; 18,370 dropped as
OSM duplicates; 258 dropped as conventional next to OSM paved. Graph:
1,353,218 nodes, 1,181,019 edges.

| | Edges | km |
| --- | ---: | ---: |
| Both ends on OSM | 13,911 | — |
| One end on OSM | 56,536 | 41,321 joined |
| Island | 554,440 | 272,821 |
| DRA total | 624,887 | 314,142 |

Allow-off Dirt/Balanced on Hope, Merritt, Enderby, Crowsnest **match OSM-only**
(Crowsnest +0.5 km from 535 OSM surface enrichments).

Allow-on: Merritt→Kamloops is the intended ride (Dirt 145 → 170 km, 34% → 66%
dirt, 18 km DRA). Long pairs become dirt tourism — Hope→Princeton Dirt 199 →
1,351 km (138 km DRA). Do not publish until there is a detour budget or a
both-ends-on-OSM filter.

**Third pack (FTEN) is out.** OSM core + DRA `resource` is the BC recipe.
FTEN does not ship. Same later for other provinces: one capillary overlay,
not two.

---

## 2. Secondary layer (Layers)

`NetworkOverlayManager` paints the **installed pack**, not a second CDN.

**Honest Layers:** paint only edges the current Allow setting can route.

- Allow **off** → hide `motorized_unknown` and `motorized_excluded`.
- Allow **on** → purple Access may show.
- Clean forces Allow off, so Clean never paints purple.

Copy: “Shows ~20 km of secondary network the current Allow setting can
route. Purple Access (unknown) hides until Allow unknown is on.”

Lens = one province at a time. Corridor = ~2–3 km of map focus + route
anchors. Do not paint a pretty mesh the router will ignore.

---

## 3. Pack-time stitches (connectivity)

Script: `scripts/pack-fabric/scripts/stitch-adventure-tips.js`.

Near-miss OSM tips are a **graph** problem. Costs cannot join an island.

| Rule | Value |
| --- | --- |
| Join radius | 150 m (`STITCH_JOIN_M`) |
| Tips | degree-1 nodes on permissive `track` / `double_track` / `resource` / `recreation` / `local` |
| Target | nearest through-road node (degree ≥ 2, permissive) |
| Access of new edge | `motorized_permissive` |
| **Never stitch** | `motorized_unknown` / restricted / excluded |
| Geometry | short undirected edge; do not merge nodes |

Run against `graph.v1.json.gz` with `--pack-v2` so `graph.v2.bin` +
`geometry.v1.bin` rewrite. Does not rewrite v1 gzip (re-run is safe).

Runtime soft-stitch in `OnDeviceRouter` (Allow on, non-Clean) may still
bridge unknown islands to the giant — that is the Allow opt-in, not a
pack default.

**Hard ban:** dead-end ↔ dead-end / island ↔ island tip joins.

---

## 4. Profile costs (the dial)

Phone: `Dirt/Routing/OnDevice/OnDeviceProfileCosts.swift`.
Live API: `scripts/pack-fabric/routing/lib/profile-costs.js`.

**Keep them in lockstep.** iOS tables + Dirt unpaved multipliers are SoT.
Tuning a profile never rebuilds packs.

Locked extras on Dirt / Balanced (iOS Dijkstra):

- `passableQualityMult` — prefer gravel/track, tax low-confidence and unknown access
- Untagged freeway/arterial/ramp costs as **paved** (not adventure fuel)
- `pavementLateJoinMult` — mild extra paved tax while far from B (Dirt 0.35, not 2.8)
- `approachAwayExtra` — Dirt: hunt, clamp only in the last ~2.5 km of B;
  Direct: same dirt prices, strong crow-flies so it does not meander.
  Clean: pavement; urban cores are walls unless the pin is there. Rural dirt is
  preferable to an unrelated urban crossing.
  All profiles: freeway/arterial/ramp avoided unless a pin snapped onto that highway.

Measured on local `graph.v2.bin` (Allow off, 2026-08-12):

| Pair | Dirt | Balanced | Direct | Clean |
| --- | ---: | ---: | ---: | ---: |
| Chilliwack→Enderby | 560 km / 47% | 552 km / 47% | 372 km / 27% | 368 km / 0% |
| Chilliwack→Crowsnest (BC hop) | 1319 km / 44% | 1123 km / 36% | 919 km / 14% | 889 km / 0% |
| Crowsnest→Calgary (AB hop) | 767 km / 93% | 747 km / 93% | 252 km / 42% | 215 km / 0% |
| Calgary→Lethbridge | 489 km / 98% | 456 km / 98% | 259 km / 75% | 216 km / 0% |

Hope→Princeton stays ~99% overlap (canyon — no unpaved path). Alberta prairie
is already ~all dirt for both adventure profiles; Dirt meanders longer on the
grid. Long BC eastbound is where Dirt and Balanced actually split.

Do not add a fifth Wander control. Do not add a BC-only cost exception
unless Alberta confirms the prairie needs a different dial — prefer one
national table.

---

## 5. Allow unknown (legal)

Unknown does **not** turn OSM dirt on or off.

| Allow | What the router may use |
| --- | --- |
| **Off** (default) | Proven OSM: motorway → track, plus tagged dual-sport path/cycleway (`motorcycle=yes` / designated / permissive). Dirt profile still taxes pavement hard. |
| **On** | The same, plus **unproven** `motorized_unknown` (purple Access): path/cycleway with no motor tag, provincial capillary (DRA resource, AB Access, …). |

- Clean never opens it.
- Do not stitch `motorized_unknown` at pack time.
- Do not default it on to chase dirt%.
- A blue line on Shortbread is the basemap, not a routing guarantee. OSM `highway=track` is already in the pack with Allow off. OSM `highway=path` without a motor tag is what this toggle opens — and only if it actually joins the graph.

---

## 6. Province packs vs live vs seams

Phone `graph.v2.bin` is the source of truth. Live `/api/route` must fetch **that
same file** from R2 (`/{id}/graph.v2.bin` + `geometry.v1.bin`). Downloaded vs
cellular is only *where* the bytes live — not a different road network.

`longhaul.v1.json.gz` is a thinned highway extract (drops service, keeps FTEN
only near cities). It is **not** the Dirt fabric. Do not route Dirt/Balanced
on it.

| Hop | Engine |
| --- | --- |
| Wi-Fi or cellular available | Live route, fuel, and graph services. Never silently fall back to an installed pack. |
| No Wi-Fi and no cellular; required packs installed | On-device `graph.v2` and installed fuel sidecars, including adjacent-pack seam chaining. |
| Offline and a required pack is missing | Honest unavailable/download-required result; never invent or silently span the missing fabric. |

### Live seams (canada-chain)

Leftover live `routing/regional/merge.js` lives in this repo at `scripts/pack-fabric/routing/regional/merge.js`. One hop per adjacent region pair.

**Long borders** (AB–BC, SK–AB, 49th parallel, US states): the seam is where
**this** A→B line crosses the two region families, then snaps onto the **phone
pack** fabric. The crossing point is just a hop join — not a scenic funnel.

**Bottleneck links only** (the only legal road, not a scenic funnel):

| Link | Why it is a door |
| --- | --- |
| NS–NB Tantramar | Isthmus — chord can miss it through the Bay of Fundy |
| NB–PE Confederation Bridge | Only road onto the island |
| NB–QC Dégelis | Only Canada land link (Maine is not on the chain) |

**Rider choice:** Plan mode via-pins (3+ points) skip engineered seams and
are the way to force a specific crossing.

Canada–Canada adjacency stays explicit (rectangles lie). US–US and
Canada–US adjacency is bbox-touch so we do not maintain a 50-state pass list.

Pack-time stitches live in `graph.v2.bin`. Live must use that file so stitches
are on the ride, not only on the phone.

### On-device cross-province

When both adjacent packs are installed, the phone hops pack-to-pack. Each hop
uses that province’s `graph.v2.bin` (stitches, Dirt costs, Allow). The seam is
the A→B chord crossing plus a few border-line retries; each side snaps onto
**OSM core edges in its own pack** — not DRA / FTEN / Access / MNRF
capillary (§1a Rule 2). If the join fails, tell the rider to drop a via —
do **not** send the ride to `longhaul.v1.json.gz`.

If a pack is missing, live is missing-pack only.

---

## 7. Publish discipline — live and PACKS are one ship

There is **one** file per region: R2 `dirt-packs/{id}/graph.v2.bin` +
`geometry.v1.bin`. PACKS downloads it. Live `/api/route` loads it. Cellular
vs downloaded is delivery, not a second network.

A fabric or cost change that is only on the phone, or only on live, is
**not shipped.** Use `scripts/pack-fabric/scripts/ship-routing.js`.

1. Never overwrite R2 `manifest.json` with a single-region-only file — **merge**.
2. Upload `graph.v2.bin` + `geometry.v1.bin` **before** the merged manifest.
   That object is what the phone downloads **and** what live `/api/route` loads.
   There is no second live pack. Rebuild + publish once.
3. Phone skips files that already exist — testers **Remove** then **Download**.
4. Nova Scotia is **frozen** this pass (already good). Do not stitch/republish NS
   unless a seam bug requires it.
5. Cost tables: `OnDeviceProfileCosts.swift` + `scripts/pack-fabric/routing/lib/profile-costs.js`. Deploy live with `ship-routing.js --live`.
6. Deploy `/api/route` from `scripts/pack-fabric/` only. `longhaul.v1.json.gz` is not a routing graph.
7. After ship: `node scripts/pack-fabric/scripts/ship-routing.js --assert`
   (fails if production `schemaVersion` is still `longhaul-region-1`).

---

## 8. Rollout

| Order | Region | Status |
| --- | --- | --- |
| 0 | Nova Scotia | **Skip** — leave as-is |
| 1 | British Columbia | **Done** 2026-08-12 — OSM-only + 24,427 stitches + honest Layers |
| 2 | **Alberta** | **Stitched 2026-08-12** — 21,387 joins (694,894 → 716,281). Confirm prairie vs Rockies-west before rolling east. |
| 3 | SK, MB, ON, QC, NB, PE, NL, territories | Packs **on R2**. Stitch recipe after AB confirms |
| 4 | US states | Packs **on R2** (manifest 2026-08-12). Same OSM + stitch laws when rebuilt |

Per-region recipe (after AB confirms):

```bash
cd scripts/pack-fabric
NODE_OPTIONS=--max-old-space-size=8192 \
  node scripts/stitch-adventure-tips.js --pack-v2 routing/data/regions/<id>/graph.v1.json.gz
# merge-publish <id> to R2 (see §7)
```

Do not OSM-only-rebuild a province that still needs its provincial capillary
reviewed. Stitch permissive OSM tips on the pack you have; keep unknown gated.

---

## 9. Field checks

### Same-province (pack SoT)

1. Remove + Download the province pack.
2. Dirt, **Allow off**.
3. Layers on: no purple.
4. Record km, dirt%, paved%, unknown% (should be ~0 unknown).
5. Same A→B with Allow **on** — dirt% may rise; that is purple, not a bug.

**BC:** Chilliwack → Enderby (mountain corridor; Allow-off ~37% is accepted).

**AB (confirm):**

| Hop | Why |
| --- | --- |
| Calgary → Edmonton | Prairie grid, little mountain excuse |
| Calgary → Drumheller | Mixed prairie / badlands |
| Canmore / Banff → Jasper | Rockies-on-the-west only |
| Grande Prairie → Peace River | Northern resource / white rural |

Expect Allow-off dirt% **higher** than BC 37% on prairie hops if OSM
connects. If Calgary→Edmonton still hugs the QE2 with Allow off, stitches
didn’t land or the pack wasn’t re-downloaded.

### Cross-province (on-device if both packs installed; else live phone pack)

| Hop | Why |
| --- | --- |
| Golden BC → Banff / Edmonton | Northern chord hops further north than White Rock→Lethbridge |
| White Rock BC → Lethbridge AB | Southern chord, not a 200 km detour to Lake Louise |
| Vancouver BC → Seattle WA | 49th parallel, not an AB pass |
| Seattle WA → Portland OR | Columbia band, not a named pass |
| Drop a via on Hwy 3 | Forces Crowsnest; 3+ pins skip engineered seams |
| Lloydminster area SK/AB | Prairie seam, not mountains |
| Waterton / Chief Mountain | 49th parallel (AB–MT) |

Profile debug: `CrossProvinceRouteDebug` (White Rock → Lethbridge) is for
seam/chain bugs. Live must load R2 `graph.v2.bin`, not `longhaul.v1.json.gz`.

---

## 10. Agent rules (do not regress)

1. Do not default Allow unknown on.
2. Do not stitch `motorized_unknown`.
3. Do not restore Wander.
4. Do not retune costs to chase Allow-on dirt% with Allow off.
5. Do not paint Layers the router cannot use.
6. Do not invent asphalt on untagged secondary/tertiary/unclassified.
7. Do not publish a one-region manifest.
8. Do not OSM-include `footway` / pedestrian / steps.
9. Same-province installed pack is SoT — no silent live fallback, no silent Allow.
10. After a pack publish, testers must Remove + Download.

---

## Key files

| File | Role |
| --- | --- |
| `scripts/pack-fabric/routing/adapters/osm-roads.js` | OSM include / access / surface |
| `scripts/pack-fabric/scripts/stitch-adventure-tips.js` | Pack-time permissive tip joins |
| `scripts/pack-fabric/routing/lib/profile-costs.js` | Cost tables (this repo; `--live` deploys them) |
| `scripts/pack-fabric/routing/regional/merge.js` | Live canada-chain |
| `Dirt/Routing/OnDevice/OnDeviceProfileCosts.swift` | Phone cost tables (SoT) |
| `Dirt/Routing/OnDevice/OnDeviceRouter.swift` | Dijkstra + runtime Allow stitch |
| `Dirt/Map/NetworkOverlayManager.swift` | Honest Layers |
| `Dirt/Features/Layers/LayersSheet.swift` | Lens copy |
| `Dirt/Features/RoutePlanning/RoutePlannerModel.swift` | Pack SoT vs live vs cross-province |
