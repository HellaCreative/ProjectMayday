# DIRT iOS — Maps

MapLibre Native integration, route paint, markers, location, and offline tile session rules. Spec: [WEB-SPEC-FOR-IOS.md](./WEB-SPEC-FOR-IOS.md) §6.

---

## Key files

| File | Role |
| --- | --- |
| `Dirt/Map/MapLibreMapView.swift` | `UIViewRepresentable` + style layers + gestures |
| `Dirt/Map/MapState.swift` | Observable map model (route, markers, camera, style, overlays) |
| `Dirt/Map/MapStyleCatalog.swift` | Basemap IDs, style URL writer |
| `Dirt/Map/OfflineTileManager.swift` | Offline pack prefetch (active basemap) |
| `Dirt/Map/POIManager.swift` | Rider Services POI chunk loader (Vercel CDN → MapState) |
| `Dirt/Map/NetworkOverlayManager.swift` | Province network overlay chunk loader (NS/NB/QC → MapState) |
| `Dirt/Map/GeoJSON+Utils.swift` | `Data.gunzipped()` gzip decompression; `LayerPrefsSnapshot` |
| `Dirt/Networking/AppConfig.swift` | Shortbread URL + idle camera |
| `Dirt/Features/Layers/LayersSheet.swift` | Basemap picker + all overlay toggles |

---

## MapLibre integration

- Default style: OSM **Shortbread** (bundled `shortbread-style.json`) — high-contrast paint tuned for sunlight readability, derived from web `tuneShortbreadContrast()`.
- **Swappable basemaps** (`MapStyleCatalog` + Layers → Basemap):
  | ID | Source | Notes |
  | --- | --- | --- |
  | `shortbread` | Bundled Shortbread JSON | High-contrast OSM vector; works offline; no billing |
  | `esriSatellite` | Esri World Imagery raster tiles | No token required; aerial imagery via ArcGIS Online |
- Esri style is written to a cache-directory JSON at selection time (same raster-spec pattern as the old Mapbox path). Tile URL: `https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}` (Esri uses `{z}/{y}/{x}` order).
- No Mapbox token required or expected. `MapStyleCatalog.tokenKey` and `hasMapboxToken` have been removed.
- **Routing is unchanged:** OSM dual-sport graph via `POST /api/route`. Basemap swap is visual only.
- Idle camera: NS overview `(-63.0, 45.1)` zoom `7.25`.
- `MLNMapView` via `UIViewRepresentable`; coordinator owns style load / reload (`styleGeneration`), route sync, markers, camera, follow mode.
- User location: `showsUserLocation` when authorized; nav sets `userTrackingMode = .followWithCourse`.
- Gestures: tap → `MapState.onTap`; long-press → `onLongPress` (wired to planner in `AppEnvironment`).
- Logo hidden; attribution bottom-left; compass top-right.

Generation counters (`routeGeneration`, `markerGeneration`, `styleGeneration`, `poiDataGeneration`, `networkDataGeneration`, `layerPrefsGeneration`) avoid redundant UIKit work.

`MapState` also exposes `mapCenter: CLLocationCoordinate2D` and `mapZoom: Double` (updated by the Coordinator on `regionDidChangeAnimated`) so `@Observable`-observing managers can react to viewport changes without needing a direct callback.

**Ported:** web’s `tuneShortbreadContrast()` logic is baked into `shortbread-style.json` paint properties (background, water fills/lines, forest, park/vegetation, residential, commercial, industrial, farmland, cemetery, school, sand — 57 layers). No runtime post-load patching needed.

---

## Route rendering

`MapState.displaySegments(from:)` merges adjacent same-surface edges (web-style), then MapLibre paints two sources:

| Source / layer | Colour | Meaning |
| --- | --- | --- |
| `dirt-route-access-*` | `#0a66c2` | access / resource |
| `dirt-route-gravel-*` | `#5d6874` | gravel / unknown / unpaved |
| `dirt-route-track-*` | `#7c3aed` | track / double_track (branches) |
| `dirt-route-paved-*` | `#ffb000` | paved (+ default) |
| `dirt-route-connector-*` | `#d22730` | connector / no-segment fallback |
| Casings | White ~85% opacity | Readability |

Matches live web `route-network` paint (not stats mix `#3a9dff` / `#fdb003`, and not brand orange).

`RouteSegment.paintSurfaceKey` prefers `surfaceClass` then `trackClass`. If a response has **no** `segments`, the full geometry paints as **connector** (web parity).

`RouteSegment.isDirt` / adventure surfaces still drive dirt% vocabulary; paint is per-class.

---

## Markers

| Kind | Look | Used for |
| --- | --- | --- |
| `.start` / `.stage` | Chrome fill, white stroke | Plan A / intermediate |
| `.destination` | Orange fill | B |
| `.rider` | Nav green fill | Live group peers |

Rider callouts enabled; `onRiderTap` hook exists (planner/groups can extend). Groups merge rider pins without wiping route markers.

---

## User location

`LocationService`: best accuracy, `otherNavigation`, 5 m filter.

| Mode | When |
| --- | --- |
| When-In-Use | App launch (`RootView.task`) |
| Always | Start nav / Start sharing |
| Background updates | Nav active or sharing (`allowsBackgroundLocationUpdates`) — requires `UIBackgroundModes` = `location` in merged `Config/Info.plist`. Enabling without that key is a fatal Core Location crash. |

Locate button (top chrome) flies to current fix or re-requests When-In-Use.

---

## Offline tiles — session rules

