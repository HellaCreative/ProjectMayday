# Quebec live canary — September 8, 2026

Live JavaScript only. Quebec rebuilt using the Atlantic toll/access correction from the locked September 6 OSM source. Candidate fabric-v4-20260908-02 reuses the accepted Atlantic graph, geometry, fuel and rider-service bytes without rebuilding them, and regenerates connection records for NS, NB, PE, NL and QC. Original releases remain unchanged.

Quebec graph: 8c9a422b1d149ebd187963672620b269b50246461e16748f33d57da428db0f3b. Factory commit: 0d7553663dd3fc7f71dc3fa9cc07b7bb678e699e. Per-region reuse provenance is in release.json.

Purpose: verify the larger pack and Atlantic connections before wider rebuild. Automated live and physical acceptance remain pending. Route quality is a separate unresolved task. No Swift changes, phone installation, download publication, or production publication. Future Swift/Android parity must reproduce accepted live changes; none is claimed by this data-only canary.

## Shared connection corrections found by Quebec testing

The first live attempt failed four of six Quebec border requests. A fifth returned a 558 km detour for a roughly 4 km Campbellton bridge trip and is also a failure. The pack files loaded correctly. The live handoff chooser ranked a preset border location rather than the rider's endpoints, admitted unknown-access crossings with Allow Unknown off, and accepted roads present in both extraction halos even when isolated from one region's connected road network.

The shared JavaScript chooser now ranks proven crossings against adjacent route endpoints, honors access policy, and filters shared halo fragments against each available rider endpoint's connected road network. Actual searches still enforce travel direction and turn restrictions; a component match alone is not a route proof. Intermediate regions without a rider endpoint remain subject to actual hop searches. This applies to routing and fuel planning through their shared seam resolver, without edits to surface preferences or Swift.

Local checks pass both directions for Campbellton, Edmundston–Dégelis, and Fermont–Labrador City. Campbellton returns 3.7 km. Both Sorel ferry terminal directions pass. Six Quebec highway/overpass/ramp checks match actual OSM travel direction and continuity. 57 targeted JavaScript checks pass, including a disconnected shared-fragment fixture, access gating, direction, and fuel limits. Live checks of the new source remain pending.

Known separate failure retained: the street pin at (-73.1125, 46.0463) selects a destination-only driveway loop on departure and fails to leave through the adjoining destination-only driveway; its reverse and both ferry-terminal tests pass. The pack preserves the actual source driveway and ferry. Do not claim this pin failure repaired or erase it from acceptance records. Route quality remains unaccepted. No nationwide rebuild until Quebec gate is accepted.
