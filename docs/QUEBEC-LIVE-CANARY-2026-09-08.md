# Quebec live canary — September 8, 2026

Live JavaScript only. Quebec rebuilt using the Atlantic toll/access correction from the locked September 6 OSM source. Candidate fabric-v4-20260908-02 reuses the accepted Atlantic graph, geometry, fuel and rider-service bytes without rebuilding them, and regenerates connection records for NS, NB, PE, NL and QC. Original releases remain unchanged.

Quebec graph: 8c9a422b1d149ebd187963672620b269b50246461e16748f33d57da428db0f3b. Factory commit: 0d7553663dd3fc7f71dc3fa9cc07b7bb678e699e. Per-region reuse provenance is in release.json.

Purpose: verify the larger pack and Atlantic connections before wider rebuild. Automated live and physical acceptance remain pending. Route quality is a separate unresolved task. No Swift changes, phone installation, download publication, or production publication. Future Swift/Android parity must reproduce accepted live changes; none is claimed by this data-only canary.

## Shared connection corrections found by Quebec testing

The first live attempt failed four of six Quebec border requests. A fifth returned a 558 km detour for a roughly 4 km Campbellton bridge trip and is also a failure. The pack files loaded correctly. The live handoff chooser ranked a preset border location rather than the rider's endpoints, admitted unknown-access crossings with Allow Unknown off, and accepted roads present in both extraction halos even when isolated from one region's connected road network.

The shared JavaScript chooser now ranks proven crossings against adjacent route endpoints, honors access policy, and filters shared halo fragments against each available rider endpoint's connected road network. Actual searches still enforce travel direction and turn restrictions; a component match alone is not a route proof. Intermediate regions without a rider endpoint remain subject to actual hop searches. This applies to routing and fuel planning through their shared seam resolver, without edits to surface preferences or Swift.

Local checks pass both directions for Campbellton, Edmundston–Dégelis, and Fermont–Labrador City. Campbellton returns 3.7 km. Both Sorel ferry terminal directions pass. Six Quebec highway/overpass/ramp checks match actual OSM travel direction and continuity. 57 targeted JavaScript checks pass, including a disconnected shared-fragment fixture, access gating, direction, and fuel limits. Live checks of the new source remain pending.

Known separate failure retained: the street pin at (-73.1125, 46.0463) selects a destination-only driveway loop on departure and fails to leave through the adjoining destination-only driveway; its reverse and both ferry-terminal tests pass. The pack preserves the actual source driveway and ferry. Do not claim this pin failure repaired or erase it from acceptance records. Route quality remains unaccepted. No nationwide rebuild until Quebec gate is accepted.

### Regression caught before stable publication

Preview dbab1ef passed all six Quebec border routes but failed the previously accepted NB→NS test. Weak (directionless) connectivity was insufficient, and a retry discarded the filtered crossing list. The chooser now walks outgoing legal arcs from the departure and incoming legal arcs from the arrival, honors access policy, and retains its filtered alternatives during retries. Existing actual route searches remain responsible for turn restrictions and final path proof. The NB→NS regression and all Quebec border checks pass locally; a synthetic one-way fixture checks both departure and arrival.

56 focused tests pass after these changes (the earlier 57-test run also included two network-dependent cross-province tests; the new focused run adds the directed fixture and excludes those two in favor of explicit candidate replays). DEV deployment enables the existing ROUTING_CHAIN_CACHE=1 setting. The compact packs use the existing three-pack LRU; connection checking and fuel hops reuse loaded packs instead of re-downloading Quebec in the same request. The default production setting is unchanged. Final live replay and stable alias verification are required before the handoff.


## Physical acceptance and fuel follow-up

Richard accepted long live routes between Halifax, Quebec and Labrador on September 8. Export `dirt-app-debug-2026-09-08T140232Z.txt` records build 8ae00633, successful route responses, and a remaining final-stage fuel gap. National rebuilding has not started.

The failing fuel request fuel-1f656dd6 found 544 reachable pumps, routed six candidates completely, then rejected all six for previous-road overlap. A local replay with the four history IDs retained in the export (the original had 17) reproduces the same rejection class: 8,728 m of prior-road reuse. It is a mechanism reproduction, not an exact replay of the phone's complete history or warm candidate cache.

Repair: evidenced overlap with previously committed roads remains in ranking and diagnostics but is no longer a hard fuel-feasibility veto. Unknown/unexplained retrace remains subject to the existing cap. A continuation reusing roads from the newly proposed pump approach remains subject to the fuel-stem cap, even if those roads also occur in old history. Fuel range, legal access, road packs and route search are unchanged. Live JavaScript only, per Richard; Swift/Android parity follows acceptance.

Local result: previously failing location pair now returns four pumps with approach distances 266,026 / 332,654 / 321,271 / 165,784 m, all within 333,000 m. All 43 fuel-chain tests pass, including new committed-history coverage and existing meaningful fuel-stem rejection. Deployment and physical retest pending at this commit.
