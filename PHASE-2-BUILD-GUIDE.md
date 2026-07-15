# DIRT. MAYDAY. Phase Two Build Guide

## Purpose

Phase Two turns the current Nova Scotia routing proof of concept into a rally-oriented trip planner and navigation product.

The central design decision is:

> The browser displays the basemap, the planned route, and a small amount of nearby riding context. A routing service owns the full routable network and performs the graph search.

The rider should be able to plan a trip across Nova Scotia, divide it into stages, choose a route character, save the route, and navigate one active stage with clear rally-style guidance.

This document is the implementation handoff for Cursor.

## Current Baseline

The current repository is `/Users/richardsmith/SandBox01/Mayday`.

The current `main` branch contains:

- The HRM pilot routing work from commit `46d4efe`.
- A later province-wide NSTDB build from commit `5fc0e04`.
- A later chunking build from commit `6fdb355`.
- The current navigation work through commit `e5d91a1`.
- Phase 2A eligibility and schema work through commit `3f3ab5f`.
- Phase 2A preflight (unknown-access default off, ramps restored, guide committed) through `8177232`.
- A Nova Scotia manifest with 301,635 eligible production edges in 76 chunks (`schemaVersion` `2a-2`).

The current implementation is useful as a visual and interaction reference, but it should not remain the production routing architecture.

Known current limitations:

- The browser builds a graph from loaded GeoJSON.
- Loaded chunks are retained and are not evicted.
- Browser can enforce access policy for demos, but Phase 2B must enforce the same policies in the routing service.
- Route profiles use client-side multipliers rather than calibrated route objectives.
- Cleanest still calls public OSRM separately.
- Long-distance routing can load too much data and exceed mobile memory.
- The UI has navigation features but not yet a full trip/stage/roadbook model.

## Product Model

Use this hierarchy everywhere in the application:

```text
Trip
  -> Stage
       -> Route
            -> Navigation
```

### Trip

A trip is the complete journey. It may cross provinces and may contain many stages.

Trip-level data includes:

- Name
- Overall start and destination
- Ordered stage list
- Total distance and estimated riding time
- Total dirt percentage
- Fuel and service plan
- Saved route versions

### Stage

A stage is one rideable leg. It may represent one day, one fuel interval, or one rally section.

Stage-level data includes:

- Start and end waypoint
- Optional intermediate waypoints
- Route profile
- Distance
- Estimated moving time
- Estimated elapsed time
- Dirt and pavement percentages
- Fuel/service/camping waypoints
- Access and data-confidence warnings
- Offline availability status

### Route

A route is the engine's selected path for a stage. It is returned as a compact geometry plus segment metadata.

### Navigation

Navigation is the active-stage experience. It should only need the current route, route cues, basemap tiles, and a small moving window of nearby eligible network context.

## Non-Negotiable Rules

1. Never create long free-space route connectors.
2. Never route across a visual crossing unless the graph has a valid junction there.
3. Never route a feature explicitly marked `No Vehicular Traffic`.
4. Do not classify non-motorized recreation trails as single track for motorcycle routing.
5. Do not silently substitute an unrelated highway route for a requested dirt route.
6. Do not load the entire province or country into the browser for normal planning.
7. Do not make the rider inspect millions of raw lines to create a route.
8. Every route segment must retain source, surface, access, and confidence metadata.
9. Every fallback, exclusion, snap, or partial result must be visible to the user.
10. The route shown to the rider must be the route the navigation engine actually uses.

## Data Eligibility

### Exclude from the production pack

The following features must not be included in the production routable/display pack:

- `No Vehicular Traffic`
- Pedestrian-only trails
- Bicycle-only trails
- Hiking paths
- Private or explicitly closed roads
- Railways, ferries, driveways, and service artifacts unless deliberately supported by the routing model
- Geometry with no usable line coordinates

**Ramps:** included by design as `motorized_permissive` paved edges for highway continuity. They are not a display-priority dirt layer; they paint with paved surface.

**TRAIL vs TRACK:** excluding `TRAIL` / `No Vehicular Traffic` does **not** remove `TRACK`. TRACK remains in the pack as `surfaceClass=track` with `accessClass=motorized_unknown` until verified.

