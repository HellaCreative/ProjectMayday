# DIRT routing rebuild workbook

Status: discovery draft, September 8, 2026. This is the working record for Richard's systematic routing redesign. It is not an approved specification or a completed build plan. No routing implementation is changed by this document.

## Purpose

Extract the product intent from the existing engine, tests, historical changes and rider feedback. Make competing requirements explicit. Agree on rider outcomes, then produce an executable architecture and build plan with measurable acceptance criteria.

Richard's latest direction expands the brief beyond destination routing: support enjoyable local riding and loops, consider shared GPX rides, provide strong defaults, allow meaningful rider adjustment, and allow future location search to create pins. Older prohibitions against exploration must be reviewed in that context.

## How decisions will be recorded

For each topic, record: rider intent; evidence in code or documents; current behaviour; conflicts; proposed rule; Richard's decision if needed; example journeys; acceptance checks. Historical implementation constants are evidence, not automatically product requirements.

States: **confirmed now**, **inherited intent**, **proposal**, **open question**, **measured behaviour**. Keep these distinct. A successful test is evidence for its case, not proof of universal quality.

## Confirmed now

- Review the decision architecture systematically rather than continuing discrete scoring patches.
- Extract and explain intent before finalising a replacement design.
- Build toward a clean, accurate, efficient and extensible engine.
- Treat local enjoyable rides and shared loops as important use cases.
- Design for sensible defaults and possible rider-adjustable preferences.
- Accommodate future location search for pin placement.
- Finish discovery with a concrete build plan that can be executed and verified.

The first-release scope of each new capability remains to be decided. No specific latency target, search algorithm, slider or loop-generation method has been accepted yet.

## First intent inventory

This table is the initial extraction. Dated clarifications below supersede it where they differ; in particular, the fourth clarification establishes three flows and revises the proposed use of time/distance inputs.

| Topic | Extracted intent | Status and decisions still needed |
| --- | --- | --- |
| Destination ride | Enjoy the ride between ordered rider pins, preserving required stops. | Inherited. Define acceptable extra distance/time and whether a pin requires an exact visit or may shape a route nearby. |
| Local exploration | Generate an enjoyable ride from a starting place, potentially returning there. | Confirmed interest. Decide first-release scope, distance/time/area input, return point and permitted area excursions. |
| Dirt | Prefer meaningful, explicitly known unpaved riding. Unknown surface is not dirt. | Inherited. Decide dirt proportion versus total useful dirt distance and detour tolerance. Highest percentage alone can select a disappointing ride. |
| Balanced | Seek a feasible mix near 50/50 known dirt and pavement. | Inherited. Decide whether 50/50 remains the desired default, tolerance and what happens when it is unavailable. |
| Clean | Prefer paved roads with sensible progress; current intent includes city and motorway avoidance. | Inherited. Clarify whether Clean means efficient paved travel or enjoyable paved riding, particularly for loops. |
| Cities and towns | Avoid unnecessary major-city riding without breaking access to rider destinations; small towns are not universal barriers. | Inherited. Decide avoidance strength, acceptable bypass distance, and treatment of useful town services. |
| Road legality | Respect actual access, travel direction, barriers and turns. Never invent a road connection. | Inherited invariant to retain. Unknown permission remains separate from explicit prohibition and unknown surface. |
| Repeated roads | Avoid pointless out-and-back riding; permit necessary endpoint and service access. | Inherited intent with conflicting historical hard rules. Define acceptable shared stems for loops and worthwhile dead-end destinations. |
| Fuel | Use real, directionally reachable pumps; track usable range after reserve through the journey. An ordinary pin does not refill the tank. | Inherited. Review stop-count priority, preferred stopping point and arrival escape requirements. |
| Fuel uncertainty | Distinguish verified coverage, established gaps and incomplete searches. | Inherited invariant. Decide how an unverified but usable route is presented and accepted. |
| Variety | Offer meaningfully different good rides with reproducible results. | Inherited. Decide explicit “another ride” versus automatic variation on repeated requests. |
| GPX | Preserve the imported original, its direction and shape; make conversions and deviations explicit. | Inherited plan. Decide faithful following versus optional reinterpretation and delivery phase. |
| Rider adjustments | Good defaults should work without tuning; optional controls should express recognisable tradeoffs. | Confirmed direction. Controls and their ranges are unapproved. Legality is not a preference slider. |
| Place search | Resolve a named location into a rider-chosen pin. | Confirmed future need. Keep place lookup distinct from finding a road route to the chosen location. Provider and offline scope are unselected. |
| Editing and recovery | Preserve unaffected rider choices, completed planning and downstream anchors where feasible. | Inherited. Separate planning edits from navigation recovery and define invalidation boundaries. |
| Regional boundaries | A rider should experience one connected journey across supported regions. | Inherited. Preserve exact directional crossings and ferry facts; boundaries must not reset fuel or ride intent. |

## Conflicts to resolve explicitly

1. **Forward-only destination rules versus loops.** Returning to the start is success for a loop. Destination progress rules cannot govern every ride mode unchanged.
2. **Maximum dirt versus a bounded ride.** We need a definition of a worthwhile ride within distance/time expectations. More searching is not a substitute for defining that tradeoff.
3. **No retrace versus necessary access.** Historical zero-retrace wording and later recovery allowances disagree. Define the rider outcome before choosing penalties or exclusions.
4. **Fuel follows the ride versus fuel shapes the ride.** A beautiful route with no feasible fuel chain is not a fuel-qualified result. Feasibility must influence selection while preventing pumps from independently dictating a poor ride.
5. **Minimum stops versus ride quality.** Proving the fewest stops across every conceivable route is different from finding the fewest stops on one selected route. The accepted scope of that promise must be explicit.
6. **Area versus distance.** A 200 square kilometre area is not a 200 kilometre ride. Area boundaries, ride length and ride duration need separate meanings.
7. **Existing numerical rules versus durable intent.** The 75% fuel preference, short-dirt thresholds, dirt quality floors, corridor widths and detour ceilings have different histories. None should be carried over without its purpose and consequences being understood.
8. **GPX preservation versus improvement.** Following a friend's ride and generating an alternative inspired by it are different requests.

## Questions in the first discussion

- Does the first release include both destination routes and generated loops?
- Is local ride creation primarily expressed by approximate distance, riding time or a selected area?
- When interesting riding adds distance, should the default preserve a requested budget, offer alternatives, or prioritise ride quality with a clear preview?

First answers recorded below. Later discussions will cover concrete examples of surface tradeoffs, city bypasses, fuel access, retrace, GPX preservation, adjustable controls, degraded results and acceptable waiting time. Ask in small batches after showing the relevant extracted intent.

### Richard's first clarification — adventure and distance

**Confirmed now:**

