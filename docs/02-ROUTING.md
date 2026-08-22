# DIRT iOS — Routing

> **Supporting implementation reference.** Current product law, source policy,
> release state, and blocker priority are defined in
> [`00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`](00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md).

Client routing behaviour as implemented. While online, use live route, fuel, and
graph services. While offline, use installed `graph.v2` packs through
`OnDeviceRouter`. Never silently substitute one source after the selected source
fails.

The canonical waypoint, derived fuel-stop, rebuild-boundary, and replay contracts
are defined in [`10-ITINERARY-MODEL.md`](10-ITINERARY-MODEL.md).

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
| `Dirt/Features/RoutePlanning/RoutePlannerModel.swift` | Canonical itinerary orchestration, save, nav start, recalculate |
| `Dirt/Features/RoutePlanning/Itinerary/` | Rider intent, reducer, builder, routing-source abstraction |
| `Dirt/Features/RoutePlanning/RoutePlannerCard.swift` | UI |
| `Dirt/Features/Navigation/NavigationSession.swift` | TBT + off-route trigger |
| `Dirt/Persistence/SavedRoute.swift` | SwiftData + GPX export |

---

## Profiles

| UI chip | `RouteProfile` raw value | Guidance (UI) |
| --- | --- | --- |
| Clean | `cleanest` | Pavement-first · urban cores are walls · no unknown access |
| Direct | `direct` | Dirt fabric · follow the A→B line · minimal lateral journey |
| Balanced | `balanced` (default) | Adventure bias · still efficient |
| Dirt | `dirt` | Maximize unpaved · avoid highways |

**Allow unknown access** → `accessPolicy.motorizedUnknown`.

**Product law (enforced in `RouteRequest.init`):** if profile is `.cleanest`, `motorizedUnknown` is forced `false` even when the toggle is on. UI also disables the toggle for Clean (`RoutePlannerCard`).

Vehicle is always `"dual-sport-motorcycle"`. `motorizedPermissive` is always `true`.

---

## Policy (planning)

1. **Online planning** → live `/api/route` and matching live fuel/graph data.
2. **Offline with covering packs** → on-device; two adjacent installed packs can chain.
3. **Offline without covering packs** → actionable “download from PACKS” copy.

Pack download may be initiated manually from PACKS. It is not required to plan
while online. Before navigation participation, Start must prepare the corridor
basemap layers and touched routing packs for offline use; end-to-end verification
of that preparation remains an active acceptance gate.

Live without a pack **must** search the same `graph.v2.bin` PACKS would install. If you rebuild a pack or retune costs, ship both (`scripts/pack-fabric/scripts/ship-routing.js`). Do not leave live on `longhaul.v1.json.gz`.

### Urban-core wall

Every normal profile search treats each recognized urban core as a hard wall. A
stage may use a core when A or B is inside that same core. Clean first seeks a
paved route outside the walls, then permits a rural unpaved connector while the
walls remain intact. Only after both searches prove no route exists may Clean
cross a core. A timeout never relaxes the wall. That last-resort result carries
`urban_core_fallback` in warnings and
`debug.fallback=urban_core_last_resort`. Live and on-device implementations
must remain in lockstep (`hop-search.js` / `UrbanCore.swift`).

Every qualifying OSM city and every major town is a hard urban-core wall. The
shared pack rule currently qualifies cities at 20,000 people and towns at
50,000; a city with missing population is treated conservatively as a core.
Smaller cities/towns use a separate scored avoidance penalty. That makes a comparable
wilderness alternative win without severing rural graph connectivity when the
only through-road crosses town. A route that still crosses a smaller town is labeled
`settlement_fallback`.

Pack overlap does not weaken this policy. Each pack carries overlapping core and
settlement boxes from adjacent packs, intermediate seams keep 5 km of urban
clearance, and edge-segment intersection checks prevent long OSM edges from
crossing a core between two outside graph nodes.

### Corridor selection