The raw source archive may be kept outside the application bundle for audit and future classification work. It must not be loaded by the normal map or routing client.

### Access classes

Use an explicit access field rather than assuming that every government line is legal for motorcycles.

Recommended values:

- `motorized_verified`
- `motorized_permissive`
- `motorized_unknown`
- `motorized_restricted`
- `motorized_excluded`

Default routing should use verified and permissive edges only. Unknown access may be offered through an explicit advanced option later, but it must never be silently treated as safe or legal.

### Routing policy versus map visibility

Access controls are routing-policy controls. They determine which edges the route engine may use and must be saved with each stage.

The production default is:

- `motorized_permissive`: enabled
- `motorized_unknown`: disabled
- `motorized_restricted`: never routable by default

When `motorized_unknown` is enabled, the rider must receive an explicit warning before calculation. The route result must show the distance and percentage of unknown-access edges and save the choice with the stage. The warning must say that unknown access is not permission and may expose the rider to closures, private land, seasonal restrictions, or enforcement.

Do not use the same switch for route eligibility and map visibility. A rider may want to hide nearby context while still allowing the route engine to use an access class, or inspect nearby context without changing the route.

The route request must include the stage access policy, for example:

```json
{
  "accessPolicy": {
    "motorizedPermissive": true,
    "motorizedUnknown": false
  }
}
```

### Separate surface from structure

Do not use one mutually exclusive field for every visual and routing concept.

Each edge should carry separate attributes:

```json
{
  "edgeId": "ns-gov-12345",
  "surfaceClass": "paved|gravel|access|track|single|unknown",
  "structureType": "none|bridge|tunnel|ford",
  "accessClass": "motorized_verified",
  "source": "ns-gov",
  "sourceDescription": "ROAD - Resource Access - Dry Weather",
  "confidence": "high|medium|low",
  "seasonal": false,
  "distanceMeters": 842,
  "geometry": [[-63.1, 44.7], [-63.09, 44.71]]
}
```

This prevents a paved bridge from being treated differently from a paved road merely because it is a bridge, while preserving bridge information for display and navigation.

## Topology Preparation

Topology is prepared offline before data is exposed to the application.

### Required graph rules

- Preserve sufficient coordinate precision during source normalization.
- Split lines at shared endpoints and shared interior vertices.
- Detect geometric line crossings where the source contains no shared vertex.
- Split a true same-level crossing into a junction.
- Preserve grade separation for bridges, tunnels, ramps, and overpasses.
- Do not connect lines merely because they are close.
- Leave genuine dead ends as dead ends.
- Assign stable node IDs and edge IDs.
- Assign connected-component IDs.
- Validate that every edge geometry starts and ends on its declared nodes.

The current packer rounds coordinates to five decimals and only splits shared coordinate vertices. That is a useful interim step, but it is not a complete planarization pass. The next packer must produce a topology report containing:

- Total nodes
- Total edges
- Same-level junctions
- Grade-separated crossings
- Dead ends
- Connected components
- Excluded features by reason
- Edges with unknown access
- Intersections found but intentionally not connected

### Graph output

The production build should emit a compact graph or routing-engine tile set, not only display GeoJSON.

The browser may receive simplified display geometry, but routing geometry and routing attributes must remain in the routing service or offline graph store.

## Routing Engine

The preferred architecture is a persistent routing service backed by tiled regional graph data.

Valhalla is the first engine to evaluate because it supports tiled graphs, runtime costing, edge attributes, map matching, and maneuver generation. Its documentation describes dynamic costing over one graph and hierarchical tiles:

- https://valhalla.github.io/valhalla/sif/dynamic-costing/
- https://valhalla.github.io/valhalla/tiles/
- https://valhalla.github.io/valhalla/api/turn-by-turn/api-reference/

GraphHopper may be evaluated as an alternative, but the first implementation should prove one engine end to end before splitting effort between engines.

Vercel should host the web application and a thin API proxy. The large graph should not be loaded into a Vercel serverless function on every request. Use a persistent routing service or a separately hosted routing worker with warm regional data.

## Route Profiles

The four visible profile names remain:

- Direct
- Balanced
- Dirt
- Cleanest

These must be defined as documented objectives rather than unexplained numeric multipliers.

### Direct

Shortest valid route by distance over all eligible surfaces.