- Include both destination rides and loops in the first-release scope discussed here.
- Adventure riding is the purpose in both modes. A destination is not an instruction to minimise travel between pins.
- Endpoint separation does not express desired ride length. A nearby campsite may be the destination for a full day's riding.
- A local ride should normally return home as a loop.
- A long trip, such as a lake in Quebec, should provide interesting dirt riding throughout the journey, including between fuel stops and rider waypoints.
- Approximate riding distance is meaningful to Richard; he uses it to judge how long the ride will take. Approximate riding time is not his desired planning input. This does not prohibit an informational time estimate.
- A slider should allow less meandering when the rider has limited time and more exploration when desired. Its exact units, scope and interaction with surface preferences remain unresolved.

**Revised interpretation:** one adventure-riding purpose can have an open destination or a return-to-start destination. The request needs to express both where the rider wants to go and how much riding they want along the way. A minimal-distance connection may be useful internally but is not the default product objective. Global prohibitions on lateral exploration conflict with this confirmed intent.

**Proposal, not yet accepted:** express the exploration control in visible approximate kilometres, so the rider can understand its effect without understanding scoring. Treat this separately from Dirt/Balanced/Clean surface preference. Additional distance should buy worthwhile riding, not artificial repetition. Determine whether the control applies to the whole itinerary, individual rider legs, or both before designing its search contract. Generated fuel stops should support this chosen ride rather than redefine its adventure objective.

**Worked scenarios to preserve in acceptance:**

1. Home to home: a satisfying local adventure loop at the requested approximate distance.
2. Home to nearby campsite: substantial worthwhile riding before arrival, despite short endpoint separation.
3. Home through chosen waypoints to a Quebec lake: worthwhile dirt riding across the journey with feasible fuel legs; no assumption that each leg should be the quickest connection.

No distance tolerance, maximum exploration multiplier, quality formula or slider implementation has been accepted by this clarification.

### Richard's second clarification — rider sections and fuel sections

**Confirmed now:**

- Continue discovery through small back-and-forth questions until sufficient intent is captured to build from.
- Each section between adjacent rider-placed waypoints needs its own riding style. A multi-region adventure can intentionally alternate Dirt and Balanced as the rider chooses.
- Insert fuel stops between rider waypoints when the actual ride and motorcycle range require them. Generated fuel stops are waypoints, but remain distinct from rider-placed waypoints.
- Let the rider replace an unwanted generated fuel stop with alternatives in a similar distance area. Replacements must still support a feasible journey.
- Prefer the ability to change riding style on individual sections separated by fuel stops, such as Point 2 → Fuel 1 and Fuel 1 → Point 3.
- Fine-grained fuel-section style editing is conditional on acceptable rebuilding time. If it makes rebuilding too slow, Richard accepts style controls only for the whole section between rider-placed waypoints.

**Scope clarification:** the preceding question asked about amount of riding per rider section; Richard explicitly confirmed riding *style* per section. Do not silently treat this as a final decision on distance-slider scope. Separate surface-style control from requested riding-distance control in subsequent discussion.

**Proposed edit boundary:** changing Point 2 → Point 3 should reuse unaffected geometry before Point 2 and after Point 3. Revalidate fuel continuity at those boundaries: rider waypoints do not inherently refill the tank, so an edit can affect fuel available downstream. Do not promise that downstream fuel validation can always be skipped. Define the behaviour when an edit cannot preserve downstream fuel feasibility before implementation.

**Unresolved details:** what “similar distance area” means to the rider (progress along the ride, distance from the existing pump, or another interpretation); whether style edits may move generated pumps automatically; response-time acceptance for fine-grained controls; distance-slider scope; and how conflicting downstream fuel needs are presented.

**Next discussion example:** changing a section from Balanced to Dirt makes it longer, and the previously selected fuel stop is no longer reachable within usable range. Establish whether DIRT should propose a revised fuel plan or keep the selected pump fixed and report the conflict. This distinguishes generated recommendations from rider-committed anchors.

### Richard's third clarification — fixed anchors and integrated fuel

**Confirmed now:**

- A rider-placed waypoint can only be moved by the rider, whether it is a fuel station or another destination. Route optimisation must retain that commitment.
- A rider waypoint placed at a fuel station implies a full refill. Make that refuelling explicit in the itinerary. An ordinary rider waypoint does not refill the tank. The precise station-association rule must preserve directionally reachable station access rather than relying on proximity alone.
- DIRT may automatically replace a generated fuel stop when a riding-style or Allow Unknown change alters the route and makes the old stop unreachable. Allow Unknown remains an access-policy choice, not a surface classification.
- Offer suitable alternatives for generated fuel stops. A user-selected alternative remains distinct from a rider-created primary waypoint; selecting a generated replacement does not by itself grant permission to move a rider-created anchor.
- Fuel feasibility must participate in route construction and selection. Do not first commit a fuel-blind adventure route, then find a nearby pump and repeatedly rebuild the ride around it. This is a rider-outcome and work-reuse requirement, not a prescription for one specific search algorithm.
- Lateral travel for fuel can contribute to an interesting ride. A straight-line corridor between rider pins must not automatically disqualify it. Exact limits on worthwhile extra distance remain open.
- If a rider's fixed destination is a fuel station but reaching it requires another refill, add that generated stop even if it is only 10 km before the fixed station. Both stops explicitly refill the tank. Never move the fixed station merely to avoid two nearby refills.

**Provisional rule, explicitly open to scenario testing:**

- In “Route Build,” adjacent rider waypoints define primary legs containing generated fuel sections.
- Changing a primary leg's riding style changes the styles of all fuel sections inside it. This is an explicit parent edit overriding any finer section choices, subject to testing the intended interaction.
- Independent fuel-section riding-style edits should only be available in “Route Build,” not “Plan a Route.” Richard's exact distinction between those two named flows remains to be clarified; do not map them onto existing app entry points by guesswork.

**Ambiguous wording to clarify:** Richard said “if a fuel stop isn't necessary, then we continue the route to the fuel stop regardless of where that fuel stop is.” The fixed rider-placed fuel-stop example clearly requires visiting that station even when a refill is unnecessary. Do not infer that an unnecessary automatically generated stop must always be retained. Ask about this distinction if it remains relevant after the next clarification.

**Acceptance scenarios:**

1. A primary style edit lengthens the route: DIRT adjusts generated fuel stops while preserving every rider-placed anchor and validates the returned geometry's actual fuel use.
2. A fixed rider-placed fuel station requires a generated refill 10 km earlier: retain both stops and show a refill at both.
3. A station lies laterally away from the pin-to-pin line: consider legal, worthwhile fuel-feasible riding through it rather than rejecting it solely for lateral displacement.
4. Changing a primary style updates all internal fuel-section styles; independent internal edits are offered only in the agreed Route Build flow.

**Still open:** exact Route Build versus Plan a Route meaning; whether newly selected generated alternatives have any temporary pinning behaviour; how unnecessary generated stops are removed; distance targets and tolerances; and how edit boundaries preserve downstream fuel feasibility without unnecessary rerouting.

### Richard's fourth clarification — three rider flows and critical review

Richard explicitly wants pushback and better alternatives, not literal adoption of every exploratory statement. Evaluate ideas against examples, consequences and feasibility. Preserve uncertainty and distinguish confirmed intent from proposed solutions.

