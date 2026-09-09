# Route controls — September 9, 2026

Initial implementation (superseded by the dedicated Loop section below): Loop appends the current plan’s first waypoint; full-screen ride settings beside fuel offer wander and city/highway avoidance; downloaded packs have Update and working Delete across cached revisions. Replacement packs are staged and verified before switching. Navigation protection is checked again after awaits before deleting or publishing a replacement.

Verification: 19 Swift tests passed in RidePreferencesTests and PackFirstRoutingTests, including Loop identity/rebuild boundary, optional payload isolation, old options decoding, and deletion of old/current NS revisions without deleting NB. Simulator settings layout checked in portrait and landscape, including cancelling edits. No physical-device installation or acceptance is claimed.

Backend work remains separately committed in routing-rebuild (513f014, 337020c). 202 adventure tests passed. Final isolated preview https://pack-fabric-qe2ckrazy-goricksmith-7678s-projects.vercel.app preserves default southwest NS route geometry and fuel stops exactly. Custom direct and exploring/highway-avoidance requests both complete. Custom settings are currently qualified only for live NS/NB; offline custom planning explicitly reports unavailable.

Historical release hold (superseded below): the pack-owner task is uploading/verifying the national catalog. Do not update AppConfig catalog/seams or promote this preferences preview over that work. Combine the preference commits with its verified national candidate, repeat default and custom hosted checks, then update both catalog and seam paths and produce the DEV app. Current stable DEV and the phone have not received these controls yet.

## Coordinated DEV activation

Richard authorized DEV-now rollout while remaining national uploads/checks continue. Combined service source `a64270857b2e246edaf135fffa50d82fbba3b66e` is active at `pack-fabric.vercel.app`, preview https://pack-fabric-p2fgmm4id-goricksmith-7678s-projects.vercel.app. It preserves national source3e40760 plus optional preferences. 204 adventure tests and63 Swift tests passed. Combined hosted default NS geometry/fuel hash exactly matches accepted baseline; direct custom route completes. Main app catalog and all pack file/seam URLs updated in9858a1c to the09candidate. Catalog publication still belongs to pack-owner task. No physical-device install occurred. Existing national OOM and incomplete-upload issues remain recorded in dev-activation.json.


## Dedicated Loop and Create Return Route

The Route mode strip now uses compact SF Symbol/title tabs on system material, with dark orange selection: From here, Loop, Plan a route, Saved. The existing bottom app dock is preserved. Start actions adapt to large text, and the distance slider exposes kilometres to accessibility.

Create Return Route is available for an open From Here or planner itinerary with at least two distinct endpoints. It keeps the outbound legs and appends the start. It requests a stronger positive preference against recently ridden roads, without forbidding unavoidable access roads.

Loop has its own setup: current or map-selected start, a map-selected direction guide, 50–500 km total target distance, existing ride style/settings, and Create Loop. The direction tap guides the search rather than becoming a required destination. Three candidate circuits run through the canonical itinerary/fuel builder. The third adjusts its size using measured results; incomplete candidates are discarded. Ranking combines distance error, whole-circuit shared-road estimate and reused stations. Actual distance and estimated shared kilometres are shown. Changing direction or distance requires rebuilding. Leaving during a search cancels it; stale results cannot replace the current plan.

Backend source 993258b6c51720e0219fcb4e3467a2e714aaf06f adds optional preferDifferentRoads on the combined national-controls source. It increases existing prior-road cost from 4 to 16 only for opted-in requests. Default hosted southwest NS fixture remains exactly 469779.4375069987 metres, two pumps, geometry SHA256 9f50ad7c5cf45d8a2221a97230157ba816aed3e3deea0936a28dcb36cdf3d29c.

Hosted NS candidate evidence: a 150 km target produced complete 187.5, 275.0 and 235.9 km circuits, all closing on identical snapped start/end coordinates and satisfying each fuel range cap. Shared-road estimates were 12.6, 18.2 and 12.7 km respectively. The feedback-adjusted candidate was incomplete and rejected, retaining the 187.5 km winner. This is evidence of bounded candidate selection, not a promise of exact target distance or zero overlap. Recent-road cost uses the existing bounded arrival history; whole-circuit ranking also measures earlier overlap.

Qualification remains live NS/NB for personalized routing and Loop. No national/offline Loop parity or physical-device acceptance is claimed. Navigation algorithms are unchanged. Phone installation remains Richard’s Xcode step.


Final verification: 22 Swift tests passed in LoopPlanTests, RidePreferencesTests and PackFirstRoutingTests; 205 adventure engine tests passed. Signed iPhone DEV build succeeded and verify-ios-development.sh passed. Impeccable reviewer scored the three accessibility corrections resolved: reflowing start actions, kilometre slider value, and readable tab sizing at maximum text size. The visible planner label is shortened to Plan; its full accessibility label remains Plan a route. No broad accessibility certification is claimed. Richard requested iPhone-only testing; the temporary iPad simulator was shut down and deleted.

