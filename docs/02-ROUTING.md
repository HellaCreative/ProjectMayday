# DIRT iOS — Routing

Client routing behaviour as implemented. Prefer on-device `graph.v2` + `OnDeviceRouter` when packs cover the pins; otherwise live `POST AppConfig.routeURL` via `RoutingClient`.

---

## Key files

| File | Role |
| --- | --- |
| `Dirt/Routing/RoutingClient.swift` | Live HTTPS client for `/api/route` |
| `Dirt/Routing/OnDevice/OnDeviceRouter.swift` | Dijkstra + snap on `graph.v2` |
| `scripts/pack-fabric/scripts/stitch-adventure-tips.js` | Pack-time permissive tip → through-road joins |
| `Dirt/Routing/OnDevice/GraphPackStore.swift` | R2 manifest, download, installed packs |
| `Dirt/Routing/RoutingModels.swift` | Profiles, request/response Codable |
| `Dirt/Routing/GeoMath.swift` | Distance / nearest vertex |
| `Dirt/Features/RoutePlanning/RoutePlannerModel.swift` | Modes, stages, save, nav start, recalculate |
| `Dirt/Features/RoutePlanning/RoutePlannerCard.swift` | UI |
| `Dirt/Features/Navigation/NavigationSession.swift` | TBT + off-route trigger |
| `Dirt/Persistence/SavedRoute.swift` | SwiftData + GPX export |

---

## Profiles

| UI chip | `RouteProfile` raw value | Guidance (UI) |
| --- | --- | --- |
| Clean | `cleanest` | Pavement-first · no unknown access |
| Direct | `direct` | Shortest practical · mixed surfaces |
| Balanced | `balanced` (default) | Adventure bias · still efficient |
| Dirt | `dirt` | Maximize unpaved · avoid highways |

**Allow unknown access** → `accessPolicy.motorizedUnknown`.

**Product law (enforced in `RouteRequest.init`):** if profile is `.cleanest`, `motorizedUnknown` is forced `false` even when the toggle is on. UI also disables the toggle for Clean (`RoutePlannerCard`).

Vehicle is always `"dual-sport-motorcycle"`. `motorizedPermissive` is always `true`.

---

## Policy (planning)

1. **Packs cover both pins in one region** → always on-device (even on Wi‑Fi).
2. **Missing pack / cross-province / pin outside pack** + online → live `/api/route`.
3. **Offline without covering packs** → actionable “download from PACKS” copy.

Pack download is **manual** (PACKS sheet). It is not required to drop a pin or plan while you have cell service. Start Nav does not fetch a routing pack.

Live without a pack **must** search the same `graph.v2.bin` PACKS would install. If you rebuild a pack or retune costs, ship both (`scripts/pack-fabric/scripts/ship-routing.js`). Do not leave live on `longhaul.v1.json.gz`.

---

## On-device + live contract

`OnDeviceRouter` searches an installed `graph.v2` pack. The same `RouteRequest` shape posts to live `/api/route`.

Rules:

- Each hop is **exactly two** locations.
- Multi-stage Plan = **one search per stage**.
- Success requires a polyline of at least two points (`RouteResponse.isComplete`).
- Dirt% / paved% come from packed surface codes (or live segment stats).
- `options.avoidEdgeIds` is honored on-device when incident recovery asks for a detour.
- `RouteSegment.edgeId` lets reports match a network edge.

On-device search is one active pack at a time. Cross-province while online uses live canada-chain.

Errors surface as `RoutingError.server(message)`.

---

## Modes

### From here

- GPS = A (`LocationService.currentCoordinate`).
- Map tap = B → immediate route.
- Ephemeral: switching back into From here clears destination + response (`modeChanged`).

### Plan a route

- **Long-press** appends stage points (`appendPlanPoint`). Tap does not place points .
- First point opens a stage with start only; second completes A→B and routes; further points chain from previous end.
- Aggregate distance / dirt% / paved% across stage responses.
- Maneuvers concatenated with along-route offset for nav.

**Per-stage policy (Figma redesign):** each `Stage` owns a `profile` **and** an `allowUnknown` flag. The mode chips edit the selected stage (tap a stage row to select it) or the default for new stages; each stage row has its own Allow-unknown toggle behind the access acknowledgement. The global profile/allow values only seed new stages — changing them never rewrites existing stages.

### Saved

- SwiftData `SavedRoute` (name, profile, coords, distance, dirt%, paved%, createdAt).
- Open → paints as a synthetic complete `RouteResponse` (no maneuvers).
- Delete supported. **GPX import is not implemented** (not in this build).

### Save / Export / Start

CTA matrix in the card: Save (chrome) · Export GPX (`ShareLink`) · Start (nav green). See [06-UI-DESIGN.md](./06-UI-DESIGN.md).

---

## Navigation + recalculate