**Current flow definitions:**

| Flow | Rider request | Route ownership |
| --- | --- | --- |
| From Here: Build a Route | From the rider's current location to one rider-selected destination, nearby or across the country. | DIRT constructs the adventure and generated fuel stops between the two anchors. |
| Plan a Route | Travel through an ordered set of rider-selected places. | Rider anchors define the itinerary; DIRT constructs the adventure and fuel sections between them. |
| Loop (new) | Create a ride returning to the starting location, including a campground used as a home base. | DIRT generates the outing using the rider's desired amount of riding. |

Example planned itinerary: Porters Lake → Bay of Fundy → friends in Moncton → a campground outside Quebec City → Thunder Bay. Richard also described visiting a discovered camping place and then rejoining the planned track; exact temporary-excursion versus itinerary-edit behaviour remains open.

**Revisions to earlier interpretation:**

- The two existing flows are “From Here: Build a Route” and “Plan a Route.” “Route Build” was shorthand for the former, not a separate flow.
- The provisional fine-grained style rule now means fuel-section edits in From Here; primary rider-to-rider style edits in Plan a Route. Loop's editing rules remain open.
- Richard currently proposes explicit time and/or distance targets only for Loop. A four-hour dirt outing from camp is a concrete example. This supersedes the earlier interpretation that time is not a meaningful planning input in any flow.
- Keep the earlier nearby-campsite/full-day-riding example as an unresolved product tension: without a destination-ride exploration input, DIRT still needs a clear default for worthwhile extra riding. Do not silently adopt a distance slider across every mode.

**Engineering proposals for discussion, not accepted rules:**

- Share legal-road, fuel, preference and result contracts across the three flows. Distinct rider flows do not require three independent routing engines; loop candidate generation may differ from destination generation.
- Treat a requested loop duration as approximate moving time unless Richard prefers elapsed outing time. Stops, riding pace and conditions prevent a guaranteed return time. Display the estimated distance alongside duration and disclose what the estimate includes.
- Keep From Here and Plan a Route simple by default, while evaluating whether an optional exploration control is needed to serve the nearby-campsite/full-day example. Do not add that control without resolving its intent.
- A loop outing should preserve the longer saved itinerary and its continuation; confirm how leaving and rejoining that itinerary works before implementing navigation changes.

**Next question:** how should a destination ride distinguish a relatively short adventure to a nearby campsite from a full day's adventure ending at that same campsite, if explicit ride-length controls are reserved for Loop?

### Richard's fifth clarification — loops, saved trips and variety

**Confirmed now:**

- Loop is an adventure returning to its starting point **including fuel planning**. It shares actual-range and refuelling requirements with the other flows.
- Richard accepts a saved-itinerary workflow instead of requiring automatic nested outings: save the trip, ride part of it, clear the active ride, create and ride one or more loops, then load the saved trip and continue.
- Variety is required across all three flows. A rider camping for two days should be able to obtain different outings from the same camp.
- Proposed Loop setup includes a chosen direction (N, NE, E, SE, S, SW, W, NW) and desired distance or riding time. DIRT chooses a loop and provides outbound and return navigation.
- Whether a destination ride is longer or more exploratory is the rider's choice during setup. Defer exact From Here and Plan a Route controls until scoring intent has been discussed.

**Recommendations and implications, not yet accepted implementation details:**

- Offer an explicit way to request another ride with unchanged settings. Changing time or distance should not be required merely to obtain variety. Prefer meaningfully different roads; do not promise uniqueness where the legal network has only one suitable option.
- Treat compass direction initially as the area the loop explores, not a mandatory first-turn bearing: a legal departure from camp may initially point elsewhere. Confirm this meaning when defining loop geometry.
- Saved-itinerary resumption must let the rider continue from their current position/appropriate remaining stage without forcing a restart or revisiting completed stops. Exact persistence and rejoin semantics need review; loading a saved route alone does not establish this behaviour.
- Clarify whether avoiding yesterday's roads is an explicit preference or automatic history behaviour. New alternatives within a session and cross-day ride-history avoidance are different capabilities.
- Richard referenced an app he called “Detect” as inspiration. Record the described interaction without assuming the app's identity or claiming its current behaviour has been externally verified.

**Next discussion: scoring intent.** Start with how Dirt should trade surface proportion against actual worthwhile dirt distance and total ride length. Use concrete competing rides, not coefficients. Later cover continuity/short excursions, city avoidance, repeated roads, fuel placement and variation. Do not choose user sliders before their underlying tradeoffs are understood.

### Richard's sixth clarification — riding type and purpose

**Confirmed direction:**

- Ride setup includes riding type alongside desired time or distance where applicable, especially Loop.
- Different days can call for dirt riding, big bike-friendly riding, more pavement, or visiting rural points of interest.
- Richard uses “rider” and “tourist” to describe different emphases: riding itself versus taking in places along the way.

**Do not overinterpret:** Richard has not yet selected between the 100 km/80% dirt and 150 km/73% dirt examples. His response confirms richer ride preferences, not a numerical ranking rule. Time/distance remains explicit for Loop; controls in the other flows are still deferred pending scoring discussion. No commitment to requiring both a time and a distance target.

**Proposed distinction for review:** surface preference (dirt/pavement), road suitability (including big-bike friendliness), and interest in visiting places are related but separate. A big bike-friendly ride can contain dirt; a paved ride can be about riding rather than tourism. Consider simple presets over these dimensions rather than hard-coded equivalences such as pavement = tourist.

**Evidence requirement:** do not label a route big bike-friendly solely from surface or road class. Establish what Richard means, what mapped attributes support it, and what remains unknown. Likewise, “scenic” or rural-interest claims need suitable source information; they are not guaranteed by a winding line.

**Next clarification:** define big bike-friendly in rider terms before specifying its scoring, exclusions or confidence labels.

### Richard's seventh clarification — core surface objectives

This clarification supersedes earlier proposals that framed Dirt as adding worthwhile diversions to a paved/direct route. Richard explicitly identifies the following as the core of the app.

**Confirmed intent:**

- **Dirt:** seek as close to 100% known dirt as possible. Pavement is a necessary connector to further dirt or required anchors, not an independently desirable component. Do not start with a paved trip and reward occasional dirt excursions.
- **Balanced:** seek as close as feasible to 50% dirt and 50% pavement.
- **Clean:** seek 100% paved back roads. Richard excludes highways, freeways and divided highways from this intended style. Mapping his rider-language exclusions onto road attributes and handling places where no compliant connection exists remain unresolved.
- Length alone does not make an adventure bad. Richard rejects “unnecessarily long” as the reason to prefer a shorter ride. Do not silently impose a shortest-route detour ceiling as product intent. Explicit loop time/distance requests still matter.
- Avoid pointless small cycles and dirt tokenism: a 1 km excursion returning to the same intersection, or a 200–300 m dirt diversion interrupting a connector toward a substantial dirt stretch, is undesirable.
- Meaningful continuous dirt riding is desirable. This does not authorise deleting short dirt edges that form necessary legal connections, station access or endpoint access.
- Earlier “tourist” and “rider” phrasing was exploratory description, not UI nomenclature. Big bike-friendly exploration is parked at Richard's request.

