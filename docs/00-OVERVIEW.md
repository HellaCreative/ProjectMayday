# DIRT iOS — Overview

> **Current authority:** Read
> [`ROUTING-SOURCE-OF-TRUTH.md`](ROUTING-SOURCE-OF-TRUTH.md)
> first. Start Navigation, cues, and HUD:
> [`00-NAVIGATION-SOURCE-OF-TRUTH.md`](00-NAVIGATION-SOURCE-OF-TRUTH.md).
> This page is a short technical introduction and does not define current
> routing status or work priority.

Native SwiftUI client for the DIRT dual-sport navigator. Environment isolation is described in `ENVIRONMENTS-AND-RELEASES.md`.

| | |
| --- | --- |
| **Develop here** | `/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt` |
| Working checkout | Use the assigned product checkout; see `AGENTS.md` |
| Agent primer | [../AGENTS.md](../AGENTS.md) |
| Packs + live API | `scripts/pack-fabric/` |

DIRT helps dual-sport riders plot A→B routes with surface-mix control (Clean / Balanced / Dirt + Allow unknown), navigate the line, save/export GPX, and optionally ride with a signed-in group.

TestFlight / signing steps live in [../README_TESTFLIGHT.md](../README_TESTFLIGHT.md).

## Why native iOS

- Background location (nav + group share with screen off)
- Offline graph packs tied to a ride session
- Turn-by-turn HUD that survives lock screen / interruptions
- App Store / TestFlight distribution and OS permissions UX

MapLibre Native renders the map. Current and intended routing-source behaviour,
pack acquisition, fuel construction, and regional policy are defined only in the
canonical routing document. Accounts and groups are Supabase. Non-routing POI delivery is described in `RIDER-SERVICES-FREEZE-2026-09-05.md`.

## Doc index

| Doc | Scope |
| --- | --- |
| [ROUTING-SOURCE-OF-TRUTH.md](ROUTING-SOURCE-OF-TRUTH.md) | Canonical product, routing, source policy, current state, and priority |
| [00-NAVIGATION-SOURCE-OF-TRUTH.md](./00-NAVIGATION-SOURCE-OF-TRUTH.md) | Canonical Start Navigation, Junction/Rally cues, HUD, in-ride waypoints |
| [../AGENTS.md](../AGENTS.md) | New-agent primer (Vercel vs R2, branch) |
| [00-OVERVIEW.md](./00-OVERVIEW.md) | This file |
| [01-STACK.md](./01-STACK.md) | Swift stack, SPM, structure, signing |
| [03-GROUPS.md](./03-GROUPS.md) | Groups, presence |
| [04-PROFILES-AUTH.md](./04-PROFILES-AUTH.md) | Sign in with Apple, session, display name |
| [05-MAPS.md](./05-MAPS.md) | MapLibre, style, route paint, offline tiles |
| [06-UI-DESIGN.md](./06-UI-DESIGN.md) | Tokens, dock, CTAs |
| [07-FUTURE.md](./07-FUTURE.md) | Deferred work + App Store checklist |
| [../README_TESTFLIGHT.md](../README_TESTFLIGHT.md) | Device / archive / TestFlight ops |

## Locked decisions

- Sign in with Apple is the only account path
- Routing decisions and pack policy live only in the canonical routing document.
- Rider Services POIs from OSM, with motorcycle fuel filter
- Network overlay paints the installed pack, not a second CDN
- dirtmoto.app is the marketing / legal site (not a map client)
- **One workspace:** this iOS repo, including `scripts/pack-fabric/`.
