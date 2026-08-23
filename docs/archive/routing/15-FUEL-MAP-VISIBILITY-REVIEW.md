# DIRT — Fuel Map Visibility Review

> **DECOMMISSIONED:** Historical evidence only. Current authority:
> [`00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`](../../00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md).

> **Implementation evidence.** This records an approved fuel-layer repair and
> its acceptance criteria. Current product authority and work priority are in
> [`00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`](00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md).

Status: approved by rider and implemented; awaiting physical-device validation
Evidence: physical device test on White, 2026-08-21

## Rider-visible failure

With the Fuel Station layer enabled, stations are not spatially stable while
zooming:

- a regional view appears to show a cluster of fuel locations;
- zooming in can make the locations disappear;
- zooming farther can produce a different, seemingly random subset; and
- selecting a generated fuel waypoint reveals alternatives, but those
  alternatives are not visually distinct enough from ordinary fuel markers.

Fuel is safety-critical route information. A pump that is visible at one useful
zoom must not disappear at the next useful zoom merely because the data query
window changed or a refresh was in flight.

## Confirmed implementation causes

1. `POIManager` observes only map centre and zoom. It does not receive the
   actual visible coordinate bounds from MapLibre.
2. At zoom levels below 9, fuel is requested from a fixed 28 km pad around the
   centre. At zoom 9 and above, the pad abruptly drops to 4 km. The requested
   area therefore shrinks from about 56 km wide to about 8 km wide at one zoom
   threshold, regardless of the screen's real visible area.
3. The newly returned viewport response replaces the entire POI source. It is
   not merged with a stable geographic cache.
4. If an online fuel refresh fails, `performRefresh` continues with an empty
   fuel array and publishes it. A transient live-service failure can therefore
   erase pumps that were already visible.
5. The current “cluster” is only visual overlap between individual dots.
   `POIDeduper` merges duplicate fuel records within 55 m, but there is no
   zoom-aware map clustering, cluster count, or stable cluster expansion.
6. General fuel-layer pumps and valid replacement candidates do not have a
   strong state distinction. Replacement candidates are full planner fuel pins
   labelled with a bullet and receive the ordinary selected-pin treatment; they
   do not pulse or carry a candidate halo.

## Proposed behaviour contract

### 1. Fuel coverage follows the visible map

- MapLibre publishes the actual visible coordinate bounds after a settled pan
  or zoom.
- The fuel query uses those bounds plus approximately 20% overscan on each side.
- A new query is required only when the visible map approaches the edge of the
  previously loaded coverage. Zooming within already loaded coverage does not
  discard or refetch the same stations.
- Results are cached by stable geographic cells and merged by station ID. The
  rendered set is the stations intersecting the visible bounds plus overscan.
- Online planning remains live-pack only. Offline use remains installed-pack
  only. This change does not introduce silent fallback and does not modify pack
  data.

### 2. Refreshes never blank proven fuel data

- Keep the last successful fuel paint visible while the next viewport request
  is loading.
- Atomically replace or merge the paint only after a successful response.
- Cancellation from continued map movement is silent and preserves the current
  paint.
- A live-service error preserves the current paint and reports the failure in
  diagnostics; it does not publish an empty station set.
- Turning the Fuel Station layer off intentionally clears or hides it. Moving
  below the supported regional zoom may intentionally hide it, but ordinary
  zooming within the supported range may not.

### 3. Stable zoom hierarchy

Proposed defaults for device validation:

- **Below zoom 6.5:** hide fuel; this view is too broad for actionable station
  decisions.
- **Zoom 6.5–8.5:** show stable orange clusters with a station count.
- **Zoom 8.5–10.5:** split clusters progressively; show smaller clusters and
  isolated pump dots.
- **Zoom 10.5 and above:** show individual pump icons for every station in the
  loaded viewport.

Cluster membership must be deterministic for a fixed camera. Zooming in splits
a cluster into smaller clusters or its constituent pumps; zooming back out
recreates the same cluster. No point should appear to teleport because a
different centre pad was fetched.