**Engineering interpretation to validate:** prefer coherent dirt continuity and necessary paved connections, penalise/reject gratuitous cycles and meaningless excursions, and evaluate actual surface composition. A long connected adventure is not equivalent to repeatedly circulating through the same intersection. Do not manufacture dirt percentage by adding cycles. Numerical thresholds and the precise global objective still require scenario testing; “close to 100%” is an intent, not an assertion that an exhaustive global optimum can always be computed.

**Open questions:** when no legal connection exists using the selected style, offer a clearly labelled exception versus report no matching ride; whether Clean's “no highways” excludes every numbered rural two-lane road or primarily major through-roads/divided roads; scope of motorway exclusions for Dirt/Balanced; and how to choose among very long coherent dirt alternatives without inventing a rider-facing distance cap.

**Next scenario:** a required short highway connection is the only legal way between otherwise compliant paved back-road networks. Establish whether Clean must refuse that connection or may offer it as an explicit exception.

### Richard's eighth clarification — highways are connectors, not prohibitions

This supersedes the seventh clarification's interpretation of highway exclusions as strict bans and the proposed exception-acceptance flow.

**Confirmed intent:**

- Highways, major roads, divided roads and freeways are not forbidden road types merely because the rider selected an adventure profile.
- They may serve as necessary connections between more desirable riding, just as a bridge connects otherwise separated networks.
- DIRT should use these connections automatically when needed. Do not stop routing solely because the preferred road types cannot form the entire journey.
- No special exception warning or rider approval is required for using such a connector. Ordinary accurate route geometry and surface information remain appropriate.
- Clean seeks paved back roads, with major-road connectors available when needed. Dirt seeks dirt with paved connectors where needed. Balanced seeks its surface mix; the exact acceptable deviation when that mix is unavailable remains a separate question.
- These preferences do not relax actual access prohibitions, vehicle eligibility, travel direction, barriers or turn restrictions.

**Scoring implication:** undesirable road categories are preferences to minimise in context, not hard graph exclusions. A highway shortcut must not win merely because it reduces distance or travel time when a worthwhile preferred-road adventure is available. The exact tradeoff between a very long preferred-road connection and a short major-road connector remains to be tested through scenarios, not solved by an invented cap.

**Next discussion:** settlement avoidance has historically been another hard-wall/fallback mechanism. Establish whether a legal passage through a town or city should similarly be an automatic connector between desirable roads, and what distinguishes acceptable necessary passage from unwanted urban riding.

### Richard's ninth clarification — wide settlement avoidance

**Confirmed intent:**

- Give major city centres, cities, towns and settlements a decent/wide berth. Do not merely avoid their central point.
- A shorter path through a settlement, including a shortcut toward desirable riding, is not a valid reason to enter it or skim its edge.
- A rider-placed waypoint within a settlement authorises access to that location. Determine the scoped approach/departure behaviour later; it does not imply a route-wide urban-avoidance waiver.
- Richard expects broad settlement avoidance to remove much of the need for major-highway travel. Treat this as a product expectation to evaluate against actual road geography, not a verified universal network fact.

**Unresolved exception:** Richard first described geographic truncation between bodies of water forcing travel through a city/settlement, then stated that only a rider-placed waypoint grants permission to enter or approach one. Ask explicitly whether an unavoidable geographic passage is also allowed without a rider waypoint. Until answered, do not adopt an automatic settlement fallback or claim an absolute no-passage rule is agreed.

**Engineering implications requiring subsequent decisions:** define settlement extent and what counts as a decent berth using actual mapped evidence; distinguish settlement access from highway classification; define treatment of a rider starting inside a settlement; establish whether generated urban fuel stops are disallowed and what happens when no rural fuel chain exists. Do not silently create an urban waypoint to bypass avoidance or reuse the previous general “sensible connector” fallback.

**Next question:** with no rider waypoint in town, if the only legal connection between otherwise separated networks passes through that town, may DIRT use that passage automatically or must it report that the ride cannot meet the settlement rule?

### Richard's tenth clarification — rural towns welcome, larger urban areas avoided

This supersedes the ninth clarification's broad wording covering all towns and settlements.

**Confirmed intent:**

- Small rural towns are welcome: passing through them can be part of the adventure. Do not wall off every named settlement.
- Avoid larger built-up towns and major cities with a wide berth. Richard cited settlements of roughly 20,000–30,000 people and cities of hundreds of thousands to explain the distinction; these are illustrative, not accepted population thresholds or a data-classification algorithm.
- Urban shortcuts are unacceptable. If open rural land offers a connection around a larger urban area, favour that land rather than cutting through the urban area for shorter travel.
- Genuine unavoidable connections are acceptable automatically: geographic constrictions, passages between bodies of water, and required access to a rider-placed urban waypoint.
- The Shediac/Dieppe/Moncton area is a rider-provided example where highway travel or closer urban proximity may be necessary. Treat this as a scenario to examine, not a verified claim of no alternative or a hard-coded regional exemption.
- “Strict but not super strict” means strong avoidance of larger urban areas with meaningful necessity exceptions, not a blanket prohibition that breaks the ride.

**Implementation questions:** identify larger built-up areas and rural towns using available map evidence, avoiding reliance on a single population cutoff or administrative polygon; define wide berth and geographically constrained passage; scope urban access to the rider's required anchor; ensure search timeout is not evidence of unavoidable passage. Establish how fuel necessity interacts with urban avoidance before specifying fallback policy.

**Next scenario:** if all otherwise feasible fuel chains require a pump inside a larger town, does fuel necessity authorise urban access, or should DIRT retain avoidance and report that fuel coverage cannot be established under the current preferences? A merely closer urban pump is not the same as an essential urban pump.

### Richard's eleventh clarification — rural fuel preference and necessary urban fuel

**Confirmed intent:**

- Prefer rural pumps over pumps in larger towns/cities, even when the rural option adds riding kilometres.
- Automatically allow a pump in a larger town/city when no other fuel-feasible option permits the onward journey.
- A merely closer urban pump is not a reason to abandon a feasible rural fuel plan.
- Evaluate onward feasibility, not just the ability to reach the candidate pump. The rural detour must itself respect remaining usable fuel.
- This is an additional necessity exception to larger-urban-area avoidance. It needs no rider approval flow.

**Evidence and scope:** inability to prove a rural fuel chain before a deadline is not proof that none exists. Resolve the bounded-search treatment explicitly in the technical design and preserve honest verification states. Access needed for an urban pump should not silently remove the larger-urban-area preference from the rest of the trip.

