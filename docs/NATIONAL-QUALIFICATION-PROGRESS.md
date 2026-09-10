# National qualification candidate

Not deployed. Service national-v1 flag added;214adventure fixture tests pass,
including3region restriction preservation and duplicate-region rejection.
Exact63-region graph/geometry/fuel admission imported from audited release09.

Real local pack smoke (single process per case, original immutable bytes):
- PEI Balanced fuel:75.072km complete,431ms,126032KiB peakRSS.
- VT/NH Balanced fuel:7.243km complete,5017ms,1089296KiB peakRSS.

These are local smoke tests, not hosted or comprehensive nationwide acceptance.
VT/NH uses over1GB RSS despite a short route: big-region/multi-region memory is
an explicit remaining qualification concern. Runner saves complete result and
uses actual decoded packs. Fixtures in bench/fixtures/national-*.json.

Remaining:3+realregion, long/crosscountry/state/province routes, fuel replacements,
customsettings, runtime deadlines/cache behavior, hosted exactrelease deployment,
Swift offline parity and release archive/signing. Do not activate national based
only on these two successful smokes. Accepted Loop/navigation/fuel behavior frozen.

## Memory refinement

Joined edge IDs and source aliases are now materialized on demand instead of
allocating strings and one array for every edge. Overlap aliases retain all
source identities.214existing adventure tests pass; dedicated lazy-ID coverage
added and passed. Same VT/NH route:600496KiB peakRSS versus1089296KiB before
(~45% less),3879ms versus5017ms. Geometry and distance identical. This is one
controlled sample, not a national memory ceiling. Larger regions remain open.

Hosted preview b5804e6 against promoted release09: PEI complete2769ms cold,
1267ms warm (data648→3ms); VT/NH complete15878ms; NS complete4548ms.
WA stopped during preparation with expansion_limit before anysearch expansions.
Preparation allowance now scales to max20M,64*edgeCount; existingdeadline retained.
This does not grant more search time or change route scoring. Retest pending.

WA follow-up: warm hosted request exposed repeated from/via OSM relation16478624.
Adapter now normalizes only a repeated single-edge only-turn with explicit YES/NO
one-way access, a unique to-edge exit, and a viaNode matching entry. It becomes
an enforced node-only turn at that exit; source metadata/pack bytes unchanged.
All other ambiguous cases still fail.218 adventure tests pass including negative
selfloop, entry-only, same-edge, multi-via, unknown/bidirectional direction cases.

Urban preparation now applies only spatially intersecting core boxes to each
candidate edge. Full/indexed and partial/reversed crossing measurements agree.
WA local request progresses into route/fuel search (preparation4204ms) but still
fails20s deadline after fuel label_limit. This remains an open national blocker.

Preview3 source0ce8c2e:
https://pack-fabric-od1cxhn5j-goricksmith-7678s-projects.vercel.app
WA cold: data5608ms, preparation6351ms, deadline during station matching.
WA warm: data3ms, preparation0ms, station matching10820ms, search still hits20s.
The immutable preparation cache works, but cold/warm fuel-chain qualification
is not complete. Finer grid experiment reduced matching locally but raised
preparation time and did not complete; reverted rather than change accepted
index geometry without a demonstrated overall win. No production alias moved.

Exact source bounding rectangles retained in the station index now reject
coarse-cell neighbours outside the conservative query rectangle before expensive
polyline projection. Crossings retained; source geometry/projection/access rules
unchanged. WA matching5255→1018ms in local20s samples, preparation4204→3721ms.
It reaches more candidate search work but still fails fuel label limits/deadline.
Bounds add32bytes/edge (~69MB WA); measured overall process1.16GiB peak including
further search progress, not a production memory guarantee.219tests pass.
Station index now reads exposed typed coordinates directly when available,
retaining polyline fallback for joined graphs. This avoids per-point temporary
arrays; direct/fallback query equivalence test passes. Request timings remain
variable under concurrent work and no national performance claim follows.

Distinct parallel from/via edges can now use explicit writer-resolved viaNode
only after checking complete via/to adjacency. Repeated-edge broad normalization
was rejected after SK/OH source counterexamples; only the earlier independently
proved WA case remains until corrected versioned packs arrive. Added directed
parallel-entry and wrong-entry/disconnected rejection coverage.

