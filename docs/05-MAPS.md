# DIRT iOS — Maps

MapLibre Native integration, route paint, markers, location, and offline tile session rules. Spec: [WEB-SPEC-FOR-IOS.md](./WEB-SPEC-FOR-IOS.md) §6.

---

## Key files

| File | Role |
| --- | --- |
| `Dirt/Map/MapLibreMapView.swift` | `UIViewRepresentable` + style layers + gestures |
| `Dirt/Map/MapState.swift` | Observable map model (route, markers, camera, style) |
| `Dirt/Map/MapStyleCatalog.swift` | Basemap IDs, Mapbox token, style URL writer |
| `Dirt/Map/OfflineTileManager.swift` | Offline pack prefetch (active basemap) |
| `Dirt/Networking/AppConfig.swift` | Shortbread URL + idle camera |
| `Dirt/Features/Layers/LayersSheet.swift` | Basemap picker + legend prefs |

---

## MapLibre integration

- Default style: OSM **Shortbread** at `https://dirt-mayday.vercel.app/app/data/shortbread-style.json` (vector tiles; no Mapbox token).
- **Swappable basemaps** (`MapStyleCatalog` + Layers → Basemap):
  | ID | Source | Notes |
  | --- | --- | --- |
  | `shortbread` | Production Shortbread JSON | Works offline without Mapbox |
  | `mapboxOutdoors` | Mapbox Outdoors v12 **raster** tiles | Needs `pk.` token; terrain / trails / land cover |
  | `mapboxStreets` | Streets v12 raster | Token required |
  | `mapboxSatellite` | `mapbox.satellite` raster | Token required |
- MapLibre cannot resolve `mapbox://` URIs, so Mapbox styles are written as local Style Spec JSON using the [Static / Raster Tiles APIs](https://docs.mapbox.com/help/dive-deeper/mapbox-in-maplibre/) (token only in UserDefaults / Info.plist / env — never committed).
- **Routing is unchanged:** OSM dual-sport graph via `POST /api/route`. Basemap swap is visual only.
- Idle camera: NS overview `(-63.0, 45.1)` zoom `7.25`.
- `MLNMapView` via `UIViewRepresentable`; coordinator owns style load / reload (`styleGeneration`), route sync, markers, camera, follow mode.
- User location: `showsUserLocation` when authorized; nav sets `userTrackingMode = .followWithCourse`.
- Gestures: tap → `MapState.onTap`; long-press → `onLongPress` (wired to planner in `AppEnvironment`).
- Logo hidden; attribution bottom-left; compass top-right.

Generation counters (`routeGeneration`, `markerGeneration`, `styleGeneration`) avoid redundant UIKit work.

**Not ported:** web’s `tuneShortbreadContrast()` post-load colour tweaks. Native uses the remote Shortbread style as served (or Mapbox raster as selected).

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

`LayersSheet` persists basemap choice, optional Mapbox token, Rider Services + Map Visibility toggles via `@AppStorage`.

**No GeoJSON/POI/NSTDB sources are added to the map yet.** Toggles are preference-only; sheet copy states overlays land in a later build. See [07-FUTURE.md](./07-FUTURE.md).

---

## Starting a new agent on this area

1. Read `MapLibreMapView.swift`, `MapState.swift`, `OfflineTileManager.swift`.
2. Cross-check session rules with [WEB-SPEC-FOR-IOS.md](./WEB-SPEC-FOR-IOS.md) §6.
3. For overlay streams, study web `app/index.html` sources — do not invent tile URLs.
4. **Invariants:** Start-Nav-only prefetch; keep-through-reroute; never clear packs on End alone; selected-route paint stays on web per-surface palette (not stats mix, not brand-orange-only); production style URL.
5. **Open questions:** true corridor pack vs bbox; port `tuneShortbreadContrast`; MaxOfflinePack size / eviction policy on device.
