# DIRT — HTML → iOS functional continuity

Living backlog so chat decisions don’t get lost. **UI chrome is out of scope** — iOS keeps its refined UI; this list is **functionality and logic** parity with the HTML POC (`Mayday/app/index.html`).

Last updated: 2026-07-27 (straight-cut / triangle route fix — denser longhaul geom + proximity prune)

---

## Priority order (agreed)

1. **A — Groups map** — named pins + tap → route to rider  
2. **B — Planner pins** — teardrop markers, drag-to-move, road snap  
3. **C — Route geometry / off-route** — no false straight shortcuts; investigate client + `/api/route`  
4. **Basemaps** — high-contrast Shortbread + satellite (Esri World Imagery; no Mapbox)  
5. **Remaining list** below  

**Deferred (accepted for now, still required for product success):** offline basemap/tile packs (hard-disabled after crashes). Revisit after A–C + layers.

---

## Decisions locked

| Topic | Decision |
| --- | --- |
| Apple Sign-In | Working via Supabase Client ID `com.mayday.dirt` |
| Tester unlock | Keep until store freeze; then `BuildChannel.allowPreReleaseTesterUnlock = false` |
| Mapbox basemaps | **Remove** — no Mapbox billing |
| High-contrast map | Enrich OSM Shortbread paints (water / vegetation / land) for sunlight |
| Satellite | **Esri World Imagery** (OSM does not ship true satellite; OSM remains the vector/routing base) |
| Groups Realtime | Polling first; Realtime channel after pin + tap-to-route works |
| Offline packs | Deferred; necessity acknowledged |

---

## A — Groups (done for TestFlight retest)

| HTML | iOS target | Status |
| --- | --- | --- |
| Named rider pin + status color/label | Full name + status chip; status-colored dot | Done |
| Tap pin → route to member | `MapState.onRiderTap` → `planner.routeToMember` | Done |
| Pins stay while group is active (not only sheet open) | Keep map presence after sheet close | Done |
| Live share + roster | Exists (poll 10s / upsert 5s) | Done |
| Sheet Route / focus | Exists | Done |
| Distress `rider_alerts` | Port later | Backlog |
| Supabase Realtime channel | After A basics | Backlog |

---

## B — Route planning pins

| HTML | iOS target | Status |
| --- | --- | --- |
| Numbered teardrop stage markers | Replace circular poke pins | Done |
| Select → drag → re-snap → re-route | Annotation drag | Done |
| Client road snap ~500 m (zoom-independent) | Drag snaps to active route polyline ≤500 m; fresh place uses raw coords until route returns (MapLibre Native can’t query vector road hits like HTML). Server still snaps on `/api/route`. | Partial |
| Delete stage / waypoint | Parity with stage delete | Todo |
| Long-press place in Plan | Exists | Done |
| Multi-stage + per-stage profile | Exists | Done |

---

## C — Geometry & off-route

| Issue | Approach | Status |
| --- | --- | --- |
| Pins snap after route | Pins snap to geometry endpoints after route (`applyRoutedBoundary`) | Done |
| False “off route” while on road | Was `nearestVertex` mid-curve false positives → `nearestProjection` onto segment; threshold **50 m** (HTML parity) | Done |
| Straight-cut / triangle routes (Meaghers Grant) | **Two causes on Vercel longhaul packs:** (1) shape thinning capped every edge at **6 points**, so gentle curves painted as chords through terrain; (2) dual-fabric out-and-backs missed by exact-coordinate loop prune. **Fix:** spacing-based thin (~35 m, max 80 pts) in `build-longhaul-region-packs.js` + proximity-cell loop prune (~20 m / 25 m match) in `path-pruning.js`. Rebuild all `longhaul.v1.json.gz` packs. Needs **Mayday API redeploy** (packs + pruning code). | Done (needs deploy) |
| Tendril / house-loop detours (all profiles) | Geographic loop pruning runs for all profiles after path search. Proximity matching above also covers near-miss dual-fabric loops. | Done (needs deploy) |

---

## Basemaps & layers

| Item | Status |
| --- | --- |
| High-contrast Shortbread variant | Done — `tuneShortbreadContrast()` baked into `shortbread-style.json` (57 layers) |
| Esri satellite basemap option | Done — `esriSatellite` via ArcGIS Online raster tiles; no token |
| Remove Mapbox Outdoors/Streets/Satellite + token UI | Done — `MapStyleCatalog` + `LayersSheet` cleaned up |
| Rider Services POIs on map (fuel/camp/lodging/liquor) | **Done** — colored discs + category icons (pump/tent/bed/glass); nearby OSM duplicates collapsed (campgrounds ~450 m) |
| POI tap → route to / use as waypoint | **Done** — larger hit target; POI tap beats pin drop (tap + long-press) |
| Province network overlays NS/NB/QC actually drawn | **Done** — `NetworkOverlayManager` + 6 MapLibre line layers |
| Layers toggles wire to overlay paint | **Done** — surface/access/bridge/tunnel/restricted toggle `isVisible` |
| Layers prefs only (old state) | Resolved |

### Overlay architecture (summary)