**Next discussion:** stop timing and count. The inherited engine prefers refuelling after 75% of reserve-adjusted usable range, subject to an earlier stop needed for continuation. This is not yet reaffirmed in discovery. Ask whether Richard wants stops naturally placed toward the end of usable range or earlier when that better preserves the desired riding; separate this from adding stops to chase small scoring improvements.

### Richard's twelfth clarification — fuel feasibility before stop timing

**Confirmed intent:**

- Automatically refuel early when needed to preserve a fuel-feasible journey, including before a substantial dirt stretch. Do not wait for the inherited 75% preference when doing so would jeopardise continuation.
- Fuel planning serves rider safety: plan to keep fuel available throughout the actual route, using the motorcycle's stated range and reserve. Stop timing and route preferences must not override feasibility.
- If a fuel risk cannot be resolved through available refuelling or route changes, notify the rider that carrying additional fuel or adjusting the route may be necessary based on the vehicle's fuel range.
- Do not interrupt the rider with a fuel warning for a situation DIRT has already resolved automatically with a feasible fuel plan.

**Engineering boundary:** the engine can verify planned distances against supplied usable range and available station data; it cannot guarantee real-world consumption or an operating pump. Use precise verification language without turning ordinary successful planning into repeated disclaimers. A search timeout or missing evidence is not a proved fuel gap and must not trigger a false claim that extra fuel is necessary. The honest presentation of incomplete verification remains to be defined separately.

**Open acceptance decision:** the existing contract requires fuel at the final destination sufficient to reach a pump afterward, unless the destination itself provides a refill. Confirm whether that includes remote campsites and how long-stay/loop riding is requested, without silently assuming an overnight stop refills the tank or adding unrequested future riding.

**Next question:** should destination arrival always retain enough usable fuel to reach a known reachable pump afterward, even when the rider's current route ends at camp?

### Richard's thirteenth clarification — retain the road route, expose fuel defects

This clarifies and supersedes inherited wording requiring fuel-on routing to fail as a whole when fuel verification fails.

**Confirmed intent:**

- Failure to find a fuel station must not by itself prevent completion/display of an otherwise routable road journey. Preserve the route while making its fuel-verification status honest.
- A route with failed or incomplete fuel planning is not a fuel-verified success. Do not hide the failure behind vague text such as “no logical station could be added.”
- Distinguish actual geographic/range limitations from implementation failures that miss usable stations. Richard reports visible stations on returned routes despite fuel-planner rejection; capture and investigate those as concrete failure cases.
- At every required waypoint, including a final remote campsite, retain enough usable fuel to reach the next required refill or a reachable onward pump. An ordinary campsite stop does not reset the tank.
- Validate actual legal road travel from camp to the pump, including the access road and required travel direction. Do not substitute straight-line proximity.

**Diagnostic proposal:** preserve station identity, source/version, inclusion or rejection reason, legal approach/departure reachability, actual route distances, remaining fuel, continuation outcome and search-completion status. Compare map-visible station data with the planner's fuel data; a displayed pump alone does not establish legal access or current source consistency, but unexplained omission is not acceptable. Use replayable cases to separate missing data, matching/connectivity defects, candidate pruning, range failure and exhausted search.

**Boundary:** “route should always complete” applies to fuel failure, not permission to invent a road across disconnected or legally inaccessible networks. Keep road completeness and fuel verification as separate result fields. Tests must assert both.

**Reserve interpretation:** retain the existing reserve-adjusted usable-range model; Richard's phrase “remaining fuel reserve” is interpreted as remaining fuel available for onward riding, not permission to consume the protected reserve. Make this interpretation clear in discussion and revisit if Richard intends otherwise.

**Next question:** how should departure fuel be supplied, especially for a new loop from camp or resuming a saved itinerary without a refill? Do not assume that creating/loading a route fills the tank.

### Richard's fourteenth clarification — every loop starts with fuel

**Confirmed intent:**

- For every generated Loop, make a real fuel station the first waypoint from the rider's current starting location, whether home, camp or hotel.
- The first station is a generated fuel waypoint with an explicit full refill. Subsequent loop planning uses full reserve-adjusted range from that refill and adds further fuel stops as necessary.
- The loop still returns to the original starting location. Inserting a first fuel stop does not change its return anchor.
- This reflects Richard's group-riding routine: start the day by refuelling together before the adventure.
- The previous destination-arrival requirement is intended to make a pump reachable after an overnight stop, rather than leaving the rider stranded at camp.

**Engineering limitation to discuss:** a prior plan establishes reachability only under its fuel assumptions and subsequent travel. It does not measure actual remaining fuel. New home/hotel starts, unrecorded riding and changed consumption may lack any prior arrival estimate. A mandatory first pump does not itself prove the initial leg is fuel-feasible. Never silently reset fuel at the creation of a Loop or mark its initial leg verified without a stated/confirmed starting-fuel basis.

**Proposals pending:** include the start-to-pump leg in the loop's displayed total distance and moving-time target; select the first pump using actual legal reachability and onward adventure fit, without a long dirt hunt before the morning refill; carry prior estimated remaining range as a suggestion subject to rider confirmation rather than treating it as telemetry. Scope of the all-loops first-pump rule when starting already at a station remains an ordinary zero-distance refill case to define.

**Next question:** allow a simple remaining-range confirmation for the first leg, with any prior arrival estimate prefilled, so the route can verify access to the mandatory first pump without assuming a full tank.

### Richard's fifteenth clarification — end-navigation summary, no starting-range confirmation

**Confirmed intent:**

- Do not require a starting remaining-range confirmation. Richard notes that many motorcycles lack useful fuel gauges and the app cannot observe riding performed outside it.
- In Loop, From Here and Plan a Route, Start begins navigation. Choosing End Navigation opens an “Are you sure you want to end navigation?” confirmation.
- Confirming the end shows recorded riding time, kilometres travelled, average speed and approximate remaining fuel expressed as kilometres of range.
- Give riders useful information without claiming knowledge of unrecorded riding or actual tank contents.

**Engineering proposals/limits:** derive ride statistics from recorded movement rather than planned geometry. Exact definitions of moving versus elapsed time and average speed remain to be settled. The remaining-range figure requires an estimation basis; ending navigation does not prove the next ride's starting fuel. The earlier proposal to confirm starting range is rejected. Initial estimate policy remains unresolved; do not silently describe an assumed full tank as measured fuel.

### Richard's sixteenth clarification — live fuel countdown and confirmed refills

**Confirmed direction:**

- Passing a pump must not silently reset estimated range to full. Richard agrees with explicit refill confirmation; exact placement/timing of the interaction remains open.
- Provide a visible estimated fuel-range countdown during navigation, potentially in the HUD. It follows tank state through the journey, not distance remaining to the destination.
- Richard proposes yellow when the rider passes a planned fuel station without refilling, and red when estimated fuel reaches the configured reserve threshold.
- Keep the rider clearly informed of estimated remaining fuel. UI layout and final warning interaction are not yet designed.