### 4. Separate general fuel from route fuel

- **General fuel layer:** orange cluster, dot, or pump icon. Tapping an
  individual pump opens its normal station information.
- **Chosen route fuel waypoint:** the existing prominent `F1`, `F2`, and so on
  teardrop pin. It remains above the general fuel layer.
- **Valid replacement candidate:** a compact pump marker with an expanding
  orange halo. It must not look like another committed `F` waypoint.
- **Invalid/non-forward station during replacement:** remains visible through
  the general fuel layer but is muted and cannot be selected as a replacement.

### 5. Replacement interaction

When the rider taps a committed fuel waypoint:

1. the selected `F` pin lifts and receives the strong selection ring;
2. only graph-valid forward alternatives receive candidate halos;
3. the map keeps ordinary fuel stations visible for geographic context;
4. tapping a halo candidate replaces that fuel waypoint and replans forward;
5. completed upstream route geometry and upstream fuel identities remain
   unchanged; and
6. tapping Cancel or the selected `F` pin again exits replacement mode without
   changing the route.

The candidate animation should pulse, not flicker: approximately a 1.2 second
ease-in/ease-out halo expansion with a restrained opacity change. With Reduce
Motion enabled, show a static double orange ring instead. The marker itself
must remain continuously visible throughout the animation.

## Scope and boundaries

In scope:

- `MapState` visible-bounds state;
- `POIManager` viewport coverage, cache, and error-preserving refresh;
- MapLibre fuel clustering and zoom presentation;
- visual treatment and selection state for replacement candidates; and
- focused diagnostics and automated tests.

Out of scope:

- rebuilding or republishing graph/fuel packs;
- changing fuel eligibility or station filtering;
- changing fuel-chain selection or range physics; and
- restyling campground, lodging, or liquor layers beyond sharing safe viewport
  infrastructure where appropriate.

## Required tests

1. Crossing zoom 9 no longer changes the requested coverage from 56 km to 8 km;
   the request covers the real visible map plus overscan.
2. Zooming 8 → 9 → 10 over a fixed centre never loses a station that remains
   inside the visible bounds.
3. A cancelled or failed live refresh retains the last successful station set.
4. Panning within cached coverage performs no duplicate network request.
5. Leaving cached coverage fetches the missing cells and merges by station ID.
6. A fixed camera produces deterministic cluster IDs and counts.
7. Cluster expansion reveals the same constituent station IDs at closer zoom.
8. Tapping `F1` exposes only graph-valid alternatives as pulsing candidates.
9. Tapping a candidate records the selected station override and preserves all
   upstream built legs.
10. Reduce Motion replaces animation with a static, equally legible candidate
    treatment.
11. Turning the Fuel Station layer off removes the general fuel paint without
    removing committed route fuel waypoints.
12. Online requests remain live-only and offline requests remain installed-only.

## Approved decision

The rider approved:

- the zoom bands above;
- 20% viewport overscan;
- clusters with counts at regional zoom;
- individual pumps from zoom 10.5 upward; and
- pulsing candidate halos with a static Reduce Motion alternative.

Approved by the rider on 2026-08-22.

## Implementation checkpoint

Implemented without pack or routing-behaviour changes:

- MapLibre now publishes its real visible coordinate bounds.
- Fuel coverage uses those bounds with 20% overscan and a source-specific
  geographic cache.
- Cancelled or failed same-source live refreshes preserve the last successful
  fuel paint.
- Regional fuel is rendered as deterministic MapLibre clusters with counts;
  cluster taps zoom toward the constituent pumps.
- Close zoom renders individual pumps.
- Committed `F` pins remain route pins. Valid alternatives are compact pump
  badges with a pulsing orange halo, or a static double ring with Reduce Motion.
- Ordinary fuel paint is muted during replacement mode, and tapping the
  selected `F` pin again exits without changing the route.
- Focused simulator build and regression tests pass. Physical validation on
  White remains required for zoom continuity and candidate legibility.