Surface should not be penalized except for explicit access, safety, seasonal, or vehicle restrictions.

### Balanced

A practical compromise between distance/time and dirt content.

The response must report the actual result. Balanced must not promise exactly 50/50 unless the engine can enforce that constraint.

### Dirt

Maximize eligible dirt and track content while allowing the minimum necessary paved connection.

The engine should prefer a longer dirt route over a shorter paved route when that tradeoff is intentional. It must report unavoidable paved distance and explain when a dirt-only connection does not exist.

### Cleanest

Prefer paved, maintained, and efficient roads.

This should eventually use the same unified graph with a paved-preferred cost profile. OSRM may remain temporarily for comparison, but it should not be the permanent definition of Cleanest because it creates a second routing system and a separate data model.

## Route API Contract

The frontend should call one route endpoint for all four profiles.

Example request:

```json
{
  "tripId": "trip-123",
  "stageId": "stage-02",
  "profile": "dirt",
  "locations": [
    {"lat": 44.74, "lon": -63.30, "label": "A"},
    {"lat": 45.20, "lon": -61.15, "label": "B"}
  ],
  "vehicle": "dual-sport-motorcycle",
  "accessPolicy": {
    "motorizedPermissive": true,
    "motorizedUnknown": false
  },
  "options": {
    "includeNearbyContext": false
  }
}
```

Example response:

```json
{
  "routeId": "route-123",
  "profile": "dirt",
  "status": "complete",
  "geometry": [[-63.30, 44.74], [-63.29, 44.75]],
  "distanceMeters": 39800,
  "estimatedMovingSeconds": 7200,
  "estimatedElapsedSeconds": 9000,
  "stats": {
    "pavedPercent": 18,
    "gravelPercent": 31,
    "accessPercent": 38,
    "trackPercent": 13,
    "singlePercent": 0
  },
  "segments": [
    {
      "edgeId": "ns-gov-12345",
      "surfaceClass": "access",
      "structureType": "none",
      "source": "ns-gov",
      "distanceMeters": 842,
      "geometry": [[-63.1, 44.7], [-63.09, 44.71]]
    }
  ],
  "maneuvers": [],
  "warnings": [],
  "debug": {
    "startMatchedEdge": "ns-gov-100",
    "endMatchedEdge": "ns-gov-900",
    "startAccessMeters": 34,
    "endAccessMeters": 12,
    "componentId": "ns-main",
    "fallback": null
  }
}
```

The route response must contain enough information for the frontend to render the route, build a roadbook, export GPX, and navigate without loading the full routing graph.

## Browser Data Loading

### Trip overview

Load:

- Daylight basemap tiles
- Cities, roads, services, and labels from the basemap
- Stage waypoints
- Selected route geometry only

Do not load the raw trail network by default.

The overview legend should focus on route eligibility and trip information, not raw-line visibility. It may show which access policy is active for the selected stage.

### Stage planning

Load:

- Selected route geometry
- Stage boundaries
- Fuel, camping, lodging, food, repair, and emergency waypoints
- Optional limited route corridor context

### Navigation detail

Load:

- Active stage route
- Basemap tiles around the rider
- Nearby eligible network context
- A small forward-looking context window

The nearby network should be visually subordinate to the selected route. The route is the primary navigation object; nearby tracks exist for orientation and junction awareness.

Nearby context is controlled by a separate navigation-view switch such as `Nearby tracks`. This switch changes visibility only. It must not change the route or the stage access policy.

### Moving context window

Use a moving corridor around the rider rather than loading an entire stage.

Recommended initial behavior:

- Keep the current rider area loaded.
- Prefetch several kilometres ahead based on heading and speed.
- Keep a smaller buffer behind the rider for recovery and wrong-turn awareness.
- Evict context that is outside the active window.
- Keep the active route geometry and route metadata available for the whole stage.
- Keep nearby context limited to eligible motorized lines unless the rider explicitly enables an advanced unverified-context view.

The current 0.4 degree chunks are too coarse for this purpose. Use smaller display tiles or a corridor endpoint that returns only nearby context.

## Visual and Interaction Design

Do a UX and information-architecture pass now. Defer final cosmetic polish until the new route API and stage states exist.

### Planning screen