`startNavigation()` activates `NavigationSession` immediately (coordinates + maneuvers + display segments), hides the primary dock, and starts offline prefetch as best-effort background work. Tile caching never gates the Start action.

While active, the HUD shows:

- Turn cues from route `maneuvers` when a turn is within ~250 m.
- **Surface alerts** (~600 m look-ahead) when the route is about to leave pavement onto gravel/track/access — OSM segment classes standing in for Mapbox `RoadSurface` / route notifications.
- Current surface label on the cue card footer.
- Product copy: adventure profiles **do not avoid unpaved** (on-device costing); Dirt prefers unpaved and penalizes highway spine.

Route completion also toasts the highest-priority on-device routing `warnings` (`unknown_access_used`, `unavoidable_pavement`, …) or a dirt% heads-up.

Off-route: ≥3 samples > 80 m from nearest vertex → `onRerouteNeeded` (cooldown 20s) → `recalculateFromRider()`:

- Rider GPS → preserved destination (From here / last plan end).
- Same profile + Allow policy.
- Offline tiles kept (`keepExisting: true`).
- **Side effect:** sets `mode = .fromHere` and replaces `fromHereResponse` — a multi-stage plan collapses to a single A→B during mid-trip recalculate.

### Incident report + recovery

The nav **REPORT** pill opens `IncidentFlowOverlay` (`RouteIncidents.swift`):

1. **Report what's ahead** — six one-tap categories (access closed / gate / flooded / blocked / unsafe / other). Stored device-local (`dirt_reports_v1`, 14-day freshness), matched to the nearest routed `edgeId` within 150 m when available. Shared persistence is still blocked (no durable store) — reports never claim to sync.
2. **Report logged** — recovery actions, none of which touch the route without confirmation:
   - *Find a way around* — rider → preserved destination with `options.avoidEdgeIds=[reported edge]`, same profile + access policy.
   - *Backtrack* — the existing verified polyline reversed to the last junction maneuver behind the rider. Never a straight line.
   - *Return to nearest verified network* — rider → nearest point on the active route line.
   - *End stage* — ends navigation.
3. **Replace route?** — preview (distance / dirt% / what was avoided) with *Keep current route* / *Apply route*. Failures show: "No verified alternate route found. Backtrack to the last verified junction or end this stage."

---

## What works on iOS today

| Capability | Status |
| --- | --- |
| From here A→B | Yes |
| Plan multi-stage chain | Yes (global profile) |
| Clean / Direct / Balanced / Dirt | Yes |
| Allow unknown + Clean immunity | Yes |
| Aggregate mix bar | Yes |
| Save / Export GPX | Yes |
| Start nav + TBT cues | Yes (maneuvers when present) |
| Off-route recalculate | Yes (collapses plan → from here) |
| Route-to-member | Yes (switches to From here) |

---

## Gaps (client)

| Gap | Notes |
| --- | --- |
| GPX import | Missing |
| Shared incident sync | Blocked on a durable store  — reports are device-local |
| Downstream rejoin labeling | Detours replace the route; automatic rejoin-point detection not implemented (allowed by spec §7) |
| Debug sheet of last N route attempts | Not shipped |
| `options.matchLimitMeters` / `corridorBufferMeters` | Not sent |

---

## Engine law

| Topic | Law / fact |
| --- | --- |
| Engine | On-device Dijkstra on installed packs; live Node A* / canada-chain via `/api/route` |
| Packs | Download from R2 via PACKS (`GraphPackStore`) — required for offline, optional when online |
| Fabric | Adventure = OSM + provincial capillary; Clean = pavement product |
| **No gap-spanning** | Soft-stitch (Allow on, non-Clean) may bridge capillary → giant fabric; **hard ban** on dead-end↔dead-end / island↔island tip joins. Pack-time stitches (`stitch-adventure-tips.js`) join **permissive** track/resource/local tips to through-roads ≤ 150 m — never `motorized_unknown` |
| **dirt% law** | Stats = adventure surfaces vs paved; paint and % must agree |
| **Allow law** | Allow opens `motorized_unknown`; Clean never |
| **Balanced + Allow** | Soft target ~50/50 dirt/paved when fabric allows |

Cost tables live in `scripts/pack-fabric/routing/lib/profile-costs.js` and `OnDeviceProfileCosts.swift`. Keep them in lockstep. Locked map-refinement laws (OSM include, honest Layers, pack stitches, Allow, seams): [08-MAP-REFINEMENT.md](./08-MAP-REFINEMENT.md).

---

## Starting a new agent on this area

1. Read `RoutingModels.swift`, `OnDeviceRouter.swift`, `RoutePlannerModel.swift`, then `NavigationSession.swift`.
2. **Invariants:** Clean forces Allow off; never gap-span on a client-side sketch; dirt%/paved% vocabulary matches map paint classes.
3. **Open questions:** per-stage profile UI; should recalculate preserve plan stages?; when to send `avoidEdgeIds`.