Corridors are geographic search envelopes, not route-length budgets. Direct and
Balanced widen only when topology requires it. Dirt compares coherent candidates
inside 50, 100, 150, and 200 km envelopes, works back from 100% dirt, and uses less
pavement then less backward/lateral movement when dirt yield is effectively tied.
Shortest distance is not a selection input for Dirt, Balanced, or Direct.

Widening is lateral permission only. It never multiplies the amount of travel
away from the next pin. Live finite-corridor searches hold fixed forward-progress
guards (Direct 5 km, Balanced 10 km, Dirt 15 km); only the final unbounded
connectivity proof may relax them. This lets Dirt meander across useful side
roads without choosing a loop whose first job is to head in the wrong direction.

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

On-device search is one pack per hop. Two adjacent **installed** packs chain on-device (`CrossPackSeam`). Missing pack + online → live `/api/route` (same R2 files).

Errors surface as `RoutingError.server(message)`.

---

## Modes

### From here

- GPS = A (`LocationService.currentCoordinate`).
- Map tap = B → immediate route.
- Ephemeral: switching back into From here clears destination + response (`modeChanged`).

### Plan a route

- **Long-press** appends stage points (`appendPlanPoint`). Tap does not place points .
- Tapping the painted route inserts a shaping waypoint into that stage; the new
  pin can be dragged and only the affected primary itinerary is rebuilt.
- First point opens a stage with start only; second completes A→B and routes; further points chain from previous end.
- Aggregate distance / dirt% / paved% across stage responses.
- Maneuvers concatenated with along-route offset for nav.

**Per-stage policy (Figma redesign):** each `Stage` owns a `profile` **and** an `allowUnknown` flag. The mode chips edit the selected stage (tap a stage row to select it) or the default for new stages; each stage row has its own Allow-unknown toggle behind the access acknowledgement. The global profile/allow values only seed new stages — changing them never rewrites existing stages.

### Fuel continuity through waypoints

Fuel range is cumulative across the complete rider itinerary. A shaping pin or
ordinary A→via→B boundary does **not** refill the motorcycle. Only A and an
actual packed, route-connected fuel stop reset the tank budget.

Fuel-aware routing is a **forward construction**, never a repair pass over a
disposable A→B route:

1. Online, `/api/fuel-chain` runs one bounded physical-distance Dijkstra from
   the current point and finds every packed pump reachable on eligible graph
   edges within the current usable tank.
2. It ranks only geographically forward pumps, uses bounded graph look-ahead
   to reject dead ends, commits the next pump, and repeats from that pump.
3. The phone then calls `/api/route` only for the committed final legs and
   reveals point 1 → F1 → … → point 2 in order. Candidate count must never
   multiply full Dirt searches.
4. Dirt and Balanced reserve shortest-network headroom inside the hard tank
   ceiling so their final legs can use that distance for adventure routing.
5. Offline, the installed pack performs the equivalent graph reachability
   operation locally.

No generated route between the rider's waypoints is treated as something fuel
planning must preserve. A pump becomes the next waypoint; the following ride
starts from that pump and continues toward the rider's next point. Intentional
cancellation during pin dragging is silent and is never reported as a live
fuel-service outage.

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

This rider-observation layer complements rather than weakens the OSM pack. A
mapped road can still be gated, flooded, seasonally closed, washed out, or
incorrectly tagged in the field. The incident is queued locally when offline,
the matched edge is excluded from the on-device search, and the rider approves
the replacement before navigation changes. Region acceptance therefore tests
both honest OSM eligibility and an offline report → avoid-edge → detour flow.

---

## What works on iOS today

| Capability | Status |
| --- | --- |
| From here A→B | Yes |
| Plan multi-stage chain | Yes (per-stage profile + Allow) |
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
2. **Invariants:** Clean forces Allow off; never gap-span on a client-side sketch; dirt%/paved% vocabulary matches map paint classes. Live and PACKS are the same R2 object.
3. **Open questions:** should mid-trip recalculate preserve plan stages?
