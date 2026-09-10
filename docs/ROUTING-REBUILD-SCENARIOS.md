# Routing replacement: acceptance scenarios

Review draft, 8 September 2026. This is a test specification, not a report of passing tests. Use [the product specification](ROUTING-REBUILD-SPEC.md). Keep small synthetic graphs for invariant proofs and real journeys for quality/performance; neither substitutes for the other.

## Required scenarios

| ID | Scenario | Observable requirement |
| --- | --- | --- |
| R01 | Same anchors/settings routed as Dirt and Balanced | Dirt does not overlook a more dirt-rich feasible candidate discovered by Balanced. Record total/known dirt/paved/unknown distance, not only a headline percentage. |
| R02 | Balanced candidates at 48% and 65% dirt | Choose 48% with otherwise comparable requirements. Evaluate balance across the owning primary leg, not independently around every pump. |
| R03 | Token dirt spur or small cycle versus meaningful onward dirt | Reject gratuitous excursion; retain required connecting edges. No percentage inflation by circulating. |
| R04 | Long dirt connection temporarily heading away from destination | Keep eligible; no crow-line-only rejection or hidden shortest-distance product cap. |
| R05 | Rider campsite 12 km down a dead end | Visit fixed anchor and permit legal return; validate fuel through access and departure. |
| R06 | Pump with shared 100–200 m access or separate one-way entrance/exit | Accept legal station access; no synthetic connection, illegal turn or blanket retrace rejection. |
| R07 | Rural route around a large city versus shorter city cut-through | Choose rural adventure. Small rural towns remain usable. |
| R08 | Geographic bottleneck or rider pin inside large urban area | Permit scoped urban/highway access automatically. Test against an open-rural alternative, not only the forced case. |
| R09 | Longer feasible rural fuel chain versus closer urban pump | Prefer rural. In a separate no-rural-continuation fixture allow urban fuel automatically. |
| R10 | Early rural refill before substantial dirt | Refill early; 75% timing and stop-count heuristics do not destroy feasibility. |
| R11 | Required refill 10 km before fixed rider fuel waypoint | Keep both planned refills and fixed rider waypoint. |
| R12 | Remote destination with insufficient fuel to leave | Adjust upstream fuel/ride where feasible; otherwise preserve road route and report verified gap or incomplete evidence accurately. |
| R13 | Stations visible on the returned route but none selected | Trace source identity, eligibility, legal matching, candidate inclusion and rejection. Detect a deliberately seeded omission defect; do not label it geographic scarcity. |
| R14 | Same route with proved range gap, disconnected road and search timeout | Three distinct outcomes. Fuel failure retains complete road geometry; disconnection does not fabricate a road; timeout is not no-path proof. |
| R15 | Primary style edit; internal fuel-section edit | Primary edit updates contained styles. Fixed anchors survive. Reuse unaffected work and validate downstream fuel dependency. Finer controls remain provisional. |
| R16 | Save/reload/start, then style toggle or moved anchor | First group preserves geometry. Relevant edits may generate different affected geometry. No incidental whole-trip shuffle. |
| R17 | Loop from camp/home/hotel | First waypoint refuels; final anchor is original start. Include actual connector/fuel geometry in displayed totals. Approximate target and preferred direction are evaluated explicitly. |
| R18 | Two requested Loop alternatives with identical settings | Meaningful main-road variation where feasible; preserve style. Shared necessary access is acceptable. Honest limited-alternative result on constrained network. |
| R19 | Missed or unavailable pump during navigation | No refill reset; automatic legally reachable replacement based on estimated remaining fuel. Backtrack when needed and explain. Never loop back to an excluded unavailable pump. |
| R20 | Rider-created fuel anchor missed/unavailable | Do not silently move/delete fixed anchor. Distinguish actual visit from refill and retain itinerary intent. Product handling of an unvisited skipped anchor needs scenario review. |
| R21 | Directional borders and ferries | Both directions; true topology, matching and turn constraints. No fuel reset at border and no invented crossing. |
| R22 | Existing ride → saved trip → local loops → resume | Saved geometry remains; resume selects appropriate remaining stage without erasing rider anchors or forcing restart. Later app integration. |
| R23 | GPX preview and later generated continuation | Original line survives; no silent replacement or fake disconnected connector. Later integration. |

## Real evidence collection

Use immutable pack/source identity for each run. Existing evidence includes NS Porters Lake-area to southwest NS; near-Montreal failures during NB handoff; northern Quebec fuel-continuation cases; dense Ontario searches; Atlantic borders/ferries. Retrieve exact requests from retained exports/replay artifacts rather than reconstruct coordinates from prose.

Richard's Shediac/Dieppe example and long multi-waypoint trip are proposed scenarios, not established proofs of topology. Obtain precise anchors before treating them as regression fixtures. Loop examples need representative local connected and constrained networks.

Start with a bounded representative set: local rural, dense urban surroundings, sparse fuel, cross-region and Loop. Expand when a mechanism fails; don't repeatedly rerun every expensive case after prose or cosmetic changes.

## Evidence recorded per run

- Request, fixed anchors, profile/access, initial fuel assumption, reserve, requested variation and loop settings.
- Engine revision, graph/fuel versions, cold/warm conditions and execution environment.
- Road completeness and fuel verification separately; candidate and rejection reasons.
- Total/known dirt/paved/unknown distance; overlap, repeated access versus gratuitous cycles, settlement/highway use and reasons.
- Fuel arrivals/departures and onward escape at destination, using actual selected geometry.
- Loading/decoding, matching, search and fuel work, total response time, peak memory where measurable, expansions, candidate count and repeated full-search count.

Report typical and slow-case latency by scenario and cold/warm condition. Do not claim production percentiles from a handful of local runs. No fixed latency or overlap threshold has yet been accepted; establish these before final qualification, using the measured baseline and rider review.
