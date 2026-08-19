# DIRT iOS — Changelog

Living log for agent handoffs. Prefer this over chat archaeology.

**Last updated:** 2026-08-19

---

## 2026-08-19 — Itinerary routing rebuild (in progress, BC validation)

Branch `feature/routing-itinerary-rebuild`. Restore point: `ef0b812` on `rescue/2026-08-19`.

The product of a fuel-on plan is a hop chain **A → F₁ → … → B**, built from graph reach + progress toward B — not one Dijkstra then pumps on that line. Each hop is its own constrained search.

Hard constraints on Dirt / Balanced / Direct: metro-core **wall** (Vancouver is metro-wide, not downtown-tiny), no backtracking the edge just ridden. Clean is exempt from the wall.

Per-profile search is now a real target: Dirt keeps weight-table adventure inside a **50 km** A→B corridor; Direct is min-pavement inside a **15 km** corridor (stretch-factor superseded — trail networks are a physical size, not a % of trip length); Balanced is resource-constrained 45–55% dirt with a **40 km** safety ceiling only. Session seed picks among near-equal corridors.

Phone and live share the same constraints (`UrbanCore.swift` / `hop-search.js`). Pack binaries unchanged; ship `--live` for search code.

---

## 2026-08-19 — Corridor width replaces Direct/Dirt stretch-factor

Direct 15 km / Dirt 50 km / Balanced 40 km (safety ceiling) hard cross-track bands from the hop A→B great circle. Clean unconstrained. Nodes outside the band are ineligible, not taxed. Balanced 45–55% ratio still does the shaping; if the 40 km ceiling binds often, the ratio search needs attention.

---

## 2026-08-19 — One workspace; Vercel is API-only

Develop only in `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt` (`rescue/2026-08-19`). Packs + live API are `scripts/pack-fabric/` (adapters, schema, conflation, `api/route`, ship scripts). Packs stay on R2. Production `api/route` must not bundle graphs.

---

## 2026-08-13 — Allow unknown is unproven paths, not OSM dirt

Allow off already uses OSM track / gravel / resource. The toggle only opens `motorized_unknown` (path with no motor tag, provincial capillary). UI footnote and onboarding said “access roads” — that read as if OSM dirt was gated. Copy now matches the law.

---

## 2026-08-13 — Live and PACKS ship together

One R2 object (`{id}/graph.v2.bin`) is live `/api/route` **and** PACKS download. Cost tables copy to Mayday and deploy with the pack, not after. Door: `scripts/pack-fabric/scripts/ship-routing.js`. Assert fails if production is still the longhaul extract.

---

## 2026-08-13 — Live production actually loads the phone pack

Abbotsford→Merritt Dirt Allow-off showed **15% dirt / 331 km** because production `/api/route` was still on `longhaul.v1.json.gz` (`graphMode: longhaul-local`, 244k edges). The Aug 12 “live uses phone pack” note was written locally and never deployed.

Production now loads R2 `bc/graph.v2.bin` (556,132 edges). Same pins, Dirt, Allow off: **285 km · 45% dirt / 55% paved**, `unknownAccessPercent: 0`. Re-run From here — no pack download, no iOS rebuild.

