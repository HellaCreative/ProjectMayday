# DIRT — Navigation Source of Truth

**Authority:** navigation presentation, cues, HUD, audio and session lifecycle.
Routing and route-data decisions are defined only in
[ROUTING-SOURCE-OF-TRUTH.md](ROUTING-SOURCE-OF-TRUTH.md).

**Owner:** Richard Smith

**Routing documentation consolidated:** 2026-09-13. This edit changes no
navigation implementation and claims no new device acceptance.

**Repository:** `/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt`

This is the first document to read before changing Start Navigation, turn-by-turn,
rally cues, the navigation HUD, or in-ride waypoint callouts.

Routing, fuel, and packs remain governed by
[ROUTING-SOURCE-OF-TRUTH.md](ROUTING-SOURCE-OF-TRUTH.md).
That document does not define how the rider is spoken to or what the HUD counts
down. This one does.

The short note at `NAVIGATION.md` is a pointer only. Field tickets in
`FIELD-FEEDBACK.md` are evidence against this law, not a second spec.
Cursor canvases and chat research are not authority.

---

## 1. What navigation is

Planning builds the ride. Navigation is a separate workspace: the rider has
already accepted the line and is moving.

Start Navigation must:

1. complete the route/data readiness handoff defined in the sole routing
   source of truth, presenting its progress, cancellation and availability
   state accurately;
2. follow the polyline in course-up detail, with overview on demand;
3. speak and show the selected detail level — Junction/Essential or
   Rally/Everything;
4. count down distance and time to the **next named waypoint** on the itinerary;
5. keep speed, elapsed rider time, and (in Rally) the next roadbook notes on
   screen without stealing the cue channel.

Google Maps and Waze optimize arrival with junction decisions. DIRT's Rally
level keeps those essential decisions and adds a copilot calling the sharpness
of the road between them. A real junction always takes priority over a nearby
roadbook curve so two calls never compete for the same decision.

---

## 2. Two cue types

The rider picks **Junction / Essential** or **Rally / Everything**. Default is
Junction. There is no third “Both” control: Rally is the comprehensive level.
Audio On/Off is independent and changes speech only, not the visual cue level.

### Junction (Google / Waze)

Decision at a fork, not a wiggle in the line.

Spoken and shown:

- Turn right in X metres
- Turn left in X metres
- Turn around
- Continue straight

Cadence: two beats only — prepare (~20 seconds of travel at current speed), then
now. Skip prepare if the rider is already inside the now window. Do not interrupt
an utterance; do not re-say because GPS jitter crossed a metre ring.

Junctions come from the **road graph** (degree, chosen continuation), not from a
15° bend in the polyline. Unnamed dirt roads may omit the street name. Silence
through a real intersection is a defect.

### Rally / Everything (essential navigation + copilot / roadbook)

Every Junction/Essential decision remains spoken and shown. Between those
decisions, Rally adds sharpness and side the way a rally copilot calls the road.

Spoken and shown:

- Right 6, 200 m
- Right 6 now
- Left 3 now
- Turn left in X metres
- Continue straight (same meaning as Junction: through, do not turn)

Numbers are 6 (wide / easy) through 1 (hairpin). A roadbook curve never says
“turn”; essential junctions included in Rally retain their normal navigation
wording. A sweeping right 6 is not itself a junction call.

The Rally HUD is a short roadbook: the current note plus the next one, with
partial distance. Silence between notes is correct.

### 2a. Canonical maneuver contract

Navigation consumes an authoritative ordered maneuver list. It must not replace
valid graph-authored maneuvers merely because it can derive curves from the
polyline.

Every maneuver carries:

- a stable identity that survives decode and a mid-ride recalculation;
- `kind`: `junction`, `continueStraight`, `rally`, or `arrive`;
- along-route metres;
- side when applicable;
- Rally number when applicable;
- display and spoken meaning;
- stage identity when the maneuver is an arrival.

The active routing implementation supplies graph-authored Junction and
Continue Straight decisions. Rally curves are derived from route geometry using
the same 6→1 meaning. Engine selection and qualification belong to the routing
source of truth. Junction mode filters to
essential decisions. Rally mode merges those same decisions with the geometry
curves, suppressing any curve within the junction attention window. A curve can
never replace a junction, and distinct nearby junctions are never collapsed.

A real junction has at least one plausible motorized outgoing choice after
removing the arrival edge, private/service driveways, parking aisles, pack
stitches, ineligible access, and trivial dead-end spurs. Continue Straight is
emitted only when the chosen continuation passes through such a decision while
a plausible alternative diverges. A change in polyline bearing alone is never a
junction.

The stored legacy value `bends` / `ALL` migrates to Junction. New installs and
missing preferences also default to Junction.

