# DIRT routing replacement: product specification

Review draft, 8 September 2026. Consolidates Richard's discovery decisions in [the workbook](ROUTING-REBUILD-WORKBOOK-2026-09-08.md). This supersedes conflicting historical intent for this proposed replacement, but does not declare the deployed engine changed or qualified. Engineering proposals are identified below.

## 1. The product

Build a connected adventure matching the requested riding style, through the rider's required places, with fuel considered throughout selection. A shortest legal connection is useful search information, not the product objective. Long riding is not intrinsically bad. Artificial repetitions and token dirt excursions are bad.

| Flow | Inputs and outcome |
| --- | --- |
| From Here: Build a Route | Current location and one destination. DIRT builds the adventure and fuel stops. |
| Plan a Route | Ordered rider waypoints, with riding style per primary leg. DIRT builds the connecting adventures and fuel stops. |
| Loop | Start/return location, preferred exploration direction and approximate distance or riding time. First visit a fuel station, then ride the adventure and return to the original start, adding fuel where needed. |

Loop is in the intended first replacement release. Live routing comes before later app/offline delivery. Explicit time/distance inputs for the other two flows are not yet agreed; do not introduce a hidden user-facing detour cap.

## 2. Anchors and ownership

- Rider waypoints are fixed unless the rider moves/removes them. Each adjacent pair defines a primary leg.
- A rider waypoint at an actual reachable fuel station explicitly includes a planned full refill. Ordinary rider waypoints never reset fuel.
- Generated fuel stops belong to the primary leg and may be replaced automatically to preserve feasibility. Offer reachable alternatives around the same stage of the ride.
- Changing a primary style changes its internal fuel-section styles. Independently editing fuel sections is provisional for From Here only, contingent on responsiveness. Plan a Route uses primary-leg style controls.
- Necessary dead-end access to a rider waypoint is allowed without an arbitrary distance cap. Necessary repeated station-access roads are allowed, respecting legal entrance and exit directions.

## 3. Riding style

| Style | Objective |
| --- | --- |
| Dirt | Seek as close to 100% known dirt as feasible. Pavement connects desirable dirt and required stops; it is not the foundation to which dirt excursions are appended. |
| Balanced | Seek the closest feasible mix to 50/50 over the primary leg, with a slight dirt-side preference among comparable balances. Prefer 48% to 65%; do not set a new 55% target without agreement. |
| Clean | Seek paved back roads. Legal highway/major-road connectors remain available when needed. |

Unknown surface does not count as dirt. Allow Unknown is an access decision and cannot override explicit prohibitions. Dirt must not miss a more dirt-rich, equally feasible candidate that Balanced discovers under otherwise identical request constraints.

Prefer continuous, purposeful riding. Do not manufacture score by adding short dirt excursions or attached circuits returning to the same junction. Destination riding favours onward exits, without requiring every edge to point toward the destination. Deliberately attached circuits belong to Loop or rider-chosen anchors.

## 4. Settlements and necessary connections

Small rural towns are welcome. Give substantial built-up towns and cities a wide berth. Do not cut through them merely to shorten the ride. Population examples from discussion are not implementation thresholds.

Automatically allow necessary urban passage/access for constrained geography, a rider-placed urban anchor, or otherwise unavailable fuel continuation. Scope that access to its purpose. A timeout is not proof that rural alternatives do not exist. Highways are permissible connectors, never illegal by preference alone. No special approval flow is required for these connections.

## 5. Fuel

- Track usable range after reserve over the actual selected geometry and legal station access. Do not reset at arbitrary pins or regional boundaries.
- Consider fuel while constructing/selecting candidate rides; do not commit a fuel-blind ride and repeatedly rebuild it around independent pump searches.
- Prefer rural pumps even with extra kilometres. Use an urban pump automatically when needed for onward feasibility.
- Refuel early when useful for a feasible adventure. The historical 75% preference cannot prevent an early refill. A mathematical minimum stop count is not yet agreed as a superior objective to preserving riding quality.
- Every intermediate anchor must support onward fuel feasibility. A final destination must leave enough usable fuel to reach a pump afterward unless it includes refuelling.
- A generated stop 10 km before a fixed rider-selected station is legitimate when needed; both are planned refills.
- Fuel failure must not discard an otherwise complete road route. Report fuel verification separately. Distinguish an actual range gap, missing/inconsistent data, implementation failure and incomplete search. Never claim a safe fuel plan for unverified geometry.

Planning assumes the refills named in its plan. Actual navigation fuel state only resets after a confirmed refill. Initial fuel estimation remains unresolved; do not invent a full starting tank or claim live measurement.

## 6. Stable routes, variation and recovery

Persist the selected ride. Saving, reopening and starting navigation preserve it. Relevant edits may produce a new alternative; Dirt → Balanced → Dirt need not restore the old geometry. Preserve unaffected sections and validate fuel dependencies at edit boundaries.

Variety preserves riding style and seeks meaningfully different main roads where feasible. Shared access/fuel roads are acceptable. Limited network alternatives must not be disguised by cosmetic detours. Exact alternative-generation UI is deferred.

Navigation recovery preserves expected riding character toward the active waypoint and the remaining rider anchors. It solves the reported problem rather than randomly regenerating the trip.

Missed fuel automatically triggers replacement search using remaining estimated fuel. Existing navigation reroute reasons for closed/inactive/unavailable fuel use the same recovery. Exclude the unavailable pump for that recovery. Necessary legal backtracking is allowed and clearly explained. Passing a pump does not prove refuelling or permanent closure.

## 7. Later navigation integration, retained in the delivery plan

- Fuel HUD: estimated range countdown; proposed yellow for missed planned refill, red at reserve; text/icon as well as colour. Exact estimate initialization is open.
- End Navigation confirmation followed by recorded time, distance, speed and approximate remaining range. Definitions of moving/elapsed statistics are to be resolved during integration.
- Saved trip → clear → loops → reload/resume is sufficient; automatic nested outings are not required. Resume must not force completed waypoints to be ridden again.
- Preserve GPX originals. Further conversion/ride-entry functionality and place-search provider selection are separate milestones; neither should dictate the core pathfinder.
- Big bike-friendly classification and additional user-adjustable scoring controls are deferred. No “tourist” UI label was requested.

## 8. Remaining decisions that matter to implementation

| Decision | Next action | Blocks |
| --- | --- | --- |
| Choosing among very long coherent Dirt alternatives without a rider length target | Compare candidate objectives on representative rides; show outcomes rather than ask about coefficients. | Final destination-search ranking. |
| Settlement extent, berth and necessity proof | Inspect available map attributes and constrained/open-geography fixtures; propose evidence-backed rules. | Urban policy implementation. |
| Initial fuel assumption without a starting confirmation | Keep planning assumptions explicit; propose an honest live-state model. | Fuel-complete live navigation claims, not graph/candidate experiments. |
| Approximate Loop target tolerance and duration estimates | Prototype and inspect distance/moving-time errors. | Loop quality acceptance, not first candidate generation. |
| Meaningful variety and performance targets | Measure baseline, then set explicit acceptance thresholds before replacement qualification. | Release acceptance. |

Further questions should arise from these concrete evaluations. Do not expand discovery with incidental UI questions.