**Proposed operational semantics for review:** decrement the estimate using actual recorded travel from the last confirmed refill; a full-refill confirmation resets the estimate to configured full-tank range. A planned future refill can support planning assumptions but is not evidence of an actual refill. Missing a planned stop leaves the live estimate unchanged except for distance travelled. Confirming a refill clears a missed-refill warning; red takes precedence if reserve is reached.

**Keep two quantities distinct:** displayed estimated total range remaining to empty, and usable range before the protected reserve. Route planning uses the latter. For example, a configured 300 km full range and 10% reserve means reserve starts at an estimated 30 km remaining, not zero on a countdown that already deducted reserve. This display model is a proposal, not a final UI decision.

**Recommendations:** pair yellow/red with readable text or an icon rather than colour alone. Scope missed-stop detection to intended fuel stops, not every roadside pump. A closed or skipped pump should trigger review of reachable next-fuel options without claiming a safe continuation that has not been verified. Do not repeatedly interrupt while the rider remains in the same warning state.

**Still open:** initial fuel-estimate basis without a starting confirmation; partial refills; manual recording of unplanned refills; missed-pump detection; whether rerouting to another pump is automatic or offered; persistence across stopped navigation; and scope/timing of navigation changes relative to the live routing rebuild. These navigation requirements belong in the eventual plan; they do not authorise an incidental UI implementation during discovery.

### Richard's seventeenth clarification — automatic missed-fuel recovery

**Confirmed intent:**

- When the rider misses a planned fuel stop, automatically route toward a reachable replacement pump; no acceptance prompt is required before this fuel recovery.
- The missed stop may have been skipped for several reasons. Prioritise keeping the onward ride fuel-feasible rather than assuming rider intent or a refill.

**Proposed implementation requirements:** compute replacement reachability from the rider's current legal road position and estimated fuel remaining after actual recorded travel, without resetting the tank. Preserve rider-placed destinations and remaining anchors; adjust generated fuel stops and the affected route as needed. Prefer rural fuel where feasible, retaining the agreed necessary-urban-fuel allowance. An unconfirmed stop must not update actual refill state.

**Recovery boundaries to resolve:** distinguish missing a generated stop from passing a rider-placed fuel anchor that only the rider may remove/move. Do not silently delete a fixed anchor under this new rule. Define robust missed-stop detection so merely approaching, stopping on a forecourt, or GPS noise does not trigger rerouting. Avoid immediate repeated selection of the same missed pump for the current recovery without inventing a permanent closure. Interpret “next” as legally reachable and suitable for continuation, not merely nearest in a straight line or geographically ahead.

**Proposed presentation:** a brief non-blocking notice identifies the replacement; existing range/warning state persists until an actual refill is confirmed. If no alternative can be verified, preserve the road route and report whether there is an established fuel gap or incomplete verification. Never mark an unverified replacement as safe.

**Next question:** whether emergency fuel recovery may use a short legal retrace or highway connection to a known reachable pump behind the rider when no forward pump is reachable within remaining usable range. This is separate from manufacturing loops/retrace during normal adventure planning.

### Richard's eighteenth clarification — explained fuel backtracking and unavailable pumps

**Confirmed intent:**

- Fuel recovery may route backward to a reachable pump when necessary. Normal adventure-planning avoidance of pointless retrace must not block this recovery.
- Clearly explain why the rider is being routed in the other direction. The explanation should state the actual evidenced reason, not imply that all forward pumps were exhaustively ruled out if they were not.
- Account for the possibility that the selected fuel station is no longer active. Arrival at its location is not evidence that refuelling was possible.

**Proposals for discussion:** provide an easy “Fuel unavailable” action at a planned stop; exclude that station from the current recovery and find another pump using actual legal directions and estimated remaining range. Scope a rider's report to the current trip/recovery unless a separate verified data-update process establishes permanent closure. Do not treat a missed stop alone as a closure report.

**Safety/legality boundary:** routing backward means following a legal road route, not commanding an illegal U-turn. Preserve rider-placed anchors; if an unavailable station is itself a rider-created waypoint, record that it was visited but not refuelled and recover fuel without silently moving the anchor.

**Still unresolved:** refill confirmation may need “Full refill”, “Fuel unavailable”, and treatment of partial refills; labels and exact interaction require product review. Initial live-range estimate remains an open issue. No guarantee of station operation can be inferred from route tests or mapped pump presence.

### Richard's nineteenth clarification — one fuel-unavailable recovery

**Confirmed:** “Fuel unavailable” applies whether the station is closed or operating but cannot supply fuel, including payment-system failure. Use the same recovery: no refill reset, exclude the unavailable pump from the current recovery, automatically find a reachable replacement, and explain necessary backtracking. This is not permission to permanently mark the station closed for other riders.

**Discovery direction:** return to ride-quality scoring rather than continuing minor fuel interaction questions. The principal fuel intentions are captured; unresolved initial fuel estimation, partial refills, detection and evidence limits remain visible for the technical/scenario review.

**Next scoring question:** should Balanced's approximate 50/50 goal apply over the primary rider-to-rider leg, allowing unequal fuel sections and long continuous surface stretches, rather than forcing 50/50 independently between every generated pump? Proposal: evaluate the mix across the owning primary leg unless the rider explicitly overrides a fuel section in From Here. Loop aggregate and explicit mixed-style overrides need corresponding definitions. Do not turn surface balance into frequent switching or let generated pump placement redefine the selected ride character.

### Richard's twentieth clarification — existing reroute entry and dirt-leaning Balanced

**Confirmed intent:**

- Use the existing navigation reroute function for fuel recovery. Reasons such as “gas station closed”, “gas station not active” or “unable to obtain fuel” launch fuel-station location/recovery. Do not introduce a separate competing navigation flow merely because discovery used the shorthand “Fuel unavailable”. Exact labels and current implementation require inspection before changes.
- Balanced's surface mix is evaluated across the primary rider-to-rider section, not independently across every generated fuel section. Sustained dirt and paved stretches are acceptable.
- Balanced should skew slightly toward dirt rather than pavement. This refines the earlier near-50/50 intent; no exact revised target percentage or tolerance has been selected.
- Where feasible, incorporate fuel stops into the paved portions during route construction. Richard presents this as an opportunity for coherent ride design, not a requirement to defer necessary fuel or put every station on pavement.

**Proposed scoring interpretation:** compare whole primary-leg surface composition, favouring modestly dirt-heavy alternatives near the target. Do not assume the statement establishes a 55/45 target or makes a much more dirt-heavy ride automatically preferable to a closer balanced result. Use pavement connections productively for fuel where possible, while preserving rural preference, legal station access and actual fuel feasibility.

**Next question:** resolve whether “slightly toward dirt” means a default target such as 55% dirt, or a preference for the dirt-heavy option among similarly balanced candidates. A concrete 55% versus 45% example can establish preference without prematurely fixing a target; then compare 65% versus 48% to clarify the tradeoff if needed.

### Richard's twenty-first clarification — Balanced proximity and profile consistency

**Confirmed intent:**