### 2b. Cue cadence and speech state

Each maneuver advances monotonically:

`unspoken → prepare → now → passed`

GPS jitter cannot move a maneuver backwards or replay a delivered phase. The
session records delivered phases per stable maneuver, not only the last spoken
string.

Junction uses two beats. Prepare is approximately 20 seconds of travel using a
smoothed speed, bounded so crawling does not make it too late and highway speed
does not make it absurdly early. Now has its own bounded short lead. In Rally,
essential junctions keep that wording and cadence; added roadbook curves also
use two beats, with distance first and the short “now” call second. Exact
distance clamps are constants covered by tests, not scattered HUD literals.

Speech never interrupts an utterance already in progress. A newer `now` may
discard an obsolete queued `prepare`, and passed maneuvers are removed from the
queue. Ending navigation or turning audio off clears the queue immediately.

Navigation audio mixes over Music without pausing it or permanently changing
its volume. The audio session is released after the queue empties. Phone speaker
and Bluetooth-helmet playback are physical-test gates.

---

## 3. HUD trip computer

These are always on during an active ride. They are not cues.

| Field | Law | Must not |
| --- | --- | --- |
| Speed | Live km/h from GPS | Sit inside the cue card |
| Distance | Count down to the **next named waypoint**, live (100 → 99 → 98 km) | Speak every kilometre |
| Rider time | Elapsed since Begin Ride (`startedAt`), surviving mid-ride recalculate | Reset to zero on reroute |
| Time to waypoint | Time remaining to the next named waypoint using smoothed recent speed; use the planning fallback only until enough moving samples exist | Replace elapsed rider time or jump with each raw GPS fix |
| Remaining to destination | Secondary, once the next-waypoint pair is on screen | Be the only distance shown on a multi-leg ride |

Voice for waypoints: approach (~2 km) and arrival only. Example: “Fuel 1 in two
kilometres”, then “Arriving at F1”. The number on screen ticks every GPS fix;
the mouth does not.

### 3a. Glance hierarchy

The map remains the workspace. Portrait and landscape may pack controls
differently, but preserve this hierarchy:

1. always visible: current cue, cue distance, speed, next waypoint name and
   distance;
2. secondary strip: time to next waypoint and elapsed rider time;
3. surface immediately above the larger next-waypoint name/distance; final-destination remaining and climb are secondary;
4. Rally only: current note plus next note and partial distance.

“Always on” means the primary riding information is visible without opening a
drawer. It does not authorize four competing cards or repeating the same number
in multiple places.

---

## 4. Named waypoints in navigation

Navigation uses the ordered named-stage handoff defined by
[the routing source of truth](ROUTING-SOURCE-OF-TRUTH.md). It does not invent a
second naming scheme or redefine rider/fuel ownership or refill state.

Display the supplied Point/F title and optional station subtitle. Arrival at a
stage is “Arriving at F1”, not “stage 2”. Use the handoff's stable stage identity,
along-route distance, title, kind and relevant arrival metadata at Begin Ride
and after recalculation. Route and fuel decisions remain with the routing
contract; the HUD presents their result.

---

## 5. Start, ride, end

1. **Start Navigation** — enter preparation and lock pin editing. Present the
   readiness, progress, cancellation and availability outcome defined in the
   routing source of truth. The ride session is not active yet.
2. **Begin Ride** — activate the session, background GPS, course-up camera and
   keep-awake state. Seed the cue card from the last fix. Route-data acquisition
   and ongoing readiness follow the sole routing source of truth.
3. **End Ride** — confirm, stop speech, restore the planner and offer track
   contribution when the ride earned it.

Mid-ride off-route: hysteresis, then recalculate. Cancel an in-flight
recalculate if the rider is back on the line. Recalculate must not wipe elapsed
rider time or climb.

The navigation state machine is explicit:

`idle → prefetching → ready → active → recalculating → active → ended`

Cancel from prefetching returns to idle and unlocks route editing. Begin Ride is
the only transition that sets `startedAt`. Recalculation preserves `startedAt`,
elapsed rider time, climb, ridden edge history, completed stages, remaining
stage names, per-leg profile, and fuel order. It resets only progress local to
the replacement line.

Recalculation target, route ownership and recovery rules belong to the routing
source of truth. Navigation keeps its cue/session state aligned with the accepted
replacement. A generation or task identity prevents a late cancelled response
from replacing a newer line.

Keep-awake policy is synchronized centrally whenever scene phase or navigation
phase changes. Background/inactive always clears the idle-timer override;
returning active reapplies it while a ride is active.

---

## 6. Implementation and evidence

