# Quebec canary — September 8, 2026

Status: corrected Quebec/Atlantic candidate is live on stable DEV (`https://pack-fabric.vercel.app`), source `8ae00633d26d60ab8b35234eb3bc01eb40be2932`. Quebec pack, highway, ferry, fuel and border checks pass automatically. Physical Quebec acceptance remains pending. A separate Sorel driveway-pin failure remains open. No national rebuild or phone installation.

## What changed and why

Quebec had the same toll-booth conversion defect as the Atlantic packs. Quebec alone was rebuilt from the same locked September 6 OSM source, using the corrected factory. The five-region candidate `fabric-v4-20260908-02` reuses the exact accepted Atlantic road, geometry, fuel and rider-service bytes. It regenerates only their connection records to include Quebec. The old sealed releases remain untouched. All 40 candidate objects were uploaded to R2 and read back with matching checksums.

Quebec retains 1,203,111 road points and 1,469,141 road sections. Comparison against the old Quebec pack confirms identical source road/node identities, geometry, road lengths, surface labels, road classes, access labels, grade, bridge/layer records, seasonal flags, ferry durations and turn restrictions. The correction changes passage at 95 toll nodes; every changed node was checked against its source toll record. Genuine restrictions are not opened by Allow Unknown. Fuel has 3,518 stations; camping, lodging and liquor source data are present.

The first live border run failed four of six requests. Another returned 558 km for a short Campbellton bridge trip, which is recorded as a failure despite a “complete” API status. The shared service chose crossings around old preset locations, could choose unknown-access roads when unknown access was off, and treated a shared road fragment as a usable connection without proving that the rider could enter/leave it.

The shared live chooser now uses adjacent route endpoints, honors access policy, and checks directed outgoing/incoming reachability in the actual packs. Actual route searches still enforce final turn restrictions and path legality. Its retry retains the qualified crossing alternatives. This fixes a class of border failures, not a named-pair exception. No surface/profile preference code changed.

The first correction preview passed Quebec but regressed NB→NS. It was not published to stable. Directed reachability and retaining filtered alternatives corrected that regression. All six Quebec and eight Atlantic border checks pass locally. The final live replay must match that before stable publication.

The existing bounded three-pack cache is explicitly enabled for this DEV deployment so the service does not download Quebec again between connection checking and the actual regional hop. Production defaults remain unchanged.

## Remaining boundaries

- Physical Quebec acceptance is pending. Automated passes do not replace Richard’s tests.
- A Sorel street pin at longitude -73.1125, latitude 46.0463 still selects a destination-only driveway loop and cannot leave via the adjoining destination-only driveway. This is retained as an open JavaScript endpoint-access issue. The reverse street route and both ferry-terminal directions pass; no ferry-pack pass erases the street-pin failure.
- Route quality and speed are not accepted as complete.
- Multi-region intermediate hops still require actual route searches; directed reachability is a preliminary filter, not a complete turn-aware route proof.
- Swift/offline parity remains deferred by Richard’s live-only instruction. No phone files changed.
- No wider rebuild has started.

## Evidence and source

Evidence directory: `scripts/pack-fabric/routing/candidates/quebec-canary-20260908/`. Initial, intermediate and final requests/results are retained separately. `rebuild-content-audit.json`, `atlantic-reuse.json`, `upload.log`, `source-commit-final.txt`, `final-unit-tests.log`, `final.log` and `final-results.json` identify the data and checks. The source worktree is `.build/atlantic-live-fuel`, branch `recovery/atlantic-live-fuel`; unrelated routing experiments in the main tree are not deployed.

## Final live verification and handoff

The final matched deployment passed all six Quebec border requests (both directions at Campbellton, Edmundston–Dégelis, Fermont–Labrador City), all eight accepted Atlantic crossing requests, six Quebec highway/overpass/ramp requests, both Sorel ferry-terminal directions, and a 189 km Quebec interior route. Source-way checks validated directed travel and consecutive road connectivity on the Quebec routes; they are not a claim of complete route quality acceptance.

The fuel service created the EKO stop in Lévis. Its actual approach route is 20,811 m, within the 30,000 m first-leg allowance. Fuel-on border planning also passes NB→QC and QC→Labrador. The live fuel layer returns the same 3,518 Quebec stations; camping, lodging and liquor are present through the live layer reader. All final requests match source 8ae00633d26d60ab8b35234eb3bc01eb40be2932 and corrected release fabric-v4-20260908-02 where service/pack identity applies. The known Sorel street-pin failure was deliberately replayed and remains failed; it is not counted as a pass.

The exact verified preview was assigned to stable DEV, then checked directly without preview tooling. All six Quebec border requests, NB→NS regression, Quebec fuel creation, a fuel approach and NB→QC fuel planning passed against stable. Direct road-request timings ranged from about 1.3 to 13.7 seconds in this run; fuel creation and cross-border fuel each took about 7.4 seconds. Performance is improved by reuse but is not qualified as instant or finished.

Richard can now use the existing online DIRT DEV app to test Quebec within the province and across NB/Labrador, with fuel off/on, and inspect layers. No new app install or pack download is required. Ask for the debug export and comments. The wider rebuild has not started; preserve the physical Quebec gate and the open endpoint-access issue.