The first screen should show the usable map, not a marketing page and not a dense trail viewer.

Primary controls:

- Create trip
- Add stage
- Add waypoint
- Choose profile
- Calculate route
- Save stage

### Route result card

Show:

- Profile name
- Distance
- Estimated moving time
- Estimated elapsed time
- Dirt percentage
- Surface breakdown
- Fuel gap
- Access confidence
- Route warnings
- Save stage
- Start navigation

### Optional Explore Network mode

This is an inspection mode, not the default planning experience.

When enabled, show only the nearby eligible network around the map viewport. Keep restricted/non-motorized geometry absent from the production experience. Use this mode for data QA and advanced users who want local context.

In normal navigation, this becomes a small `Nearby tracks` control. It should show tracks on both sides of the active route and several kilometres ahead of the rider. It should not reveal the entire province-wide network.

### Navigation screen

The current rally-oriented features should be retained and extended:

- Heading-up map
- Follow camera
- 2D/3D toggle
- PiP overview/detail map
- Spoken cues
- Junction-only or all-bends cue mode
- Wrong-way detection
- Off-route state
- Surface-change warnings
- Stage progress
- Remaining distance and time
- Next fuel/service/camping point

The existing bend and junction cues are geometric. Later, use graph-generated maneuvers and road names where available, while retaining rally numbers for bush riding.

## Rally Roadbook Model

Each stage should generate a roadbook from the route response.

Each roadbook item may include:

- Distance from stage start
- Cumulative distance
- Direction or rally number
- Junction or bend classification
- Surface transition
- Road or track name
- Warning or access note
- Waypoint category
- Optional voice narration

The rider should be able to switch between:

- Map navigation
- Roadbook list
- Stage overview
- Trip overview

## Long-Distance and Canada Scaling

Never route a full Canada trip by loading Canada into a browser.

Use two levels of routing:

1. A coarse national backbone for interprovincial planning.
2. Detailed provincial or regional graphs for stage routing.

For a Nova Scotia to British Columbia trip:

- Plan the broad trip on the national backbone.
- Create or suggest province-boundary stages.
- Route dirt-rich detail only within the active province/region corridor.
- Keep the next stage available for prefetch.
- Unload completed regions from active memory.
- Preserve saved route geometry and metadata, not raw graph data.

This architecture supports a long road stage, a dirt-heavy adventure stage, and a multi-week cross-Canada trip without requiring one device to hold the country-wide graph.

## Time, Fuel, and Stage Planning

Distance alone is not enough for an eight-hour dual-sport stage.

The routing engine should eventually estimate time using class-specific speeds and penalties:

- Highway and paved local roads
- Gravel roads
- Resource access roads
- Rough tracks
- Single track, when eligible
- Stops, fuel, border crossings, ferries, and waypoints

Every time estimate should be labelled as an estimate. Do not present it as a guaranteed arrival time.

The planner should support:

- Maximum riding hours per stage
- Maximum distance per fuel interval
- Planned fuel range
- Overnight stop
- Emergency exit or bailout route
- Stage start and end time
- Rest and service stops

## Offline Navigation

Offline support should be stage-based.

Before navigation begins, download:

- Active stage route geometry
- Active stage maneuver data
- Basemap tiles for the route corridor
- Nearby eligible network context for the expected riding window
- Fuel, service, camping, and emergency waypoints

Do not advertise a stage as offline-ready until all required assets have been verified locally.

The current implementation caps basemap prefetch at 700 tiles and clears the basemap cache when navigation ends. Replace that with an explicit stage download status and a user-controlled retained offline stage cache.

## Implementation Phases

### Phase 2A: Eligibility and source packing

Acceptance criteria:

- Non-motorized trails are excluded from the production pack.
- Access status exists on every routable edge.
- Surface and structure are separate fields.
- Source provenance is retained.
- Topology report is generated.
- No free-space connectors are emitted.

### Phase 2B: Offline graph and route service

Acceptance criteria:

- Nova Scotia graph is built outside the browser.
- Route requests use one service for all four profiles.
- Direct, Balanced, Dirt, and Cleanest have documented objectives.
- The service returns route geometry, segments, stats, warnings, and maneuvers.
- Each request accepts a stage-specific access policy.
- Unknown-access routing is opt-in, warned, measured, and saved with the stage.
- Restricted and excluded edges cannot be enabled through the normal rider UI.
- Long Nova Scotia routes do not require the browser to load the full graph.

