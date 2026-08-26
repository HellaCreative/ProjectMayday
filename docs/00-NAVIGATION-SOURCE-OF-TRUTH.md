# DIRT — Navigation Source of Truth

**Authority:** canonical Start Navigation, cue, HUD, and in-ride waypoint document

**Owner:** Richard Smith

**Last reconciled:** 2026-08-25

**Repository:** `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt`

This is the first document to read before changing Start Navigation, turn-by-turn,
rally cues, the navigation HUD, or in-ride waypoint callouts.

Routing, fuel, and packs remain governed by
[00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md](00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md).
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

1. lock the corridor basemap and every touched routing pack (or warn before
   riding without offline reroute);
2. follow the polyline in course-up detail, with overview on demand;
3. speak and show **one cue type at a time** — Junction or Rally;
4. count down distance and time to the **next named waypoint** on the itinerary;
5. keep speed, elapsed rider time, and (in Rally) the next roadbook notes on
   screen without stealing the cue channel.

Google Maps and Waze optimize arrival with junction decisions. DIRT also offers
Rally, which is a copilot calling the sharpness of the road. Those are two cue
types. They are not mixed in one mouth.

---

## 2. Two cue types

The rider picks **Junction** or **Rally**. Default is Junction. There is no
combined “ALL” mode in the product. A control that mixes both is a defect.

**Continue straight** is the only shared sentence. It is used when the chosen
road goes through a real junction and the rider must not turn. Everywhere else,
one type owns the voice and the top cue card.

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

### Rally (copilot / roadbook)

Sharpness and side, the way a rally copilot calls the road.

Spoken and shown:

- Right 6, 200 m
- Right 6 now
- Left 3 now
- Continue straight (same meaning as Junction: through, do not turn)

Numbers are 6 (wide / easy) through 1 (hairpin). Rally never says “turn”. A
sweeping right 6 is not a junction call.

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

The JavaScript live engine and Swift on-device engine author Junction and
Continue Straight from the same graph rules. Rally is derived from route
geometry with the same 6→1 classifier in both engines. The phone selects one cue
type and filters the canonical list; it does not reinterpret Rally as Junction
or regenerate an unrelated list.

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
does not make it absurdly early. Now has its own bounded short lead. Rally also
uses two beats: the first includes distance to the note; the second is the short
“now” call. Exact distance clamps are constants covered by tests, not scattered
HUD literals.

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
3. expandable/tertiary: final-destination remaining, climb, and surface detail;
4. Rally only: current note plus next note and partial distance.

“Always on” means the primary riding information is visible without opening a
drawer. It does not authorize four competing cards or repeating the same number
in multiple places.

---

## 4. Named waypoints in navigation

Planner names are the navigation names. Do not invent a second scheme.

- Rider waypoints: Point 1, Point 2, Point 3, …
- Generated fuel: F1, F2, F3, …
- A rider waypoint that is a packed pump stays a Point and is also a refuel;
  the HUD may show the station name as subtitle.

`RoutePlannerModel.stageEndpointTitle` already produces `Point 1 → F1`.
Navigation must receive that ordered list (along-metres + title) at Begin Ride
and after a recalculate. Arrival at a stage is “Arriving at F1”, not “stage 2”.

The handoff is an ordered `NavigationStage` value containing stable stage ID,
along-metres, title, optional station subtitle, kind (rider waypoint, generated
fuel, rider fuel waypoint, destination), and refuel-on-arrival. Recalculation
may change along-metres but must not rename or reorder the remaining stages.

---

## 5. Start, ride, end

1. **Start Navigation** — enter the prefetching phase, lock pin edit, prefetch corridor tiles, download
   missing routing packs for the ride. The session is not active yet.
2. **Begin Ride** — activate the session, background GPS, course-up camera,
   keep the screen awake. Seed the cue card from the last fix.
3. **End Ride** — confirm, stop speech, restore the planner, offer track
   contribute when the ride earned it.

A declined or missing pack must warn that offline reroute may fail before Begin
Ride. “Ride with live maps only” is last resort, not the happy path.

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

Normal recalculation continues toward the next named waypoint and cannot route
behind the rider unless the rider explicitly chooses Backtrack. A generation or
task identity prevents a late cancelled response from replacing a newer line.

Keep-awake policy is synchronized centrally whenever scene phase or navigation
phase changes. Background/inactive always clears the idle-timer override;
returning active reapplies it while a ride is active.

---

## 6. Current implementation (not the law)

As of 2026-08-25 the code does not yet match this document. Treat the following
as defects, not product:

- Default cue mode `ALL` builds Rally curves and Junction-shaped wiggles from
  the same polyline and can speak both.
- Cue distance bands are fixed (450 / 180 / 40 m), three spoken beats, last-key
  only (jitter can repeat). New speech stops the previous utterance.
- Continue-straight is not emitted. Graph degree is unused on device.
- Live `/api/route` maneuvers are discarded whenever geometry cues exist.
- HUD “km to go” is remaining on the whole line. Stage titles are not passed in.
- `startedAt` exists; elapsed rider time is not shown.
- `KeepAwakePrefs.sync` is not called from Begin Ride.
- `NavigationSession.beginPrefetch()` is unused.
- Only a maneuver-filtering smoke test exists. There are no session-level tests
  for speech cadence/deduplication, continue-straight, named-stage arrival,
  reroute continuity, or F1 countdown.

Code: `Dirt/Features/Navigation/` (`NavigationSession`, `NavCueBuilder`,
`NavigationCueSettings`, `NavigationHUD`, `NavigationPipView`,
`OfflineMapPrepOverlay`), plus `RoutePlannerModel.startNavigation` /
`beginRideAfterOfflineReady` / `recalculateFromRider`, `MapState` navigation
camera, `LocationService`, `KeepAwakePrefs`.

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

## 8. Field evidence (2026-08-24)

Still open against this document:

- Voice talks too much / cuts itself off / repeats a curve.
- Silent at straight-through intersections.
- Rider does not yet trust turn-by-turn or Rally.

Fix the cue types and the waypoint countdown before adding more chrome.

---

## 9. Definition of done and regression matrix

Navigation changes are complete only when automated tests cover:

- Junction and Rally isolation, including migration from stored `ALL`;
- equivalent maneuver classification from live and on-device routing fixtures;
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
- all touched region packs pinned during prep/ride and explicit degraded-mode
  copy on failure;
- keep-awake transitions for active, inactive, background, reroute, and End;
- portrait and landscape layouts at the supported iPhone sizes.

Physical gates: phone speaker, Bluetooth helmet with Music playing, one rural
Junction ride, one Rally ride, a fuel-stage arrival, an off-route return, and an
offline reroute.

## 10. Locked implementation order

1. Freeze the maneuver and `NavigationStage` contracts with fixtures.
2. Remove `ALL`, migrate preferences, and default to Junction.
3. Author graph Junction/Continue Straight and matching Rally classification in
   both routing engines; stop discarding authoritative maneuvers.
4. Build the monotonic speech queue and adaptive cadence.
5. Add named-waypoint countdown, elapsed rider time, and continuity state.
6. Complete prefetch, keep-awake, and cancellable reroute lifecycle.
7. Refine portrait/landscape HUD hierarchy only after the functions are green.
8. Run automated gates, install on WHITE, then complete the physical gates.