Web rules (identity `dirt-nav-basemap-v2` on web) are mirrored in `OfflineTileManager` comments and behaviour:

| # | Rule | iOS behaviour |
| --- | --- | --- |
| 1 | Prefetch **only on Start Navigation** | `RoutePlannerModel.startNavigation` → `offline.startPrefetch` |
| 2 | Same route identity → keep / top up | `keepExisting` when identity == `lastNavigationIdentity` |
| 3 | Mid-trip recalculate → keep tiles | `recalculateFromRider` passes `keepExisting: true` |
| 4 | Clear only when Start Nav on a **different** identity | Removes packs whose context ≠ new identity when `!keepExisting` |
| — | End nav alone must **not** wipe cache | `endNavigation` does not call pack removal |

Navigation becomes active immediately. MapLibre offline packs are **fully disabled** and any leftover packs are purged on launch. MapLibre Native aborts with `std::regex_error` on the `DatabaseFileSource` thread when offline packs enumerate glyph URLs containing `{fontstack}/{range}` (known upstream). Start Navigation no longer creates or resumes packs. iOS ships a bundled Shortbread style with absolute sprite URLs (the remote style’s root-relative sprite caused `NSURLError -1002`).

### iOS vs web offline quality

| | Web | iOS v1 |
| --- | --- | --- |
| Trigger | Start Nav | Start Nav |
| Geometry | Corridor-oriented tile set (documented web cache) | **Bounding-box tile pyramid** z8–14 + 0.02° pad (`MLNTilePyramidOfflineRegion`) |
| Cap | ~1200 tiles / concurrency 4 (web) | MapLibre pack progress; 45s wall-clock skip |
| Style | Same Shortbread host (or active Mapbox raster) | `AppConfig.activeMapStyleURL` |

Documented limit in README and code: **not a true route corridor** — best-effort bbox covering the polyline extents.

---

## Layers / overlays

`LayersSheet` persists basemap choice, Rider Services, and Route data (NS/NB/QC lens) via `@AppStorage`.  
Toggle changes bump `app.mapState.layerPrefsGeneration` so managers refresh. Map visibility surface-class toggles were removed — network classes always paint when loaded.

### Rider Services POIs

`POIManager` (owned by `AppEnvironment`) observes `mapState.mapCenter`, `mapState.mapZoom`, and `mapState.layerPrefsGeneration` via `withObservationTracking`.

| | |
|---|---|
| **Data source** | `https://dirt-mayday.vercel.app/app/data/poi/poi.manifest.json` + `…/chunks/{id}.json.gz` |
| **Chunk format** | `{id, category, lat, lon, name, address, brand, openingHours, phone, website}` |
| **Trigger** | Map viewport change or layer pref change (350 ms debounce) |
| **Min zoom** | 8.5 (below: source cleared) |
| **Chunk cap** | 14 nearest to map center (web `POI_MAX_CHUNKS`) |
| **MapLibre** | Source `dirt-poi` (GeoJSON); 4 `MLNCircleStyleLayer` (one per category) |
| **Colors** | fuel #e8730c, campground #2f9e44, lodging #8a5a2b, liquor #8e44c9 |
| **Tap** | Coordinator `handleTap` → `queryRenderedFeatures` on poi layers → `mapState.onPOITap` → `mapState.selectedPOI` → `RootView confirmationDialog` |
| **Routing** | "Route to this" → `planner.routeToCoordinate`; "Add as waypoint" → `planner.addPlanWaypoint` |

### Province network overlays (NS / NB / QC)

`NetworkOverlayManager` mirrors the web corridor + viewport-lens loader.

| | |
|---|---|
| **Data sources** | `…/ns-gov-roads.manifest.json` + `…/ns-gov-chunks/{id}.geojson.gz` (same for NB/QC) |
| **Chunk format** | GeoJSON FeatureCollection, properties: `edgeId, surfaceClass, accessClass, structureType, province` |
| **Corridor mode** | Toggle off: NS lines within 2–3 km of map focus + route anchors when a route exists, or at zoom ≥ 12.5 |
| **Lens mode** | Show NS/NB/QC route lines (one at a time): viewport paint for that province |
| **Chunk / feature caps** | Corridor 6 / 1600; lens 8 / 5000 |
| **MapLibre source** | `dirt-network` (GeoJSON) |
| **Layers** | `dirt-net-access` (blue), `dirt-net-gravel` (gray), `dirt-net-track` (purple), `dirt-net-restricted` (red dashed), `dirt-net-bridge` (teal), `dirt-net-tunnel` (brown dashed) — always visible when loaded |

### Layer insertion order

```
dirt-net-access / gravel / track / restricted / bridge / tunnel   ← below route
dirt-route-{bucket}-casing / line                                  ← route
dirt-poi-{category}                                                ← above route
```

---

## Starting a new agent on this area

1. Read `MapLibreMapView.swift`, `MapState.swift`, `POIManager.swift`, `NetworkOverlayManager.swift`, `GeoJSON+Utils.swift`.
2. Cross-check session rules with [WEB-SPEC-FOR-IOS.md](./WEB-SPEC-FOR-IOS.md) §6.
3. For overlay streams, study web `app/index.html` sources — do not invent tile URLs; CDN at `https://dirt-mayday.vercel.app/app/data/`.
4. **Invariants:** Start-Nav-only prefetch; keep-through-reroute; never clear packs on End alone; selected-route paint stays on web per-surface palette (not stats mix, not brand-orange-only); production style URL.
5. **Open questions:** true corridor pack vs bbox; MaxOfflinePack size / eviction policy on device; POI clustering for dense areas.
