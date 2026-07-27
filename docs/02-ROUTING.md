# DIRT iOS — Routing

Client routing behaviour as implemented, plus the server-side law an agent must respect. Spec contract: [WEB-SPEC-FOR-IOS.md](./WEB-SPEC-FOR-IOS.md) §3. Engine law (web repo): `DIRT-ROUTING-SYSTEM.md`.

---

## Key files

| File | Role |
| --- | --- |
| `Dirt/Routing/RoutingClient.swift` | `POST` client |
| `Dirt/Routing/RoutingModels.swift` | Profiles, request/response Codable |
| `Dirt/Routing/GeoMath.swift` | Distance / nearest vertex |
| `Dirt/Features/RoutePlanning/RoutePlannerModel.swift` | Modes, stages, save, nav start, recalculate |
| `Dirt/Features/RoutePlanning/RoutePlannerCard.swift` | UI |
| `Dirt/Features/Navigation/NavigationSession.swift` | TBT + off-route trigger |
| `Dirt/Persistence/SavedRoute.swift` | SwiftData + GPX export |

---

## Profiles (UI → API)

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

## API contract (client)

`RoutingClient.route(_:)` POSTs JSON to `AppConfig.routeURL` with 60s timeout.

Request shape (matches web):

```json
{
  "profile": "balanced",
  "locations": [
    { "lat": 44.65, "lon": -63.57, "label": "A" },
    { "lat": 44.88, "lon": -63.20, "label": "B" }
  ],
  "vehicle": "dual-sport-motorcycle",
  "accessPolicy": {
    "motorizedPermissive": true,
    "motorizedUnknown": false
  }
}
```

Rules:

- Client always sends **exactly two** locations per POST.
- Multi-stage Plan = **one POST per stage**.
- Success requires `status == "complete"` (`RouteResponse.isComplete`).
- Decodes `geometry` as `[lon, lat]` pairs; uses `stats.dirtPercent` / `pavedPercent` (with top-level fallbacks).

Errors surface as `RoutingError.server(message)` from `message` / `error` fields.

iOS now sends `options.avoidEdgeIds` (server-enforced avoidance) when the incident recovery flow requests a detour; requests without avoidance omit `options` entirely and stay byte-for-byte identical to the legacy shape (covered by `routeRequestUsesCanonicalBackendShape`). Other optional web fields (`options.matchLimitMeters`, `corridorBufferMeters`) are still not sent. `RouteSegment` also decodes `edgeId` so reports can be matched to a network edge.

---

## Modes (ported from web)

### From here

- GPS = A (`LocationService.currentCoordinate`).
- Map tap = B → immediate route.
- Ephemeral: switching back into From here clears destination + response (`modeChanged`).

### Plan a route

- **Long-press** appends stage points (`appendPlanPoint`). Tap does not place points (web parity).
- First point opens a stage with start only; second completes A→B and routes; further points chain from previous end.
- Aggregate distance / dirt% / paved% across stage responses.
- Maneuvers concatenated with along-route offset for nav.

**Per-stage policy (Figma redesign):** each `Stage` owns a `profile` **and** an `allowUnknown` flag. The mode chips edit the selected stage (tap a stage row to select it) or the default for new stages; each stage row has its own Allow-unknown toggle behind the access acknowledgement. The global profile/allow values only seed new stages — changing them never rewrites existing stages.

### Saved

- SwiftData `SavedRoute` (name, profile, coords, distance, dirt%, paved%, createdAt).
- Open → paints as a synthetic complete `RouteResponse` (no maneuvers).
- Delete supported. **GPX import is not implemented** (web has it).

### Save / Export / Start

CTA matrix in the card: Save (chrome) · Export GPX (`ShareLink`) · Start (nav green). See [06-UI-DESIGN.md](./06-UI-DESIGN.md).

---

## Navigation + recalculate

`startNavigation()` activates `NavigationSession` immediately (coordinates + maneuvers + display segments), hides the primary dock, and starts offline prefetch as best-effort background work. Tile caching never gates the Start action.

While active, the HUD shows:

- Turn cues from server `maneuvers` when a turn is within ~250 m.
- **Surface alerts** (~600 m look-ahead) when the route is about to leave pavement onto gravel/track/access — OSM segment classes standing in for Mapbox `RoadSurface` / route notifications.
- Current surface label on the cue card footer.
- Product copy: adventure profiles **do not avoid unpaved** (server costing); Dirt prefers unpaved and penalizes highway spine.

Route completion also toasts the highest-priority `/api/route` `warnings` (`unknown_access_used`, `unavoidable_pavement`, …) or a dirt% heads-up.

