# DIRT iOS — Overview

Native SwiftUI client for the DIRT dual-sport navigator. Same production backend as the web POC. No staging.

| | |
| --- | --- |
| Web POC (behaviour + backend SoT) | https://dirt-mayday.vercel.app |
| Web repo | `/Users/richardsmith/SandBox01/Mayday` |
| iOS repo (this tree) | `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt` |
| Local branch | `main` |

---

## Why native iOS

The web POC is a capable MapLibre + Vercel + Supabase product, but an HTML/CSS/JS shell on a phone is the wrong chassis for:

- Background location (nav + group share with screen off)
- Offline tile packs tied to a ride session
- Turn-by-turn HUD that must survive lock screen / interruptions
- App Store / TestFlight distribution and OS permissions UX

v1 is **fully native SwiftUI** — no `WKWebView`, no Capacitor, no hybrid shell. MapLibre Native renders the map; routing and auth still hit production Vercel + Supabase.

---

## Product summary

DIRT helps dual-sport riders plot A→B routes with surface-mix control (Clean / Direct / Balanced / Dirt + Allow unknown), navigate the line, save/export GPX, and optionally ride with a signed-in group (presence share, route-to-member).

Design and API contracts for parity live in [WEB-SPEC-FOR-IOS.md](./WEB-SPEC-FOR-IOS.md). TestFlight / signing steps live in [../README_TESTFLIGHT.md](../README_TESTFLIGHT.md).

---

## Doc index

| Doc | Scope |
| --- | --- |
| [00-OVERVIEW.md](./00-OVERVIEW.md) | This file — status, locked decisions |
| [01-STACK.md](./01-STACK.md) | Swift stack, SPM, structure, signing, build battles |
| [02-ROUTING.md](./02-ROUTING.md) | Client models, API contract, profiles, server context |
| [03-GROUPS.md](./03-GROUPS.md) | Groups, presence, polling gap |
| [04-PROFILES-AUTH.md](./04-PROFILES-AUTH.md) | Email OTP, session, display name |
| [05-MAPS.md](./05-MAPS.md) | MapLibre, style, route paint, offline tiles |
| [06-UI-DESIGN.md](./06-UI-DESIGN.md) | Tokens, dock, CTAs, parity vs web |
| [07-FUTURE.md](./07-FUTURE.md) | Deferred work + App Store checklist |
| [WEB-SPEC-FOR-IOS.md](./WEB-SPEC-FOR-IOS.md) | Full web → iOS behaviour/API spec (do not duplicate) |
| [../README_TESTFLIGHT.md](../README_TESTFLIGHT.md) | Device / archive / TestFlight ops |

---

## Current status snapshot (verified 2026-07-26)

| Item | State |
| --- | --- |
| Latest commits | `e2e790d` feature build · `e98f6d4` shared scheme + SPM ID fix |
| Bundle ID | `com.mayday.dirt` |
| ASC SKU (ASC only) | `MAYDAY-DIRT-IOS-001` |
| Team | `34XM6B4G7A` |
| Marketing / build | `1.0` / `1` |
| Deployment target | iOS 26.5 |
| SPM pins | MapLibre Native **6.28.0**, Supabase Swift **2.53.0** |
| Simulator build | Passes |
| Device / generic iOS build | Passes |
| Archive | Exists at `build/Dirt.xcarchive` (Apple Development identity) |
| IPA export | **Blocked** — no App Store distribution profile for `com.mayday.dirt` |
| TestFlight upload | **Pending** Rick (Xcode Organizer Distribute, or ASC API key) |

### Shipped in v1 (code-backed)

Map idle + dock · From here / Plan stages / Saved (SwiftData) · Save + Export GPX · Start/End nav HUD + off-route recalculate · Offline bbox tile prefetch on Start (45s cap) · Email OTP + profile · Groups create/join/leave/delete + share + route-to-member · Layers legend toggles (prefs only).

### Known v1 gaps

POI / NSTDB overlay streams · Supabase realtime channel (presence is **polling**) · true corridor offline tiles · shared incidents / avoid-edge · GPX import · Watch / CarPlay / Live Activities / voice / haptics.

---

## Locked decisions

| Decision | Rule |
| --- | --- |
| Backend | Stay on **production Vercel + Supabase**. No staging. No parallel iOS-only API. |
| Shell | **No Capacitor**, no WebView wrapper. Native SwiftUI only. |
| Spec source | Live web POC + [WEB-SPEC-FOR-IOS.md](./WEB-SPEC-FOR-IOS.md) + Mayday `DIRT-ROUTING-SYSTEM.md` for engine law. |
| ChatGPT / outline docs | **Reference only.** Do not invent features from outlines that are not in code or WEB-SPEC. |
| Ship testing | User tests production web on `main`; iOS tests via device / TestFlight once distributed. |

---

## Project layout (source)

```
Dirt/
  App/            AppEnvironment, RootView (dock + sheets)
  DesignSystem/   DirtTheme
  Features/       Layers, Navigation, Groups, Profile, RoutePlanning
  Map/            MapLibreMapView, MapState, OfflineTileManager
  Location/       LocationService
  Networking/     AppConfig
  Persistence/    SupabaseService, SavedRoute (SwiftData)
  Routing/        RoutingClient, RoutingModels, GeoMath
  DirtApp.swift   @main + ModelContainer
```

Composition root: `Dirt/App/AppEnvironment.swift`.

---

## Starting a new agent on this area

1. Read this overview, then the single area doc you own (`01`–`07`).
2. Read [WEB-SPEC-FOR-IOS.md](./WEB-SPEC-FOR-IOS.md) for the contract you must not invent past.
3. Open the matching Swift files under `Dirt/` before proposing changes.
4. **Invariants:** production base URL only; no Capacitor/WebView; Clean forces Allow off; green CTA only for Start/End nav; one dock tool open at a time.
5. **Open questions:** ASC app record + distribution profile readiness; whether realtime should land before overlay streams; TestFlight cohort size.