Mayday `origin/main` now loads R2 `graph.v2.bin` (PR #7). Door for the next change: `scripts/pack-fabric/scripts/ship-routing.js`.

---

## 2026-08-13 — Dirt meanders; FTEN stays off

- Dirt vs Balanced were collapsing onto the same ~50/50 mix because untagged yellow/white OSM roads cost as adventure then painted paved.
- Dirt now costs those classes as paved (match paint), taxes collector, and discounts tagged track/resource harder so it collects trails along a dirt road. Balanced stays the dual-sport mix.
- BC recipe is OSM core + DRA `resource` only. No FTEN pack.

---

## 2026-08-13 — Packs are opt-in; live while online

- Planning never auto-downloads a routing pack. Published region + no pack on phone → live `/api/route`.
- Successful live routes no longer toast “Grab it from PACKS.” PACKS is opt-in for no-signal rides.
- Start Nav activates an installed pack; if none, skip (download from PACKS for no-signal detours).
- Auto-download next region defaults **off** (new pref key so old `true` does not stick).

---

## 2026-08-13 — OSM core vs provincial capillary (laws)

- OSM is the core stack motorway → smallest OSM road/track. Overlay dirt does **not** outweigh OSM identity; duplicates drop.
- Inter-region hops are OSM-only. Capillary (DRA resource; later Access / MNRF — not FTEN) is same-region only, joined at shared OSM nodes (~18 m), never free-space, stays `motorized_unknown`.
- BC DRA `resource` local test (not on R2): 314k km packed, **13% joins OSM** (41k km), 87% islands. Allow-off routes match OSM-only. Allow-on Dirt tours the forest on long pairs (Hope→Princeton 199 → 1,351 km). Merritt→Kamloops is the sane Allow-on ride (+18 km DRA, 34% → 66% dirt).
- Nova Scotia frozen.

---

## 2026-08-13 — BC back to OSM highway class; R2 is live+download

- Parked BC network lens + BC OSM hierarchy overlay (commented, not deleted). Shortbread OSM (motorway → track/path) is the visual.
- Nav paint: untagged OSM *road* classes (freeway…local/service) show as paved, not dirt. Track/resource stay dirt.
- Routing a published region that **isn’t downloaded** uses live `/api/route`. R2 `graph.v2.bin` is what PACKS installs for offline. Vercel longhaul is not used when the region pack exists on R2.

---

## 2026-08-12 — Dirt ≠ Balanced; BC–AB chain stays on-device

- Root cause: Dirt’s 36× paved tax + late-join 2.8 refused short paved connectors onto FSRs, so Dirt collapsed onto Balanced (or worse, Merritt). Direct’s 4.4× freeway made Direct take Dirt’s mixed corridor.
- Costs: Dirt paved 12×, late-join 0.35, away-horizon last 12 km; Direct highway near Clean; untagged highway costs as paved.
- Measured: Chilliwack→Crowsnest Dirt 44% vs Balanced 36% (23% overlap). Alberta prairie already ~93–98% dirt for both adventure profiles.
- Two downloaded packs chain on-device (dual snap + border retries). **No live longhaul fallback** — that was the black paved line through BC.

---

## 2026-08-12 — Live uses the phone pack (not longhaul extract)

Western BC → Calgary was pavement because live fetched `longhaul.v1.json.gz` (service dropped, FTEN only near cities) while PACKS downloads `graph.v2.bin`. Same R2 bucket, different file. Production aliased 2026-08-13.

---

## 2026-08-12 — Map refinement locked + Alberta stitches

- Laws: [docs/08-MAP-REFINEMENT.md](./08-MAP-REFINEMENT.md) — OSM include, honest Layers, pack stitches, costs, Allow, seams.
- Verdict: Chilliwack→Enderby **37% Allow-off vs 67% Allow-on** is the legal gate, not a cost miss. Do not chase 67% with Allow off.
- Live + pack-fabric `profile-costs.js` lockstepped to iOS Dirt tables (paved tax 36×).
- Alberta pack stitched: **21,387** permissive tips, 694,894 → **716,281** edges. Access Roads stay `motorized_unknown` (not stitched).
- Nova Scotia frozen. Cross-province still live canada-chain until on-device multi-pack.

---

## 2026-08-12 — A+C: pack-time stitches + honest Layers

- **A — Pack stitches:** `scripts/pack-fabric/scripts/stitch-adventure-tips.js` joins permissive track/resource/local **tips** to the nearest through-road node within 150 m. Does **not** stitch `motorized_unknown`. BC: **24,427** stitches, 531,705 → **556,132** edges. Published to R2 `dirt-packs/bc/` (manifest merged, 63 regions).
- **C — Honest Layers:** overlay omits `motorized_unknown` / `motorized_excluded` when Allow is off (`NetworkOverlayManager` + `MapState.networkAllowUnknown`).
- Allow Unknown stays **off** by default. Reload BC: PACKS → Remove British Columbia → Download.

---

## 2026-08-12 — Audit: web-eradication over-rotation

Besides deleting live routing, that pass also:
- Gutted Profile `CrossProvinceRouteDebug` into a packs-only stub (**restored** — hits live `/api/route` again).
- Rewrote docs (`00`, `01`, `02`, TestFlight, OnDevice README) as packs-only (**corrected**).

**Not over-rotations (kept):** motorcycle fuel filter + Overpass POIs (intentional rebuild); baked Supabase config; comment scrub of “web POC” wording; LegalLinks on dirtmoto.app.

---

- Restored `RoutingClient` + `/api/route` for planning when a pin’s province/state pack isn’t on the phone.
- Pack download is required only when offline. Online Oregon / Washington / etc. must not demand PACKS.
- Soft toast after live success used to tip “grab for offline” — **removed 2026-08-13**. Live success is just the route.
- Corrects the earlier “iOS stands alone / packs only” cut that produced “Oregon isn’t on this phone” with 5G.

---

## 2026-08-12 — Canada↔US live API (R2 packs)

- Mayday `/api/route` loads US longhaul from **R2** (not Vercel static). BC→WA / in-Oregon live works without a phone pack.
- `GraphPackStore` 49th-parallel primary (BC/WA, AB/MT, …).

---

## 2026-08-11 — Cut the old map client. iOS stands alone.

- **Superseded 2026-08-12:** live `/api/route` is back for regions without a downloaded pack.
- POIs from OSM Overpass + motorcycle fuel filter. Network overlay paints the installed pack.
- Sprites bundled. Supabase key baked. dirtmoto.app stays for marketing/legal only.

---
## 2026-08-11 — BC Dirt profile + DRA/FTEN fabric (parity)

### BC Dirt profile costs (on-device)
- `OnDeviceProfileCosts`: BC + Dirt only — deeper unpaved discount (`BC_DIRT_UNPAVED_MULT` parity) and wider near-B horizon `max(9 km, 0.5× AB)`.
- Soft length guardrail documented as server ellipse ≈ 2× crow-flies for BC Dirt; other provinces unchanged.
- Clean still never opens `motorized_unknown`.

### BC pack fabric (docs)
- Phone pack BC is **OSM + DRA + FTEN** (was wrongly documented as OSM+FTEN-only / DRA-only in places).
- Live R2 pack rebuilt 2026-08-11: **832,570** edges (was 660,542; +172k FTEN after conflation).
- `GraphPackStore` BC subtitle updated. `docs/SOON-PHONE-PACKS-AND-OVERLAYS.md` corrected.
- Display gov overlay (`bc-gov-*`) remains separate from routing fabric.

### BC OSM hierarchy overlay (display-only)
- `MBTilesVectorProxy`: tippecanoe gzip tiles now served with `Content-Encoding: gzip`.
- Bundled `Dirt/Resources/BC.mbtiles` for device runs from Xcode.

---
