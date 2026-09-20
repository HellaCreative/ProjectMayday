# Place search

Restored on main on September 20, 2026. The earlier implementation was committed
as `23e877b` on `cursor/map-lakes-ferry-attractions-9767`; it was not merged into
main. This restoration brings forward the place-search feature without importing
that branch's unrelated map, attraction, or routing changes.

The magnifying-glass button on the idle map opens place/address search. Typing
at least two characters starts a debounced Apple Maps lookup, using the visible
map region as a hint. It needs an internet connection. Neither queries nor search
results are saved by DIRT. The privacy data map records this external request.

Selecting a result previews its area. Route here uses the existing From here
pack-routing action. Add waypoint opens Plan and appends the coordinate through
the canonical itinerary action. Selecting or dismissing a result alone does not
add a waypoint. Search closes when navigation starts.

The restored presentation uses the shared glass sheet and grouping surfaces,
orange primary action, large touch targets, system text sizing, and reduced-motion
behavior. It includes visible loading, no-results, clear, cancel, retry, and
connection-error states. New queries cancel old MapKit requests; generation checks
also prevent late responses from replacing newer results or returning after close.

Verification: 41 search/planner tests passed, including appending a searched
waypoint without replacing existing pins. The portrait UI flow covers typing,
selection, Add waypoint, clearing, error, empty results, and cancellation.
A live lookup through the same MapKit service returned five valid Porters Lake
results. Evidence lives in `.build/search-restore-20260920`.

Landscape verification is separate: the existing simulator did not rotate during
this run, and the Mac was locked when its UI was inspected. The compact layout is
implemented, but physical-device/rotated-simulator acceptance remains outstanding;
a portrait screenshot must not be counted as landscape evidence.