### Phase 2C: Trip and stage UI

Acceptance criteria:

- A trip can contain multiple stages.
- Waypoints can be added, named, reordered, and removed.
- The overview shows route and stages without raw network clutter.
- Route results show distance, time, surface mix, access confidence, and warnings.

### Phase 2D: Context-aware map loading

Acceptance criteria:

- Overview mode does not load raw trail context.
- Navigation mode loads nearby eligible context only.
- `Nearby tracks` changes visibility only and never changes route eligibility.
- Context prefetch follows the rider and heading.
- Old context is evicted.
- The active route remains available throughout the stage.

### Phase 2E: Rally navigation and offline stages

Acceptance criteria:

- Stage can be downloaded and verified offline.
- PiP overview/detail behavior remains available.
- Roadbook cues are generated from route metadata.
- Surface changes are announced.
- Off-route state is clear and actionable.
- The system distinguishes reroute, return-to-route, and route-aborted states.

### Phase 2F: Canada expansion

Acceptance criteria:

- Provincial adapters normalize into the common edge schema.
- Province and region packs can be added without changing frontend logic.
- Cross-boundary routing works on the national backbone.
- Detailed dirt routing can be requested within a regional corridor.
- Active memory remains bounded while planning and navigating.

## Testing Requirements

### Data tests

- No `No Vehicular Traffic` feature appears in the production pack.
- Every routable edge has an access class.
- Every route edge is traceable to source data.
- No route geometry contains a free-space connector.
- Same-level intersections are connected.
- Bridges and tunnels do not create false same-level junctions.
- Dead ends remain dead ends.

### Route fixtures

Keep fixed fixtures for:

- Porter's Lake to Musquodoboit Harbour
- Halifax/HRM to Yarmouth
- A dirt-heavy Nova Scotia route
- A paved-only route
- A route with a required paved connector
- A disconnected or excluded destination
- A start point away from the network
- A stage crossing a data chunk boundary

### Browser tests

- Planning a long route does not reload the page.
- Overview mode does not fetch the raw network.
- Turning `Nearby tracks` on or off does not change the calculated route.
- Turning `motorized_unknown` on or off changes route eligibility and produces a visible policy summary.
- Unknown-access routes require acknowledgement and show unknown-access distance.
- Navigation context appears near the rider and disappears after leaving the window.
- Route remains visible when raw context is unavailable.
- Offline stage assets are verified before navigation begins.
- iPhone Safari memory remains stable while moving through multiple regions.

### Deployment verification

Follow the existing workflow:

```text
local files -> Git commit -> GitHub main -> Vercel deployment -> Vercel preview verification
```

Do not use a local server for product preview. Verify through the Vercel preview deployment. Use browser checks for console errors, route requests, long routes, source loading, mobile layout, and offline stage behavior.

## Cursor Handoff Rules

- Read this guide, `ROUTING.md`, `SOURCES.md`, and `INTEGRATION.md` before implementation.
- Preserve the raw source archive outside the production app bundle.
- Do not reintroduce proximity stitching or silent OSRM fallback.
- Do not load the full graph into the browser.
- Do not make the raw network visible by default.
- Keep the basemap bright, high contrast, and readable in daylight.
- Keep the selected route visually dominant over nearby context.
- Build and verify incrementally through Vercel previews.
- Keep data-build commits separate from frontend commits where practical.
- Include route debug information in development builds.
- Do not claim a route is legal or offline-ready without evidence.

## Definition of Done

Phase Two is complete when a rider can:

1. Create a trip.
2. Add multiple stages and waypoints.
3. Request Direct, Balanced, Dirt, or Cleanest routing.
4. See the selected route without a dense raw network overlay.
5. Inspect nearby eligible tracks while navigating.
6. Choose an access policy for each stage.
7. Understand distance, time, dirt percentage, fuel gaps, and access warnings.
8. Download the active stage for offline use.
9. Navigate with rally-style cues and a PiP overview.
10. Complete a long Nova Scotia route without a browser crash.
11. Extend the same architecture to another Canadian province.
