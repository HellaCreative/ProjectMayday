# DIRT iOS — Maps

MapLibre Native integration, route paint, markers, location, and offline tile session rules. Spec: [WEB-SPEC-FOR-IOS.md](./WEB-SPEC-FOR-IOS.md) §6.

---

## Key files

| File | Role |
| --- | --- |
| `Dirt/Map/MapLibreMapView.swift` | `UIViewRepresentable` + style layers + gestures |
| `Dirt/Map/MapState.swift` | Observable map model (route, markers, camera) |
| `Dirt/Map/OfflineTileManager.swift` | Offline pack prefetch |
| `Dirt/Networking/AppConfig.swift` | Style URL + idle camera |
| `Dirt/Location/LocationService.swift` | GPS feed |
| `Dirt/Features/Layers/LayersSheet.swift` | Legend prefs (overlays not painted yet) |

---

## MapLibre integration

- Style URL: `https://dirt-mayday.vercel.app/app/data/shortbread-style.json` (Shortbread / SVWD03; vector tiles from OSM Shortbread as defined by that style).
- Idle camera: NS overview `(-63.0, 45.1)` zoom `7.25`.
- `MLNMapView` via `UIViewRepresentable`; coordinator owns style load, route sync, markers, camera, follow mode.
- User location: `showsUserLocation` when authorized; nav sets `userTrackingMode = .followWithCourse`.
- Gestures: tap → `MapState.onTap`; long-press → `onLongPress` (wired to planner in `AppEnvironment`).
- Logo hidden; attribution bottom-left; compass top-right.

Generation counters (`routeGeneration`, `markerGeneration`) avoid redundant UIKit work.

**Not ported:** web’s `tuneShortbreadContrast()` post-load colour tweaks. Native uses the remote style as served.

---

## Route rendering

`MapState.displaySegments(from:)` merges adjacent same-surface edges (web-style), then MapLibre paints two sources:

| Source / layer | Colour | Meaning |
| --- | --- | --- |
| `dirt-route-dirt-*` | Brand orange `#ff7a00` | Adventure / dirt segments (`segment.isDirt`) |
| `dirt-route-paved-*` | Paved line `#303a45` | Paved segments |
| Both casings | White ~85% opacity | Readability |

If a response has **no** `segments`, the full geometry is painted as dirt/orange (selected-route treatment).

`RouteSegment.isDirt` treats surface/track classes: gravel, dirt, track, access, resource, unknown, unpaved.

**UI stats** still use dirt mix `#3a9dff` / paved mix `#fdb003` — those are **not** the map line colours. See [06-UI-DESIGN.md](./06-UI-DESIGN.md).

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
| Background updates | Nav active or sharing (`allowsBackgroundLocationUpdates`) |

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

Prefetch UI: HUD “Preparing offline tiles” with progress + **Skip**. Hard **45s** cap then proceeds to active nav.

### iOS vs web offline quality

| | Web | iOS v1 |
| --- | --- | --- |
| Trigger | Start Nav | Start Nav |
| Geometry | Corridor-oriented tile set (documented web cache) | **Bounding-box tile pyramid** z8–14 + 0.02° pad (`MLNTilePyramidOfflineRegion`) |
| Cap | ~1200 tiles / concurrency 4 (web) | MapLibre pack progress; 45s wall-clock skip |
| Style | Same Shortbread host | Same `mapStyleURL` |

Documented limit in README and code: **not a true route corridor** — best-effort bbox covering the polyline extents.

---

## Layers / overlays

`LayersSheet` persists Rider Services + Map Visibility toggles via `@AppStorage`.

**No GeoJSON/POI/NSTDB sources are added to the map yet.** Toggles are preference-only; sheet copy states overlays land in a later build. See [07-FUTURE.md](./07-FUTURE.md).

---

## Starting a new agent on this area

1. Read `MapLibreMapView.swift`, `MapState.swift`, `OfflineTileManager.swift`.
2. Cross-check session rules with [WEB-SPEC-FOR-IOS.md](./WEB-SPEC-FOR-IOS.md) §6.
3. For overlay streams, study web `app/index.html` sources — do not invent tile URLs.
4. **Invariants:** Start-Nav-only prefetch; keep-through-reroute; never clear packs on End alone; dirt map line stays brand orange unless product reopens paint law; production style URL.
5. **Open questions:** true corridor pack vs bbox; port `tuneShortbreadContrast`; MaxOfflinePack size / eviction policy on device.
