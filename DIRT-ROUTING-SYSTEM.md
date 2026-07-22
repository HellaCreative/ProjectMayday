# How the routing system works

Living product doc. Companion: [DIRT-MAP-A-PROVINCE.md](./DIRT-MAP-A-PROVINCE.md).  
Updated: 2026-07-22.

## What DIRT is (and isn’t)

DIRT is **not Google Maps** — except **Clean**.

Adventure profiles (Direct / Balanced / Dirt) run on the offline dirt fabric: OSM white roads + purple provincial capillary ([fabric model](./DIRT-MAP-A-PROVINCE.md)). Clean is the pavement/highway product: fast, mostly paved, Google-shaped.

Engine today: Node A* / Dijkstra on prebuilt regional packs via `POST /api/route`. Cost tables live in `routing/lib/profile-costs.js` — tuning profiles does **not** rebuild packs.

---

## Allow unknown = product law

| Control | Meaning |
| --- | --- |
| **Allow off** | Only `motorized_permissive` (and verified). White OSM fabric. Purple capillary is invisible to the search. |
| **Allow on** | Opens `motorized_unknown` capillary (NSTDB TRACK, forest/resource supplements). Soft-stitch may bridge near-touch islands. |

### Clean is immune to Allow

**Product law:** Clean never uses purple / unknown capillary — even if the Allow toggle is on in the UI.

- Soft-stitch must not run for Clean.
- Clean must not prefer or advertise unknown-access meters.
- If code still lets Allow expand Clean’s eligible edge set, **that is a bug against product law** — document the law here; fix the engine separately.

Adventure profiles + Allow on = open capillary. Clean + Allow on = still Clean.

---

## Profile law

UI names ↔ engine ids: Cleanest → `cleanest`, Direct → `direct`, Balanced → `balanced`, Dirt → `dirt`.

| Profile | Law | Dirt / paved intent | Purple (Allow on) |
| --- | --- | --- | --- |
| **Cleanest** | Google-fast pavement/highway. Dirt only as a last stitch when forced. | ~100% paved when topology allows | **Never** — immune to Allow |
| **Direct** | Crow-flies cut on the **dirt fabric**. **Minimize path length first**; mild dirt preference only among near-equal options. **No dirt-tourism spur** near B — once on the paved approach, go straight to destination. Not a max-dirt objective. | Dirt-biased corridor, short | More purple when Allow on (without lengthening) |
| **Balanced** | Dual-sport mix. Not Direct, not Dirt-max. **When Allow on and fabric allows, journey mix is forced toward ~50/50 paved/dirt** (soft band ~40–60% dirt; harness 25–70). Costing applies a Balanced-only paved mix pull so purple capillary cannot own the corridor. | ~50/50 dirt/paved target | Some purple when useful — not Direct’s purple max cut |
| **Dirt** | Maximize dirt / minimize pavement. Longer OK. Still avoid pointless destination loops that don’t add net dirt corridor. | As close to 100% dirt as topology allows | Heavy purple when Allow on |

**Direct ≠ Dirt.** Direct is the short dirt cut; Dirt is the long dirt max. If they look the same in the field, costing is broken — not the law.

### Adventure avoids major cities (unless staged)

**Product law:** Direct / Balanced / Dirt must **not** beeline through major urban cores (Halifax, Moncton, Fredericton, Edmundston, Québec, Montreal, …) just because longhaul pack stitching used those cities as chain hubs.

- **Cleanest** may use highway city/spine corridors (Google-fast A→B).
- **Adventure** connects packs along the A→B chord / border geometry — no injected city waypoints. If the rider stages through a city explicitly, that pin is honored.
- Engine: `corridorLocationsForRoute(..., { profile })` in `routing/regional/merge.js`.

---

## dirt% / paved% = map paint

Route stats use the **same adventure surface set the map paints** (blue/gray/purple vs slate pavement):

- **dirt%** ≈ gravel + access/resource + track (+ unknown surface, etc.)
- **paved%** ≈ paved only

Access (`motorized_unknown` %) is a separate honesty signal — “how much of this ride is Allow-gated capillary,” not a surface color.

If paint and percentages disagree, fix the aggregator — don’t invent a second vocabulary.

---

## Costing / ellipse / snap / soft-stitch (conceptual)