Navigation code lives in `Dirt/Features/Navigation/`, with planner handoff,
map camera, location and keep-awake integration elsewhere in the app. Inspect
the current implementation and device evidence before declaring a defect fixed
or a feature qualified. Historical August field notes are not a current
implementation status or a mandate to restore an older build.

---

## 7. Proven patterns this law already encodes

- Apple Maps: two spoken beats, then now.
- Waze: do not stack prompts; final now always fires.
- OsmAnd: “go ahead” / continue when the next decision is far; named
  intermediate destinations.
- Garmin zūmo: distance-to-next-via as a live trip-computer field; fuel stop is
  a via, not a kilometre ticker in the headset.
- Digital roadbooks (DMD, TRBP): next note + partial; silence between notes.

Do not take lane guidance or dense street-name TTS as required on unnamed
dual-sport fabric. Do not take CarPlay as a prerequisite for this law.

---

## 8. Definition of done and regression matrix

Navigation changes are complete only when automated tests cover:

- Junction/Essential filtering and Rally/Everything inclusion, including
  junction priority over nearby curves and migration from stored `ALL`;
- equivalent maneuver meaning for every currently supported routing source;
- Rally 6→1 direction (wide/easy to hairpin), never inverted;
- real-junction filtering and Continue Straight through a genuine decision;
- adaptive prepare/now distance clamps at walking, trail, road, and highway
  speeds;
- monotonic cue phases under repeated GPS boundary jitter;
- no utterance interruption, stale queued prompt, or speech after End Ride;
- Point/Fuel naming, station subtitle, approach, arrival, and stage advancement;
- mid-ride recalculation preserving time, climb, names, profiles, fuel order,
  and later legs;
- cancellation when the rider returns to the line and rejection of late stale
  reroute responses;
- preparation and availability presentation consistent with the routing source
  of truth, with cancellation and honest failure/degraded-state copy;
- keep-awake transitions for active, inactive, background, reroute, and End;
- portrait and landscape layouts at the supported iPhone sizes.

Physical gates: phone speaker, Bluetooth helmet with Music playing, one rural
Junction ride, one Rally ride, a fuel-stage arrival, an off-route return, and an
offline reroute.

## 9. Navigation implementation sequence

1. Freeze the maneuver and `NavigationStage` contracts with fixtures.
2. Keep two levels, Junction/Essential and Rally/Everything; migrate the retired
   `ALL` preference and default to Junction.
3. Consume graph Junction/Continue Straight and matching Rally classification
   from the accepted routing handoff; preserve authoritative maneuvers.
4. Build the monotonic speech queue and adaptive cadence.
5. Add named-waypoint countdown, elapsed rider time, and continuity state.
6. Complete prefetch, keep-awake, and cancellable reroute lifecycle.
7. Refine portrait/landscape HUD hierarchy only after the functions are green.
8. Run automated gates, then complete the physical gates on an authorized
   device. This document does not grant device-installation permission.


## 10. Field-driven navigation audit — 20 September 2026

Scope reviewed: Start/Begin readiness and cancellation, active map/overview,
location matching and progression, Report and automatic recovery, Junction/Rally
construction and delivery, speech queue, waypoint continuity, fuel detours,
background location/keep-awake, and End Ride. This is a code and automated-test
review, not a claim that field acceptance is complete.

### Implemented corrections

- Report now offers **Route Around** and **End Ride**. The old End Stage action
  ended all navigation; the new wording is honest and ending requires confirmation.
  Removed the separate Backtrack and Nearest Verified Network choices. The latter
  actually targeted a nearby point on the old line, not a new verified network.
- Route Around is permission to calculate and apply an active-leg replacement.
  It starts at the current fix, retains the next waypoint and later legs, and
  shows the replacement in overview. Failure preserves the route. Missing edge
  identity fails visibly instead of claiming the reported obstruction was avoided.
  Its task is cancellable and rejects results from a cancelled report, ended
  session, changed stage, or a rider who moved more than 75 m while it calculated.
- Road reports use segment projection, fixing mid-road matches that previously
  failed because only stored vertices were considered. Recovery follows the
  current stable stage ID before considering geographical proximity; overlapping
  outbound/return legs cannot choose the wrong waypoint just by proximity.
- Report escape is an explicit routing constraint, documented in the routing
  authority. The starting blocked road permits a legal retreat toward its prior
  endpoint only. It cannot be used forward, later in the route, or as an avoided
  destination. This does not manufacture a reverse route or override directions.
  Subsequent navigation requests retain the itinerary's recorded blocked edges.