- In the otherwise comparable 48%-dirt versus 65%-dirt example, Balanced selects 48% because it is closer to half. Do not interpret a slight dirt bias as chasing substantially more dirt.
- Dirt must seek substantially stronger dirt content where the legal, fuel-feasible network supports it. The example's 65% is neither a Dirt target nor a quality ceiling.
- Richard reports the frustrating failure of Balanced producing more dirt than Dirt. Treat that as a cross-profile search-quality defect to reproduce and prevent, not an acceptable consequence of independent scoring implementations.
- Retain near-50/50 Balanced intent with a slight dirt preference around equivalent balance; do not assert a revised fixed percentage target from this discussion.

**Proposed acceptance invariant:** with identical graph, anchors, access, fuel assumptions and applicable ride-length/area constraints, a more dirt-rich feasible candidate found by Balanced is evidence available to Dirt. Dirt should not return a lower-dirt result merely because its separate search strategy failed to consider that candidate. Compare like-for-like constraints and measured known-surface statistics; explicitly differing rider preferences are not a valid baseline for this invariant. Do not require running two full profile searches for each request; evaluate shared candidate/search evidence and offline cross-profile fixtures in architecture design.

**Honesty boundary:** 100% remains the Dirt aspiration, not a guarantee that the source network can support it. Required endpoint access and feasible fuel connections still count accurately as pavement. Avoid promising a fixed minimum percentage for every geography.

**Next discussion:** use a concrete ride with a long continuous dirt section accessible by a legal shared entrance/exit stem to distinguish a worthwhile deliberate excursion from the rejected tiny loop returning to an already visited junction. Existing broad no-retrace rules need that boundary before search design.

### Richard's twenty-second clarification — onward connections over attached circuits

**Confirmed intent:**

- For destination riding (From Here and Plan a Route), favour dirt connections that emerge onward toward the remaining journey.
- Reserve deliberately attached circuits returning to their entry junction for Loop or explicit rider-chosen waypoints; do not add them simply to increase dirt statistics.
- Richard's experience is that substantial dirt circuits commonly have multiple junctions and alternative exits, with terrain-specific exceptions such as a circuit around a mountain. Inspect available legal graph connectivity rather than assuming every circuit is single-access or inventing an exit.
- This is a coherence preference, not a requirement for every individual edge to reduce straight-line distance to the destination. Geography can require lateral or temporarily backward travel on a valid onward connection.

**Architecture implication:** candidate generation should look for distinct onward exits and meaningful connected dirt riding. Do not use a universal no-cycle/no-retrace implementation that breaks loop generation, rider-requested visits, necessary endpoint access or agreed fuel recovery.

**Next discussion:** minimum necessary repeated-road access to a fixed rider waypoint on a dead-end road (for example a campsite). Confirm that access can be as long as geography requires rather than blocked by a universal short-stem cap; distinguish this from automatically adding an unrequested dead-end dirt excursion.

### Richard's twenty-third clarification — necessary access to rider anchors

**Confirmed:** a rider-chosen campsite 12 km down a dead-end road permits the 12 km return along that same road when required to continue. Do not impose an arbitrary short-distance cap on necessary access to a deliberately selected rider waypoint. Continue respecting legal direction, access and fuel feasibility. This does not authorise automatically adding unrequested dead-end excursions to improve dirt statistics.

**Next discussion:** distinguish meaningful variety from total road non-overlap. For consecutive loops with identical camp, direction and distance, propose minimising repeated adventure sections while permitting shared necessary access/fuel roads. If the network cannot supply a distinct suitable ride, communicate limited alternatives rather than manufacturing extra distance or claiming novelty.

### Richard's twenty-fourth clarification — fuel access stems

**Confirmed:** normal access to a fuel station can require riding 100–200 m in and the same distance back out. Permit this necessary station access; do not treat it as a pointless dirt excursion or reject a reachable station solely because its access road is reused. The distances are examples, not a newly accepted exact cutoff. Respect actual legal entrance/exit directions and geometry. This clarification covers ordinary pump access; it does not automatically approve arbitrary long generated fuel detours.

The preceding question about trading riding style against variety remains unanswered; this clarification supplements the access rules rather than answering it.

### Richard's twenty-fifth clarification — variety within riding style

**Confirmed:** preserve the selected riding style and find different roads where feasible. Variety is important across the three flows, but should not turn a requested Dirt ride into a different riding style merely to avoid overlap. Shared necessary endpoint/fuel access is acceptable.

**Proposed acceptance:** requesting another ride should yield meaningfully different main riding sections when feasible, not cosmetic geometry changes or tiny detours. Retain the same rider anchors and applicable distance/time/direction preferences. Do not promise a wholly unique route where the legal, fuel-feasible network lacks alternatives. The amount of permitted quality variation and meaningful overlap thresholds need scenario-based evaluation rather than invented constants.

**Next discussion:** distinguish explicit variation from ordinary recalculation. Recommend keeping an accepted route stable until the rider requests another ride, edits relevant intent, or actual navigation/fuel recovery requires a change. Saved-route reload should preserve the chosen ride, subject to legal/data changes and necessary rejoining; merely opening/reloading/recalculating should not silently generate a new adventure.

### Richard's twenty-sixth clarification — stable built routes, variation on edits

**Confirmed intent:**

- Once built, the selected route is the rider's route: saving, reopening and starting navigation preserve it. It must remain savable and navigable, rather than being regenerated from pins on each load/start.
- Changing a leg from Dirt to Balanced and back to Dirt need not restore the original Dirt geometry. A relevant edit may generate a new alternative.
- Moving a waypoint or rerouting can create new geometry. Rider waypoints are the mechanism for defining specific places a route must visit.
- This affirms keeping a built route stable until an intentional relevant change or necessary recovery. It does not require regenerating unaffected legs during an edit.

**Proposed implementation contract:** persist selected route geometry/road identity alongside the request, generation identity, source identity and fuel-plan status. Preserve unaffected sections where feasible and revalidate relevant fuel dependencies. Necessary changes due to road/access data revisions or current-position recovery must not be hidden as ordinary variety. Navigation recovery serves the reported problem and remaining itinerary; it is not permission to randomly replace the rest of the adventure.

**Clarification of earlier explicit-variety proposal:** Richard previously agreed that another ride should seek variety while preserving style. The exact UI action for requesting a new alternative remains undecided. Do not interpret this latest list of edit/reroute examples as authorising random changes on every background recalculation.

**Next discussion:** loop distance/time targets are approximate; establish the acceptable tradeoff between a strong adventure slightly over target and a weaker/shorter route, especially for a rider with limited time. Do not silently choose a fixed tolerance or treat a requested maximum as a suggestion.

### Richard's twenty-seventh clarification — recovery continuity, approximate loop targets and complexity

**Confirmed:** navigation rerouting preserves the expected riding character toward the current rider waypoint. Loop distance is an approximate target; no numeric tolerance or maximum-distance control was accepted. Richard asks whether accumulating nuance risks recreating the engine's complexity.

