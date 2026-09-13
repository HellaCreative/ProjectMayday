# DIRT iOS — Stack

Current native stack, project wiring, and the build/signing issues that already burned time. Companion: [00-OVERVIEW.md](./00-OVERVIEW.md), [../README_TESTFLIGHT.md](../README_TESTFLIGHT.md).

---

## Runtime stack

| Layer | Choice | Notes |
| --- | --- | --- |
| Language / UI | Swift + SwiftUI | `@Observable` composition; light colour scheme forced in `DirtApp` |
| Map | MapLibre Native **6.28.0** (SPM) | `UIViewRepresentable` → `MLNMapView` |
| Backend auth / DB | Supabase Swift **2.53.0** | Baked publishable config; Keychain session by SDK default |
| Local routes | SwiftData | `SavedRoute` model only |
| Location | Core Location | When-In-Use + Always escalate; `UIBackgroundModes = location` |
| Networking | `URLSession` | Live `/api/route` + `/api/poi` + R2 pack CDN + Supabase |

No third-party nav SDK. MapLibre Native + SwiftUI.

---

## Existing configuration inventory

Configuration is implemented in `Dirt/Networking/AppConfig.swift`. The endpoint
examples below identify existing integrations, not routing-source selection or
current release acceptance. Routing decisions are defined only in [the routing source of truth](ROUTING-SOURCE-OF-TRUTH.md).

| Constant | URL |
| --- | --- |
| `routeURL` | `https://dirt-mayday.vercel.app/api/route` (live routing API) |
| `supabaseURL` | `https://iiiguqknqxoumlmppzfw.supabase.co` |
| `packCDNBaseURL` | Cloudflare R2 `pub-eb539dc7777942b889388ebb4b701697.r2.dev` |
| `livePOIURL` | Build-selected DIRT `/api/poi`; server provides bounded OSM Overpass fallback |
| `mapStyleURL` | bundled `shortbread-style.json` |

Development/production isolation and environment configuration are documented in
[ENVIRONMENTS-AND-RELEASES.md](ENVIRONMENTS-AND-RELEASES.md).

---

## Project structure

```
Dirt.xcodeproj          # open this (shared DIRT Dev / DIRT Production schemes)
Dirt/                   # app sources (see 00-OVERVIEW)
DirtTests/              # unit tests (bundle com.mayday.dirt.tests)
DirtUITests/            # UI tests (bundle com.mayday.dirt.uitests)
ExportOptions.plist     # app-store-connect export, team 34XM6B4G7A
build/                  # gitignored; local archive lives here
docs/                   # iOS handoffs
README_TESTFLIGHT.md
```

SPM pins: `Dirt.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

Package refs in `project.pbxproj`:

- `https://github.com/maplibre/maplibre-gl-native-distribution` (≥ 6.0, pinned 6.28.0)
- `https://github.com/supabase/supabase-swift.git` (≥ 2.0, pinned 2.53.0)

---

## Build / signing identity

| Field | Value |
| --- | --- |
| Bundle ID | `com.mayday.dirt` |
| Display name | `DIRT` |
| ASC SKU | `MAYDAY-DIRT-IOS-001` (ASC only — not in Xcode) |
| Team | `34XM6B4G7A` |
| Version / build | `1.0` / `1` |
| Deployment | iOS **26.5** |
| Category | Navigation |
| Permissions | When-In-Use + Always location strings; background `location` |

Archive on disk (2026-07-25): `build/Dirt.xcarchive`, signed **Apple Development: Rick Smith (AAZ5AN6BBG)**. Export failed with `No profiles for 'com.mayday.dirt' were found` — needs App Store distribution profile (usually created by Organizer Distribute while signed into the team).

CLI recipes: [../README_TESTFLIGHT.md](../README_TESTFLIGHT.md).

---

## Composition root

`Dirt/App/AppEnvironment.swift` owns:

`LocationService` · `OnDeviceRouter` · `GraphPackStore` · `SupabaseService` · `MapState` · `OfflineTileManager` · `NavigationSession` · `RoutePlannerModel` · `GroupsViewModel`

Map tap / long-press callbacks are wired into the planner at init. `DirtApp` injects the environment and a SwiftData `ModelContainer` for `SavedRoute`.

---

## What worked

| Area | Outcome |
| --- | --- |
| `xcodebuild` simulator + generic device | Clean builds with SPM resolved from CLI |
| Archive | Succeeded → `build/Dirt.xcarchive` |
| Feature surface | Full dock + planner + nav + auth + groups shipped in `e2e790d` |
| Packs + auth | R2 graph packs + Supabase |

---

## What fought us

### 1. Workspace / path disconnect

Open `Dirt.xcodeproj` in the checkout assigned to the current task. Confirm its
path and branch before editing. General workspace guidance is in
[AGENTS.md](../AGENTS.md); routing workspace ownership is in [the routing source of truth](ROUTING-SOURCE-OF-TRUTH.md).

### 2. Xcode GUI scheme + SPM resolution (`e98f6d4`)

CLI builds worked; Xcode GUI could not resolve MapLibre / Supabase products cleanly.

**Fix shipped in `e98f6d4`:**

1. Added explicit shared schemes: `DIRT Dev` for Debug testing and
   `DIRT Production` for Release validation and archives.
2. Normalized SPM object IDs in `project.pbxproj` (package refs + product dependencies) so IDE resolution matches the command-line graph.

If Xcode again shows missing MapLibre/Supabase products: File ▸ Packages ▸ Resolve Package Versions, confirm **DIRT Dev** is selected, and do not invent a second package reference.

### 3. IPA / TestFlight gate

Archive ≠ distributable IPA. Automatic signing without an App Store profile blocks `exportArchive`. Upload still needs Organizer or an ASC API key on the Mac.

---

## Starting a new agent on this area

1. Read [../AGENTS.md](../AGENTS.md), then `Dirt/Networking/AppConfig.swift`, `Dirt/DirtApp.swift`, `Dirt/App/AppEnvironment.swift`.
2. Skim `Dirt.xcodeproj/project.pbxproj` SPM sections + `Package.resolved` for pinned versions.
3. Read [../README_TESTFLIGHT.md](../README_TESTFLIGHT.md) before touching signing or CI.
4. Preserve the build-selected development/production isolation, deployment target, bundle IDs, and explicit shared `DIRT Dev` / `DIRT Production` schemes unless the current task authorizes changing them. Routing architecture and execution choices belong only in [the routing source of truth](ROUTING-SOURCE-OF-TRUTH.md).
5. **Open questions:** whether to commit DerivedData-free CI scripts; ASC API key placement for non-interactive uploads.