| | Web POC | iOS |
|---|---|---|
| POI data source | `fetch /app/data/poi/chunks/{id}.json.gz` | Same Vercel CDN; `POIManager` |
| POI layer | MapLibre cluster + circle + symbol | 4 `MLNCircleStyleLayer` (no cluster, simpler) |
| Network data | `fetch /app/data/{ns,nb,qc}-gov-chunks/{id}.geojson.gz` | Same CDN; `NetworkOverlayManager` |
| Network layers | `ns-gov-access/gravel/track/restricted/bridge/tunnel` | `dirt-net-access/gravel/track/restricted/bridge/tunnel` |
| Surface toggle | `applyLayerVisibility()` → layer visibility | `MLNStyleLayer.isVisible` via `applyNetworkLayerVisibility` |
| Province toggle | `networkOverlayProvince` / `showAllNetworkData` | `showNSLines/showNBLines/showQCLines` → which provinces load |
| POI tap → route | `usePoiAsWaypoint()` | `confirmationDialog` → `planner.routeToCoordinate` |
| Min zoom | POI 8.5; network 12.5 (corridor) | POI 8.5; network 10.0 |
| Chunk cap | POI 14; network 6 (corridor) | POI 14; network 3 per province |
| Feature cap | web: CONTEXT_MAX_FEATURES=1600 | network: 2000 combined |

---

## Other continuity

| Item | Status |
| --- | --- |
| GPX export | Done |
| GPX import | Done |
| Local incident report + avoid-edge recovery | Done |
| Shared cloud incidents / `rider_alerts` | Todo |
| Nav HUD / cues / speech / surface look-ahead | **Needs work** — see **D** below |
| Offline tile prefetch | Deferred |
| Saved routes | Done |

---

## D — Active navigation (field feedback 2026-07-26)

Priority after A–C. Dual-sport: cues happen fast; phone screen is small.

| Item | HTML / expected | iOS today | Status |
| --- | --- | --- | --- |
| Closer nav zoom | Street-level framing while following | Detail follow zoom **16.5** | Done |
| Recenter = lock follow | Rider stays centered; map moves under puck | `followGeneration` re-applies `followWithCourse` + zoom | Done |
| No waypoints while navigating | Placement disabled once nav starts | Tap/long-press/drag blocked while `phase != idle` | Done |
| Picture-in-picture | Mini map: full-route overview; tap swaps overview ↔ detail | `NavigationPipView` | Done |
| Travel time countdown | Remaining ETA → 0 at destination; multi-stage per stage | Countdown via live/planning speed; stage label when multi-leg | Done |
| Location puck in nav | Course **arrow** in direction of travel | `DirtCoursePuckView` + `followWithCourse` | Done |
| Cue audio | Speaks turn callouts (AVAudioSession + bands) | Playback session + distance bands | Done |
| Rally callouts | Spoken/shown **"Right 6"**, **"Left 4"** (severity 6→1) | `displayLabel` / `spokenLabel` | Done |
| Junction callouts | **"Turn left" / "Turn right"**; **90°** arrow | Junction labels + `arrow.turn.up.*` | Done |
| Rally arrow severity | Varying bend angle by number | Severity-mapped SF Symbols | Done |

### D acceptance checks

- [ ] Start nav → zoom tight (~16–17); rider stays centered while moving  
- [ ] Pan away → Recenter re-locks course-up follow at tight zoom  
- [ ] During nav, tap/long-press does **not** drop waypoints  
- [ ] PiP shows full route; tap swaps main ↔ overview  
- [ ] Travel time counts **down**; hits 0:00 at destination (stage label when multi-stage)  
- [ ] Puck is a course arrow while navigating  
- [ ] Rally mode audio: “Right 6” / “Left 4”; Junction: “Turn left/right”  
- [ ] Cue card arrows: junction ≈ 90°; rally severity varies  

---

## Test checklist (when A–C + basemaps land)

- [ ] Two TestFlight users in same group, both sharing → each sees the other’s **named** pin  
- [ ] Tap peer pin → route calculates From here → peer  
- [ ] Plan route: teardrop numbered pins; drag pin; snaps to road when zoomed out  
- [ ] Ride curved roads → polyline follows road; no spurious off-route  
- [ ] Layers: Shortbread rich + Esri satellite; no Mapbox options in picker  
- [ ] Rider Services toggles show POIs (zoom ≥8.5, toggle on, network required for first load)
- [ ] Tap a fuel/camp/lodging/liquor dot → action sheet shows "Route to this" → route calculates
- [ ] Plan mode POI tap → "Add as waypoint" option visible
- [ ] Province NS/NB/QC toggle on at zoom ≥10 → network lines appear in correct colors
- [ ] Access/gravel/branches/bridge/tunnel/restricted toggles hide/show respective layers  

---

## Source references

- HTML: `Mayday/app/index.html` (groups markers ~9835+, stage markers ~12558+, snap ~13376+)  
- iOS docs: `03-GROUPS.md`, `02-ROUTING.md`, `05-MAPS.md`  
- iOS code: `GroupsViewModel`, `MapLibreMapView`, `RoutePlannerModel`, `MapStyleCatalog`