DEV alias pack-fabric.vercel.app now points to preview https://pack-fabric-63bnz1smh-goricksmith-7678s-projects.vercel.app (993258b). Stable POST fuel-chain returned complete and the expected candidate09 NS identity. Activation and guard records preserve previous activations, ongoing uploads and known memory failure. Production was not changed and the phone was not installed.

## Current Loop setup — simplified GPS loop

This section supersedes the start/map-direction setup described above. Loop now starts and ends at the rider’s current GPS location. Its compact glass group contains Direction (eight compass points, initially North), Distance (50–500 total kilometres in 25-kilometre steps, initially 100 km), and Surface (the existing route profiles). There is no start selection, map pin, or “towards” step.

Create Loop is available without placing pins. It requests/checks location authorization and reports missing permission or a pending location fix inline. During generation, controls are disabled and progress offers Cancel. The current-location start is also the circuit end. Existing candidate selection, routing/fuel validation, result summaries and the separate Create Return Route action remain in place. Exact target distance and zero road overlap are not promised.

At accessibility text sizes, the control and progress rows stack vertically; menu controls expose their labels and values, and the distance slider announces kilometres. Create Loop uses the shared brand style with dark text on orange. The existing compact four-tab glass treatment and bottom dock are retained. Richard approved that glass/icon-title/orange-active language as the baseline for all future UI; root DESIGN.md records that direction without authorizing a global redesign.

Verification for this simplification: nine focused tests passed. The final simulator and signed iPhone builds succeeded, and development verification passed. Normal layout, compass selections, active Create Loop and permission feedback were inspected; maximum-text rows reflow without overlap. Full maximum-text scrolling was not established through simulator automation. Testing is iPhone-only; no iPad testing, Android qualification or physical-device acceptance is claimed here. Earlier verification above applies to its stated revision and does not qualify this final UI change.


## Loop result view — 2026-09-09

After generation completes, Loop displays its legs and a bottom Clear button. Setup fields, creation button, summary, statistics and other route actions are hidden in this result view. Clear directly resets the route and restores the Loop setup, preserving the rider's direction, distance and surface selections. The tab menu stays available. No simulator was launched for this change; signed iPhone build verification is recorded separately.


### Loop result correction

Completed Loop retains the standard route result: legs, routing/fuel/ferry notices, route statistics and Save/Export/Start actions, followed by Clear route. Only Loop creation controls remain hidden. Clear continues to restore setup with prior selections. This supersedes the legs-only result above.


## Fuel-stop replacement restoration — 2026-09-09

Tap an F pin or its route row in From Here, Loop or Plan a Route. Nearby alternatives appear progressively only after the entire forward itinerary validates, preserving upstream geometry. Tap an alternative to commit the checked result. The app checks the nearest six different canonical stations within 25 km; pending checks cancel on route changes, tab changes or navigation. Original routes remain intact when a candidate cannot be proved. Fuel pins are fixed station anchors, never freely draggable.

The NS/NB live adventure service now supports requiredFirstStationId with a fuel-bounded approach that cannot refuel at another station first, followed by a proved continuous continuation. An explicitly chosen pump needs individual route feasibility rather than completed comparisons of every alternative objective; normal route selection is unchanged. Station entrances and availability remain provisional mapped evidence.

Verification: 212 JavaScript tests pass, including fuel limits, canonical identity, disconnected/unproved continuation rejection and default comparison behavior. Hosted short and long swaps pass exact geometry continuity, fuel-range and destination escape checks; the longer replacement has hops of 218.934 km and 60.477 km on 225 km usable range. Unchanged default Atlantic request reproduces identical geometry and fuel stops. Stable DEV source 476230d4bfa3ed8b5fed16514e2908266b691b63 includes the separately verified BC–WA memory repair and preserves all63 candidate09 regions. Signed generic iPhone build and development isolation checks pass. No simulator was started, no build installed onto White, and physical-device or offline acceptance is not claimed. Evidence: scripts/pack-fabric/routing/candidates/fabric-v4-20260909-01/fuel-replacement-verification/summary.json.


### Accepted and frozen — 2026-09-09

Richard tested fuel-stop replacement on White and reported: “That worked perfectly. Freeze that. That's perfect.” This supersedes the pending physical-device acceptance above for this feature. Freeze the accepted interaction across From Here, Loop and Plan a Route: tap an F stop, reveal checked nearby alternatives, and tap to replace while preserving upstream legs. Baseline iOS commit904f11f and live backend476230d4bfa3ed8b5fed16514e2908266b691b63. Future routing/national changes must preserve this behavior; do not redesign or retune it without Richard reopening the scope. This acceptance does not qualify untested national or offline behavior.