- Off-route recovery starts automatically after three accurate, increasing-time
  fixes more than 50 m off the route over at least two seconds. Accuracy must be
  35 m or better; the planner ignores fixes older than 15 seconds. One request
  runs at a time. Failed automatic retries require at least 30 seconds and 30 m
  of movement; explicit retry remains available. Opening Report suspends this
  behavior. Rejoining cancels automatic recovery; stale generations cannot apply.
- Junction no longer synthesizes decisions from geometry-only bends. Removed a
  second normalization pass that promoted sharp bends and collapsed distinct
  junctions within 55 m. U-turn meaning and symbols survive normalization.
- Junction bearings use 25 m approaches rather than tiny adjacent OSM vertices.
  Keep the active cue until passing the actual junction (5 m tolerance), rather
  than dropping it 15 m early and presenting the next instruction mid-turn.
- Speech keeps only still-upcoming maneuver identities and the current waypoint.
  Off-route/replacement/end clear obsolete pending cues. Existing utterances are
  not interrupted by the next navigation cue; End stops speech immediately.
- Rally retains its 6-easy to 1-hairpin meaning and junction priority. Close
  opposite-direction curve notes are no longer discarded as duplicate curves.
- Surface is above the next-waypoint row in portrait and landscape. Waypoint
  title and remaining distance are larger. A delayed Begin Ride checks that
  preparation is still active before enabling GPS/navigation.

### Audit findings still requiring follow-up

1. **Fuel detours:** `performFuelViaRoute` currently picks the geographically
   nearest pump, not the nearest legally reachable pump, and uses default ride
   settings rather than explicitly passing the active leg's full policy. It
   routes back to a point 40 m ahead on the old line. The accepted fuel stop is
   not represented as its own named navigation stage, so a subsequent off-route
   recalculation can target the rider waypoint without retaining that pump.
   This needs dedicated routing/continuation tests and a repair; fuel remains
   advisory until the rider requests that detour.
2. **Graph decision quality:** branch filtering excludes prohibited/service/
   parking/short alternatives, but does not yet prove every alternative diverges
   meaningfully or leads beyond a dead-end spur. Complex forks, roundabouts,
   grade-separated nearby roads, and repeated visits to the same junction need
   targeted fixtures. Repeated edge-pair cue IDs may suppress a second visit.
3. **Rally calibration:** the severity model uses geometry radius/angle, not
   banking, grip, sightlines, or safe speed. Test wide bends, tight hairpins,
   S-bends and short successive decisions against recorded field geometry before
   treating the numbers as rider-qualified. No safe-speed claim is made.
4. **Lifecycle:** the Begin Ride guard prevents activation after cancellation,
   but a cancel→new preparation while the previous basemap activation is awaiting
   deserves a generation-specific integration test. Next-stage tile lookahead
   uses a positional stage number and needs validation after rebasing a reroute
   from a later leg.
5. **Device acceptance:** offline Route Around, missing-pack failure, report
   cancellation, returning naturally to the line, GPS loss/poor accuracy, both
   orientations with long waypoint names, phone audio, and Bluetooth helmet
   audio over Music remain field gates. No White installation was performed.

### Research comparison

The separation of maneuver type from bearing/turn modifier agrees with the
[OSRM maneuver contract](https://project-osrm.org/docs/v26.4.0/http): continuing
on a road does not by itself mean travelling geometrically straight. The
[Mapbox rerouting lifecycle](https://docs.mapbox.com/ios/navigation/guides/turn-by-turn-navigation/rerouting/)
also treats going off-route as a trigger for recalculation. These informed the
review; DIRT continues using its own installed-pack engine and riding preferences.

### Evidence

- `.build/navigation-audit-20260920/engine-final.log`: **169 engine tests pass**,
  including a full-engine blocked-road retreat and refusal to arrive through the
  blocked edge or depart in the prohibited recovery direction.
- `.build/navigation-audit-20260920/tests-3.xcresult`: **107 app tests pass** plus
  `DirtUITests/testCueSelectorHierarchy`. Includes actual Report→Route Around
  integration from a mid-segment GPS fix, preserved later leg, overview,
  overlapping stages, automatic recovery hysteresis, poor/repeated fixes, queue
  validity, close junctions/U-turns, and Rally chicanes.
- `.build/navigation-audit-20260920/tests-4.xcresult`: final **54 focused app
  tests pass** after fresh-GPS and report/session-cancellation guards.
- The cue-selector screenshot was inspected; the portrait surface/waypoint
  hierarchy is visible. Landscape is compiled, not yet visually accepted.
- The first broad app run exposed three stale expected DEV URLs from September
  17. The isolation test now expects the existing September 19 seven-pack
  candidate. App configuration and release selection were not changed.

The continental factory is separate: these are runtime corrections. No pack
bytes were rebuilt or promoted for this navigation work.