**Costing** — each edge pays distance × surface weight × road-class weight. Clean prefers major paved progress (arterial/collector/local OK) toward the destination — not freeway-only backtracks. Adventure profiles punish highway spine so the engine can’t “stay on 102 and nibble dirt exits.” Allow on adds a pull onto unknown / NSTDB for non-Clean only. **Balanced+Allow** adds an extra paved↔dirt mix pull so dirt% lands near ~50/50 when fabric can deliver both — not Direct’s crow-flies purple cut, not Dirt-max.

**Ellipse** — search stays inside a corridor around A→B (tighter for Clean/Direct/Balanced, wider for Dirt). Escalates if no path. Dirt ellipse may stay off by default so Dirt can wander farther. Balanced shares Direct’s tight band so Myra-style north tourism spurs stay out; mix divergence comes from costing, not a wider ellipse.

**Snap** — pins match nearby eligible edges. Clean prefers paved; adventure prefers dirt/track/access. Full packs bias toward the giant component so you don’t start stuck on a purple island with no way home (unless Allow + soft-stitch connects you).

**Soft-stitch** — route-time only, Allow on, non-Clean: short real-meter virtual legs between near-touch components so capillary can form a through cut. Not packed into the graph. Not free teleports. See [fabric doc](./DIRT-MAP-A-PROVINCE.md).

Weights change; law doesn’t. Don’t dump every multiplier into product docs — read `profile-costs.js` when tuning.

---

## Broken today vs intended (current gaps)

Honest gaps as of this writing:

1. **Profiles too similar** — mostly addressed on NS gold (Myra + New Glasgow→Yarmouth): Direct crow-flies dirt cut, Balanced ~50/50 when Allow on, Dirt dirt-max, Clean paved. Re-check after weight churn.
2. **Clean + Allow** — product law = immune; **implemented** in `normalizePolicy` (engine forces `motorizedUnknown` off for `cleanest`). Soft-stitch / adventure snap / Allow cost pull already skip Clean.
3. **Allow off vs on** — with Allow on, adventure should clearly take more purple; with Allow off, dirt% should come from OSM gravel/track only. If Allow doesn’t move the needle, capillary isn’t in the searchable path (pack, longhaul omit, or stitch).
4. **Longhaul vs full pack** — Vercel NS keeps NSTDB; NB longhaul drops provincial. Riders testing “Allow on” across provinces may see different purple availability — call it out, don’t gaslight.
5. **NRN still in non-NS packs** — adventure costing comments still mention “prefer capillary over paved NRN”; NS gold has no NRN. Fabric graduation is unfinished ([map a province](./DIRT-MAP-A-PROVINCE.md)).

Fixtures exist (Porters balanced, HFX–Yarmouth cleanest, etc.) — they prove completeness more than profile law. Myra profile matrix: `scripts/smoke-myra-profiles.js`.

---

## Later (not now)

Do not build these until profile law + fabric gold are boringly true:

- **Corridor alternates** — east / west / middle when geography forks. Intentional alternatives, not random “another route.”
- **Fuel range / stage length to gas POIs** — stage planning against real reach.
- **Time budget** — “home by dark” as a constraint, not a label.

**Curviness** is not the headline. Roadbook curves exist; **dirt%** is DIRT’s equivalent focus for route quality.

---

## Acceptance harness (idea)

Fixed **Myra A→B** (and a tiny set of cousins) asserts per profile:

| Assert | Clean | Direct | Balanced | Dirt |
| --- | --- | --- | --- | --- |
| Completes | ✓ | ✓ | ✓ | ✓ |
| paved% band | very high | low–mid | mid | very low |
| dirt% band | ~0 / last stitch | high for length | mid | max |
| unknown-access m (Allow off) | 0 | 0 | 0 | 0 |
| unknown-access m (Allow on) | **0 (law)** | up | some | up |
| length vs Direct | — | shortest adventure | ≥ Direct | ≥ Balanced usually |

Fail the harness → fix costing or access policy, don’t redefine the profile names.

Wire as fixtures beside `routing/test/run-fixtures.js` when ready — product owns the bands; engineering owns the runner.

---

## Insights / next direction

- **Lock Clean⊥Allow in code to match this law** — highest trust bug if Clean still touches purple.
- **Ship a Myra profile matrix harness** before more weight-table churn — numbers beat vibes.
- **Separate Direct vs Dirt on one corridor** — if dirt% and length don’t diverge, costing failed the law table.
- **Fabric and routing docs stay paired** — province onboard without profile law ships purple nobody uses; profiles without capillary ship Google with lipstick.
- **Longhaul purple policy is a product decision** — document per province what Allow can reach on production.
- **Curviness / alternates / fuel wait** — earn them after dirt% separation is obvious on NS gold.
