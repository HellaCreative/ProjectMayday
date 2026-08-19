# DIRT iOS — Overview

Native SwiftUI client for the DIRT dual-sport navigator. No staging.

| | |
| --- | --- |
| iOS repo | `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt` |
| Local branch | `main` |

DIRT helps dual-sport riders plot A→B routes with surface-mix control (Clean / Direct / Balanced / Dirt + Allow unknown), navigate the line, save/export GPX, and optionally ride with a signed-in group.

TestFlight / signing steps live in [../README_TESTFLIGHT.md](../README_TESTFLIGHT.md).

## Why native iOS

- Background location (nav + group share with screen off)
- Offline graph packs tied to a ride session
- Turn-by-turn HUD that survives lock screen / interruptions
- App Store / TestFlight distribution and OS permissions UX

MapLibre Native renders the map. Routing prefers on-device `graph.v2` packs from Cloudflare R2 when installed; live `POST /api/route` covers pins outside those packs (and cross-province hops). Accounts and groups are Supabase. POIs come from OSM Overpass.

## Doc index

| Doc | Scope |
| --- | --- |
| [00-OVERVIEW.md](./00-OVERVIEW.md) | This file |
| [01-STACK.md](./01-STACK.md) | Swift stack, SPM, structure, signing |
| [02-ROUTING.md](./02-ROUTING.md) | Client models, on-device packs, profiles |
| [03-GROUPS.md](./03-GROUPS.md) | Groups, presence |
| [04-PROFILES-AUTH.md](./04-PROFILES-AUTH.md) | Sign in with Apple, session, display name |
| [05-MAPS.md](./05-MAPS.md) | MapLibre, style, route paint, offline tiles |
| [06-UI-DESIGN.md](./06-UI-DESIGN.md) | Tokens, dock, CTAs |
| [07-FUTURE.md](./07-FUTURE.md) | Deferred work + App Store checklist |
| [08-MAP-REFINEMENT.md](./08-MAP-REFINEMENT.md) | OSM / Layers / stitches / costs / seams (locked) |
| [../README_TESTFLIGHT.md](../README_TESTFLIGHT.md) | Device / archive / TestFlight ops |

## Locked decisions

- Sign in with Apple is the only account path
- Routing: on-device packs when downloaded; live `/api/route` when online without that pack. **Same R2 `graph.v2.bin`.** Ship live + download together (`scripts/pack-fabric/scripts/ship-routing.js`).
- Rider Services POIs from OSM, with motorcycle fuel filter
- Network overlay paints the installed pack, not a second CDN
- dirtmoto.app is the marketing / legal site (not a map client)
