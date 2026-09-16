# DIRT iOS — Maps

MapLibre Native integration, route paint, markers, location, and offline tile session rules.

---

## Key files

| File | Role |
| --- | --- |
| `Dirt/Map/MapLibreMapView.swift` | `UIViewRepresentable` + style layers + gestures |
| `Dirt/Map/MapState.swift` | Observable map model (route, markers, camera, style, overlays) |
| `Dirt/Map/MapStyleCatalog.swift` | Basemap IDs, style URL writer |
| `Dirt/Map/ShortbreadTileSource.swift` | Dirt manifest validation, health gate, fallback, rollback |
| `Dirt/Map/OfflineTileManager.swift` | Offline pack prefetch (active basemap) |
| `Dirt/Map/POIManager.swift` | Rider Services POIs from DIRT `/api/poi` + packed fuel → MapState |
| `Dirt/Map/NetworkOverlayManager.swift` | Paints nearby edges from the installed graph pack |
| `Dirt/Map/ne-admin1-na.json` | Simplified Natural Earth 50m admin-1 interior lines (US+CA) for overview |
| `Dirt/Networking/AppConfig.swift` | Shortbread URL + idle camera |
| `Dirt/Features/Layers/LayersSheet.swift` | Basemap picker + all overlay toggles |
| `scripts/shortbread-edge/` | Reproducible PMTiles build, R2 Worker, deploy and verification |

---

## MapLibre integration

- Default style schema: OSM **Shortbread** (bundled `shortbread-style.json`).
- **Swappable basemaps** (`MapStyleCatalog` + Layers → Basemap):
  | ID | Source | Notes |
  | --- | --- | --- |
  | `shortbread` | Bundled Shortbread JSON | Standard · high-contrast OSM vector |
  | `shortbreadRich` | Runtime derivative of bundled JSON | Default · richer outdoor palette and road colours |
- **Tile delivery:** the app starts safely on public OSM Shortbread, then validates
  Dirt's manifest and an R2-backed sample tile. Only a compatible, healthy,
  same-origin release replaces the tile URL in every vector source.
- **Current Dirt release:** `maritimes-20260607`, Shortbread 1.0, source data
  `2026-06-07`, bounds `-69,43,-59,49`, native zoom 0–14.
- **Immutable R2 object:**
  `dirt-packs/shortbread/v1/releases/maritimes-20260607/maritimes.pmtiles`
  (238,802,510 bytes; SHA-256
  `2dd47ad2a6091a6800fd49d20cc90c913056fd0c36648b1d315165a60c4756f6`).
- **Edge service:** `dirt-shortbread-tiles` serves manifest, health, and
  release-versioned MVT URLs. Tiles outside the first regional archive pass
  through the public Shortbread fallback instead of leaving a blank map.
- **Rollback:** an unhealthy manifest/sample stays on public OSM automatically;
  `dirt.shortbread.forcePublicFallback = true` is the app-wide emergency switch.
- **Custom domain:** `tiles.dirtmoto.app` is reserved as the durable endpoint.
  `dirtmoto.app` DNS is currently at SiteGround; no DNS change has been made.
  Attach that hostname deliberately, verify TLS/headers, then change only the
  manifest URL in `AppConfig`.
- No Mapbox token. Retired Esri satellite maps to Rich.
- **Routing is unchanged:** OSM dual-sport graph via on-device / live packs. Basemap swap is visual only.
- Idle camera: continental US overview `(39.5, -98.0)` zoom `3.5` — do not flash Nova Scotia at launch.
- `MLNMapView` via `UIViewRepresentable`; coordinator owns style load / reload (`styleGeneration`), route sync, markers, camera, follow mode.
- User location: `showsUserLocation` when authorized; nav sets `userTrackingMode = .followWithCourse`.
- Gestures: tap → `MapState.onTap`; long-press → `onLongPress` (wired to planner in `AppEnvironment`).
- Logo hidden; attribution bottom-left; compass top-right.