**Process correction:** pause open-ended questioning and consolidate the captured intent into a small coherent policy. The chronological record is decision evidence, not a design with one branch per answer. Use representative scenarios to expose material remaining contradictions; defer UI details and tuning until they affect architecture or acceptance. Do not claim extraction is exhaustive or that a particular algorithm is selected.

### Consolidated policy draft — replacing the question-by-question implementation model

1. **One ride request:** choose From Here, ordered Plan, or Loop. It carries fixed rider anchors, per-primary-leg riding style and applicable loop direction/time/distance intent. Fuel stops are generated service stops, distinct from fixed rider anchors.
2. **One legal-road foundation:** source connectivity, direction, vehicle access and turns govern all modes. Never invent connections. Road surface and estimated fuel state remain honest data, not scoring fiction.
3. **One profile objective per owned section:** Dirt seeks coherent known dirt near 100%; Balanced seeks near 50/50 with a modest dirt-side preference among comparable balances; Clean seeks paved back roads. Avoid larger urban areas, welcome rural towns, and use less-desired roads as necessary connectors. No hidden shortest-path product objective. Exact settlement/necessity criteria need evidence-based design.
4. **One fuel-feasibility model:** remaining usable range carries through ordinary anchors, full-refill assumptions support planning at real stations, and live estimates reset only on confirmed refills. Include onward fuel reachability at the final destination. Prefer rural pumps, permit necessary urban fuel, refuel early where appropriate. Every Loop starts with fuel. Planning and navigation estimates are distinct states.
5. **One route-coherence policy:** favour onward connections for destination rides; don't manufacture dirt using small cycles. Permit necessary rider-anchor and station access and explicit recovery. Loop intentionally returns to its origin; do not apply a destination-only no-cycle rule to it.
6. **One editing and recovery boundary:** retain committed geometry until relevant edits/recovery. Rebuild affected sections while preserving rider anchors, ride style toward the active waypoint and feasible onward continuation. A primary style change governs its fuel sections. Finer fuel-section style controls remain provisional for From Here.
7. **One variation mechanism:** find meaningfully different candidates within the chosen style and constraints when a new alternative is requested/generated; don't reshuffle accepted geometry on reload/start. Ordinary recovery solves its cause rather than randomly changing the whole trip.
8. **One honest result contract:** road completeness and fuel verification are separate. Keep a routable road journey when fuel verification fails. Distinguish actual range/connectivity limitations, missing/inconsistent data, search exhaustion and code defects with replayable diagnostics.

**How to avoid reproducing bloat:** consolidate repeated decisions rather than add per-scenario penalties; keep product rules separate from search optimisations and presentation; use one end-to-end work budget and reusable request data; make each fallback's necessity and scope explicit. Do not assume this policy alone guarantees speed: evaluate algorithms on representative graph sizes, memory, repeated work and verified candidate quality. Avoid representing everything as one opaque weighted score; legal eligibility, fuel feasibility, ride preferences and execution limits have different meanings.

**Next deliverable:** a concise current-intent specification with source-linked evidence, a finite scenario matrix and a short material-open-decisions list. Then compare architecture/search approaches and produce the staged build plan. Do not pursue incidental navigation UI implementation or a wholesale rewrite before that comparison. The known initial-fuel-estimate uncertainty remains unresolved; no promise of a safety proof from an unknown starting tank.

## Proposed architecture boundaries to evaluate

These are responsibilities, not a commitment to extra services or an elaborate framework.

1. **Ride request:** mode, anchors, distance/time/area expectations, profile, rider preferences, fuel settings and source GPX identity where relevant.
2. **Road facts and eligibility:** immutable source identity, exact connections, direction, access, restrictions and honest surface information.
3. **Ride policy:** one explicit ordering of requirements and preferences, with explainable defaults and controlled rider adjustments.
4. **Search:** mode-appropriate candidate generation with reusable graph work, shared cancellation and an end-to-end budget. Do not assume loops and destination searches need the same algorithm.
5. **Fuel feasibility and selection:** validate and influence complete ride candidates without repeatedly rebuilding every pump approach with the full preference search.
6. **Result and explanation:** geometry, actual distance/surface, fuel evidence, compromises, unresolved sections and reproducibility information.
7. **Product integration:** pin search, editing, GPX, navigation and eventual offline implementations consume a stable ride contract.

The exact search algorithms, precomputation, runtime hosting, memory model and cache strategy require a technical comparison after the objectives are agreed. Preserve validated legal and graph components unless evidence shows they cannot support the accepted design.

## Evidence and validation plan

Build a fixed journey collection from actual successes and failures plus new exploration scenarios. Include local loops, sparse fuel, dense cities, dead-end access, both border directions, ferry routes, multiple pins, unknown access, GPX crossings and disconnected roads.

For each case define expected rider behaviour before changing the engine. Record graph and engine identity, request settings and reproducible variation. Measure cold and warm loading, matching, candidate search, fuel proof, total time and memory. Agree on typical and slow-case latency targets; a deadline is not a performance target.

Compare correctness, ride quality and speed together. An incomplete search must not become “no road” or “no fuel.” A route may only claim fuel verification for the geometry actually returned. Automated checks and Richard's physical acceptance remain separate evidence.

## Deliverables and order

1. **Intent specification:** concise rider rules and worked examples, with decisions and unresolved questions recorded.
2. **Evidence map:** where each behaviour comes from, what worked, what failed and which existing components to retain or replace.
3. **Architecture decision:** candidate algorithms and execution design evaluated against accepted modes, constraints, scale and measured baselines.
4. **Executable build plan:** ordered milestones, affected components, dependencies, acceptance checks, rollback path and explicit deferred work. Each milestone must have an observable rider outcome.
5. **Implementation and comparison:** build in isolation, compare with the baseline, then verify in DEV and collect rider acceptance before retiring old paths.

Current work is at steps 1–2. The build plan is intentionally not final while foundational product choices remain open. Existing live-first scope remains in place unless Richard changes it; later Swift and Android parity must be planned explicitly.

## Evidence sources

- `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`: profile, fuel, waypoint and historical performance intent.
- `docs/ROUTING-EVOLUTION-SPEC-2026-09-07.md`: forward progress, variety and fuel-foundation intent, including recovery clarifications and failed implementation history.
- `docs/GPX-IMPORT-TO-DIRT-PLAN.md`: preservation, reachable entry, direction and conversion intent; currently documented as a later milestone.
- `docs/ROUTING-CONSOLIDATION-REVIEW.md`: prior feature inventory and recorded rider acceptance claims, not fresh verification.
- Live-baseline worktree `.build/atlantic-live-fuel`, commit `b3cb2fa2a9ef32f1f8f3b47ed860eb30ab792fdc`: `find-path-v2.js`, `router.js`, `fuel-chain.js` under `scripts/pack-fabric/routing/lib/`.
- Richard's September 8 conversation: current authority for this broader redesign and discovery process.

This inventory is a first extraction, not an exhaustive completed audit. In particular, rider-adjustable scoring history, all app entry points and complete code-to-rule traceability still need review.