Private zero-refill candidate (OFF by default; env DIRT_ZERO_REFILL_ADVISORY=candidate-v1):
An alreadycomputed advisory with no repeated edges, sufficient initial fuel, and
proved direction-aware destination escape can avoid full resource label search.
Required/forced pump, minimumStops>0, prior itinerary histories excluded inadapter.
WA local complete13.6s with all3objectives proved; prior repeated20s failures.
NS/VTNH/PE Balanced selectedgeometry, distance, fuelstops identical incomparison.
Pavedcandidate differs NS81210.948→80771.554m; VTNH8750.150→8749.150m, bothsame
urban0/retrace0. Thus not identical weighted-search behavior for everyprofile.
Do not enable on frozenAtlantic or claim qualified from Balancedcomparison alone.
Hard exclusion added: the private zero-refill flag cannot affect any request
containing NS, NB, PE or NL. Accepted Atlantic routing stays on its existing path.
Corrected19graph overlay plus unchangedother44 admit63/63 with a37856b reader;
report /tmp/dirt-63-reader-corrected.json. Publishedrelease02verification pending.

Live reverse-cost storage ceiling raised from64MiB to256MiB, allocated in
chunks for actual eligiblearcs only. Generic caller default stays64MiB. This
removes a deterministic large-state admission ceiling without preallocating
256MiB or changing graph/scoring.223adventure tests pass; large-state hosted
memory still requires measurement. No capacity/subscriber-scale claim.
National time allowance authorized with newapp archive: cap60s for anynon-Atlantic
region,20s for all-Atlantic. Caller smallerwindow retained. Allload/preparation
shares deadline; hostingfuel-chain75s. Privatezero-refill flag remains disabled
for production deployment, preserving accepted candidate selection.

Hosted d04b390 preview6, zero-refill OFF, actual rider preferences wander.5 /
avoidCitiesfalse / avoidHighwaysfalse, WASeattle→Bellevue:
- cold COMPLETE20753ms (data5391),37.9426899km, all3candidate proofs.
- warm COMPLETE7422ms (data119), identical37.9426899km.
Both retained accepted weightedcandidate selection; no fastpath used.
https://pack-fabric-nzuuqxstt-goricksmith-7678s-projects.vercel.app
Evidence /tmp/dirt-wa-preview6.json and /tmp/dirt-wa-preview6-warm.json.

2026-09-10: Explicit wander now adds a continuous extra-distance charge to each
existing surface objective: 30 * (1 - wander)^2 per metre. It no longer filters
the completed pool down to the shortest (usually paved) route at zero. Selected
surface ranking and existing candidate count stay intact; wander 1 retains the
original objective. Sixty combinations of two reported NS destinations, three
profiles, five wander values and both unknown settings completed (max 1.37s
locally). Dirt at zero remains dirt-seeking; route changes have natural plateaus.
Release fabric-v4-20260909-02 exact graph/geometry/fuel identities admitted for
all 63 regions; corrected 19 graphs and unchanged 44 passed reader checks.
Production experimental zero-refill advisory must remain OFF.

Superseding the prior OFF instruction after default-WA qualification: the
proved-national-v1 zero-refill option is authorized for non-Atlantic requests
only. Unweighted legal search proves minimum urban exposure then objective cost;
a no-repeat path has zero retrace and zero refills. Initial fuel must cover the
path plus arrival-direction legal escape. Required/forced pumps, minimum stops
and prior rider history exclude this option. Atlantic exclusion remains hard.
This preserves the objective, not the previous heuristic-weighted candidate.
WA default (wander 1, avoidCities true) completes locally in 14.7s with all three
proofs; the previous fuel frontier hit 400k labels on each candidate. 225 tests
pass including exact-search comparison with urban priority and passing pumps.

Hosted e4f234c WA default, release02: COMPLETE44960ms cold. California on2GiB
failed with platform-confirmed OOM;4GiB performance tier (existing Pro plan)
restored bounded responses. Cold60s completed first objective but not fullpool;
warm hit fixed30m expansion cap. National-only work cap now scales with graph
edge count (64 per edge, minimum30m), deadline90s; Atlantic20s/30m unchanged.
Fuel-chain host105s. Both service projects future deployments configured4GiB.
Stable DEV slider repair deployed e4f234c with ns-nb-v1 scope while national
qualification continues; zero-wander Dirt NS completes3371ms, release02.

Hosted5cc36e2 California default cold COMPLETE76582ms,15019ms load; allthree
objective candidates complete with directional fuel escape proof. Thus90s work
and100s transport are measured allowances, not an unverified latency promise.
Evidence /tmp/dirt-ca-90-hosted.json; private
https://pack-fabric-o05hhg34d-goricksmith-7678s-projects.vercel.app .
225 focused adventure tests pass.63/63 corrected-reader admission evidence
/tmp/dirt-63-reader-corrected.json. This qualifies published pack admission plus
representative live routes, not every possible itinerary or concurrent load.