Generation counters (`routeGeneration`, `markerGeneration`, `styleGeneration`, `poiDataGeneration`, `networkDataGeneration`, `layerPrefsGeneration`) avoid redundant UIKit work.

`MapState` also exposes `mapCenter: CLLocationCoordinate2D` and `mapZoom: Double` (updated by the Coordinator on `regionDidChangeAnimated`) so `@Observable`-observing managers can react to viewport changes without needing a direct callback.

Contrast is baked into `shortbread-style.json` paint properties (background, water fills/lines, forest, park/vegetation, residential, commercial, industrial, farmland, cemetery, school, sand — 57 layers). No runtime post-load patching needed.

---

## Route rendering

`MapState.displaySegments(from:)` merges adjacent same-surface edges. Selected-route paint uses `DirtTheme` tokens, 8 pt opaque, inserted **below** street-name labels:

| Source / layer | Colour | Meaning |
| --- | --- | --- |
| `dirt-route-paved-*` | `#14161A` | paved |
| `dirt-route-gravel-*` | `#B56A00` | gravel (selected route) |
| `dirt-route-loose-*` | `#6E2F16` | loose / technical dirt |
| `dirt-route-unknown-*` | `#555A63` | unknown surface |
| `dirt-route-unknown-access-*` | `#54208F` | unknown motor access (not a surface) |
| `dirt-route-ferry-*` | `#005A70` dashed over white casing | ferry connector |

Nearby pack-network overlay uses a **separate** thinner palette so the same words do not collide: overlay gravel is cool gray `#5D6874`, overlay access is blue `#0A66C2`, overlay dirt/track is route-loose brown `#6E2F16`.

`RouteSegment.paintSurfaceKey` prefers `surfaceClass` then `trackClass`. If a response has **no** `segments`, the full geometry paints as **unknown**.

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

Session rules in `OfflineTileManager`:

| # | Rule | iOS behaviour |
| --- | --- | --- |
| 1 | Network prefetch **only on Start Navigation** | Route review may prime geometry only; Start triggers tile requests |
| 2 | Reuse / top up by z/x/y | Existing compatible tiles survive route and provider changes |
| 3 | Mid-trip recalculate → keep tiles | `recalculateFromRider` passes `keepExisting: true` |
| 4 | Block only on the first rider/fuel stage | Later stages do not delay navigation start |
| 5 | Prepare exactly one stage ahead | Serialized background work at concurrency 3 |
| — | Route changes and End Nav must **not** wipe cache | Disk cache is geography-addressed, not route-addressed |

Navigation becomes active immediately. MapLibre offline packs are **fully disabled** and any leftover packs are purged on launch. MapLibre Native aborts with `std::regex_error` on the `DatabaseFileSource` thread when offline packs enumerate glyph URLs containing `{fontstack}/{range}` (known upstream). Start Navigation no longer creates or resumes packs. Sprites are the bundled Shortbread sheet (local file URL).

### Offline tile quality

| | iOS |
| --- | --- |
| Trigger | Start Nav |
| Geometry | Route-intersected Shortbread pyramid through native z14, with a small readability halo |
| Cap | 1,200 tiles per stage plan; required ride tiles distinguished from optional halo tiles |
| Blocking concurrency | 6 (parallel testing remains unrelated and disabled) |
| Fill order | Health-approved Dirt origin, then public OSM transport fallback |
| Style | Same active origin for live MapLibre, downloads, and localhost proxy fill-through |

The provider switch deliberately keeps the existing `dirt-nav-basemap-v2`
cache because both origins are compatible Shortbread v1 tiles. A future schema
major must use a new cache namespace instead of reinterpreting old bytes.

---

## Layers / overlays

`LayersSheet` persists basemap choice and Rider Services via `@AppStorage`. Network lens prefs are cleared on launch and no longer read. Overlay paint is the installed pack.

### Basemap labels and borders