Off-route: ≥3 samples > 80 m from nearest vertex → `onRerouteNeeded` (cooldown 20s) → `recalculateFromRider()`:

- Rider GPS → preserved destination (From here / last plan end).
- Same profile + Allow policy.
- Offline tiles kept (`keepExisting: true`).
- **Side effect:** sets `mode = .fromHere` and replaces `fromHereResponse` — a multi-stage plan collapses to a single A→B during mid-trip recalculate.

### Incident report + recovery (web ROUTE-INCIDENT-RECOVERY parity)

The nav **REPORT** pill opens `IncidentFlowOverlay` (`RouteIncidents.swift`):

1. **Report what's ahead** — six one-tap categories (access closed / gate / flooded / blocked / unsafe / other). Stored device-local (`dirt_reports_v1`, 14-day freshness), matched to the nearest routed `edgeId` within 150 m when available. Shared persistence is still blocked (no durable store) — reports never claim to sync.
2. **Report logged** — recovery actions, none of which touch the route without confirmation:
   - *Find a way around* — rider → preserved destination with `options.avoidEdgeIds=[reported edge]` (server-enforced), same profile + access policy.
   - *Backtrack* — the existing verified polyline reversed to the last junction maneuver behind the rider. Never a straight line.
   - *Return to nearest verified network* — rider → nearest point on the active route line.
   - *End stage* — ends navigation.
3. **Replace route?** — preview (distance / dirt% / what was avoided) with *Keep current route* / *Apply route*. Failures show the web copy: "No verified alternate route found. Backtrack to the last verified junction or end this stage."

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
| Start nav + TBT cues | Yes (server maneuvers when present) |
| Off-route recalculate | Yes (collapses plan → from here) |
| Route-to-member | Yes (switches to From here) |

---

## Gaps (client)

| Gap | Notes |
| --- | --- |
| GPX import | Missing |
| Shared incident sync | Blocked on a durable store (web parity) — reports are device-local |
| Downstream rejoin labeling | Detours replace the route; automatic rejoin-point detection not implemented (allowed by spec §7) |
| Debug sheet of last N route attempts | Web only |
| `options.matchLimitMeters` / `corridorBufferMeters` | Not sent |

---

## Server-side context agents need

Do **not** reimplement the engine on device for v1. When debugging bad routes, read the Mayday web repo:

| Topic | Law / fact |
| --- | --- |
| Engine | Node A* on prebuilt regional packs via `POST /api/route` |
| Province packs | NS, NB, QC, PE, ON, MB, SK, AB, BC longhaul gz under `routing/data/regions/` |
| Fabric | Adventure = OSM white + provincial capillary; Clean = pavement product |
| **No NRN in adventure packs** | Health note on `GET /api/route`: NS OSM+NSTDB, NB OSM+Forest Roads, … “No NRN in adventure packs.” NS/NB gold have no NRN; older comments elsewhere may still mention NRN — trust the health note + `DIRT-ROUTING-SYSTEM.md` |
| **No gap-spanning** | Soft-stitch (Allow on, non-Clean) may bridge capillary → giant fabric; **hard ban** on dead-end↔dead-end / island↔island tip joins (invented gray connectors) |
| **dirt% law** | Stats = adventure surfaces (gravel/access/track/…) vs paved; paint and % must agree |
| **Allow law** | Allow opens `motorized_unknown`; Clean never |
| **Balanced + Allow** | Soft target ~50/50 dirt/paved when fabric allows |
| canada-chain | Cross-province long hauls may hop packs server-side; client still sends one A/B pair |
| Longhaul purple | Capillary availability varies by province pack size — Allow on may behave differently west of NS/NB |

Cost tables live in Mayday `routing/lib/profile-costs.js`. Changing iOS cannot fix profile law bugs.

---

## Starting a new agent on this area

1. Read `RoutingModels.swift`, `RoutingClient.swift`, `RoutePlannerModel.swift`, then `NavigationSession.swift`.
2. Cross-check request/response with [WEB-SPEC-FOR-IOS.md](./WEB-SPEC-FOR-IOS.md) §3.
3. For engine behaviour, open Mayday `DIRT-ROUTING-SYSTEM.md` — do not invent profile meanings.
4. **Invariants:** two locations per POST; Clean forces Allow off; never gap-span on a client-side sketch; dirt%/paved% vocabulary matches map paint classes; production URL only.
5. **Open questions:** per-stage profile UI worth it before overlays?; should recalculate preserve plan stages?; when to send `avoidEdgeIds`.