`MapStyleCatalog.generatedShortbreadStyleURL` (revision `osmand-v3`) restyles OSM Shortbread toward OsmAnd: pale land, orange motorways, green cover from z7, highway shields, and **real** admin lines. Country borders (`admin_level=2`) from Shortbread z0. Province/state borders: bundled Natural Earth 50m Admin-1 (lakes) linework from z0–7, then Shortbread `admin_level=4` from z7 — **do not change that handoff**. Do **not** paint `RegionPolygons` pack bounds. Glanceable type: near-black `#111418`, cream halo ~2.6 px. Country names through z6; province/state names held through z12. Place floors: capital z2, city z4, town z7, village/hamlet/island z10. Major road names from z10, local streets from z11. Rich is the same structure with ×1.15 saturation.

### Rider Services POIs

`POIManager` (owned by `AppEnvironment`) observes `mapState.mapCenter`, `mapState.mapZoom`, and `mapState.layerPrefsGeneration` via `withObservationTracking`.

| | |
|---|---|
| **Data source** | Fuel: packed DIRT fuel service/installed pack. Campground, lodging, and liquor: build-selected DIRT `/api/poi`, which validates the viewport and provides bounded OSM Overpass fallback. |
| **Trigger** | Map viewport change or layer pref change (350 ms debounce) |
| **Min zoom** | 6.5 (below: source cleared) |
| **MapLibre** | Source `dirt-poi` (GeoJSON); 4 `MLNCircleStyleLayer` (one per category) |
| **Colors** | fuel `#FF8000` (`DirtTheme.orange`; same as planner F-pins), campground #2f9e44, lodging #8a5a2b, liquor #8e44c9 |
| **Tap** | Coordinator `handleTap` → `queryRenderedFeatures` on poi layers → `mapState.onPOITap` → `mapState.selectedPOI` → `RootView confirmationDialog` |
| **Routing** | "Route to this" → `planner.routeToCoordinate`; "Add as waypoint" → `planner.addPlanWaypoint` |

### Province network overlays

`NetworkOverlayManager` paints nearby pack edges for display. Caps below are not routing search horizons. Honest Layers: when Allow is off, `motorized_unknown` / `motorized_excluded` are omitted. Routing laws: [ROUTING-SOURCE-OF-TRUTH.md](ROUTING-SOURCE-OF-TRUTH.md).

| | |
|---|---|
| **Data source** | Compatible installed graph and paired geometry for the displayed area |
| **When it paints** | Zoom ≥ 12.5, or Release DIRT-logo toggle (`showRoutingGraphDebug` without the DEBUG HUD). Built routes do **not** force the overlay at overview. |
| **Feature cap** | 1600 GeoJSON lines, bbox around map focus + route anchors |
| **MapLibre source** | `dirt-network` (GeoJSON) |
| **Layers** | `dirt-net-access` (blue), `dirt-net-gravel` (gray), `dirt-net-track` (brown / `track` tag), `dirt-net-restricted` (red dashed), `dirt-net-bridge` (teal), `dirt-net-tunnel` (brown dashed) |
| **DEBUG logo** | Heavy `RoutingGraphDebugManager` + GRAPH HUD. Release logo uses this lighter corridor instead. |

Loose/technical pack edges tag `surfaceClass: track` so `dirt-net-track` actually draws them.

### Layer insertion order

```
dirt-net-access / gravel / track / restricted / bridge / tunnel   ← nearby network
dirt-route-{bucket}-line                                           ← selected route
dirt-poi-{category}                                                ← above route
street-name labels                                                 ← above route (style)
```

---

## Starting a new agent on this area

1. Read `MapLibreMapView.swift`, `MapState.swift`, `POIManager.swift`, `NetworkOverlayManager.swift`, `GeoJSON+Utils.swift`.
2. Overlays paint the installed graph pack. Non-fuel POIs come through DIRT's
   `/api/poi`; the phone never depends on one public Overpass host. Preserve the
   last successful non-fuel viewport paint during a temporary upstream outage.
3. **Invariants:** Start-Nav-only tile prefetch; keep-through-reroute; never clear tiles on End alone; selected-route paint stays on the per-surface palette; bundled style. Do not flash NS at launch.
4. BC OSM mbtiles experiment is retired (class is a no-op). Network lens prefs are not read.
