# Routing recovery and evolution review — September 7, 2026

Status: local recovery under qualification. No physical-device acceptance,
GitHub push, stable DEV publication, or production change is claimed.

## Recovery identity

- Failed source: `106f5a531c72f9ac72b9add995c32534172d8319`.
- Recoverable Git branch: `backup/routing-before-recovery-20260907-230537`.
- Working-file and undeployed-patch snapshot:
  `/Users/richardsmith/SandBox01/MAYDAYiOS/routing-recovery-20260907-230537`.
- Narrow revert commits: `73312b4`, `07211ba`.
- Baseline compatibility/documentation: `6b6fd69`.
- Keep `a245972`: direct-buffer remote loading is independent of routing law.
- Every unrelated dirty/untracked file was copied and SHA-256 checked unchanged.
- Optional `SavedRoute.routeSeedsData` remains as a dormant compatibility column
  so DEV installation does not remove a persisted model property.

The V4 reader, DEV configuration, topology reader, and sealed 63-region release
predate the reverted commits. No pack or catalog was changed. Navigation source
and Android repository were not edited. Stable DEV still reports the failed
source and must be coordinated with the recovered phone build after approval.

## Evolution intent retained

`ROUTING-EVOLUTION-SPEC-2026-09-07.md` remains the implementation brief, with
recovery clarifications overriding its historical qualification claims and
restrictive departure wording. Restore and device-qualify the baseline before
freezing it and introducing the next routing slice.

Code-review findings from the removed implementation:

1. `router.js` enabled `rejectPriorEdges` whenever history was nonempty. Swift
   enabled the same hard exclusion. History flowed across fuel and regional
   boundaries; exceptions only covered narrow start/end edges. This can block
   a lawful departure. Snap failures have additional causes and are not all
   attributed to this condition without reproduction.
2. The exact device Yarmouth request spent roughly 20 seconds on its foundation,
   left too little time for fuel proofs, then searched again for advisory display.
   Fuel orchestration must share one operation budget and reuse completed work.
3. The removed `fuelArcAccessAllowed` used `runtime.enums.ACCESS_NAME` to decode
   V4 `edgeAccess` bytes. These are different tables: directional 1 means unknown,
   but aggregate 1 means permissive; directional 2 means denied, but aggregate 2
   means unknown. It could accept unknown access with Allow Unknown off, or denied
   access with Allow Unknown on, and reject customer forecourts. Any reintroduced
   fuel proof must use V4 directional codes and retain complete turn state.
4. The forecourt helper started restriction history empty at a foundation junction.
   Via-way restrictions arriving from earlier foundation edges require preserved
   state and validation through the rejoined route, not only the immediate turn.
5. `106f5a5` changed JavaScript completed-candidate acceptance and fuel alternatives
   without a corresponding Swift search change. Its shared-law claim is unproven.
6. Minimum-stop claims applied to a bounded, prefiltered station set. A small
   shortlist is appropriate for presentation, but cannot by itself prove that no
   fewer-stop legal plan exists across the available packed stations.
7. Saved route seeds were added to storage and writes; restored-seed replay and
   nonzero-seed real-graph equality need explicit qualification, not inference.
8. Most waypoint movement code predates these commits. The logged session changes
   from From Here to Plan; no move action is recorded. The removed map change was
   the already-selected fuel-pin callback, not the general waypoint drag path.

The earlier baseline itself has limitations: one-stop foundation slicing can
create synthetic `fuel-access:` segments, and exact Yarmouth fuel planning may
select lower-Dirt station legs. Recovery is not a declaration of launch quality.

## Local evidence

- 65 focused JavaScript checks passed after the narrow recovery.
- The DEV iOS target compiled. Initial itinerary run: 72/73 passed; the failed
  assertion expected a redundant first-section override after returning to the
  rider-leg default. It was corrected to check the inherited default, preserved
  downstream override, and displayed profiles. Rerun pending below.
- Exact Yarmouth: 44.76484,-63.34023 → 43.47454,-65.60197, Dirt, unknown off,
  234,000 m usable: complete with two stops in 28.397 s. Returned legs were
  219,626 m / 47% Dirt, 225,478 m / 56%, 36,164 m / 48%; no connector segments.
  This is a recovery result, below the evolution's 55% whole-route regression
  floor, and does not preserve the removed implementation's 67% foundation.
- Short route to the known Porters Lake services location: 7,303 m in 0.701 s,
  complete, sealed V4 identity.
- NB→QC using V4 topology selection: complete, 725,639 m in 14.092 s.
- Regional fixtures must set `DIRT_V4_REGIONS` as well as graph-path overrides.
  The first NB→QC probe loaded V4 graphs but used the older topology selector;
  that probe is excluded from V4 seam qualification.

## Device and release gate

White iPhone only: same-province short route; exact Yarmouth at 234 km usable;
NS→NB including departure from a fuel stop; NB→QC; QC→ON; Plan waypoint select,
move and insert; From Here long-press destination relocation; saved-route opening.
These are recovery checks, not acceptance of unfinished evolution features.
Local checks first, then explicitly authorized stable DIRT DEV publication,
matching DEV device build, Richard's physical results, and only then an explicitly
authorized GitHub backup. Actual production remains untouched.

## Next independently qualified slices

1. Route-connected fuel proof: correct directional access/turn history, no
   synthetic geometry, minimum necessary stops over the searched packed set,
   one foundation search and honest incomplete failure.
2. Regional/rider-leg departure scope, with exact pump and seam fixtures. A
   minimum necessary legal exit must not become general retrace permission.
3. Stable per-leg seed lifecycle and edit scope, with saved replay and identical
   nonzero-seed fixtures in JS and Swift. Freeze navigation behavior.
4. Remaining-road progress and two or three legal candidate routes from one
   bounded search; same selection and completion rules in both engines.
5. Fuel replacement and waypoint interaction on the phone, followed by the full
   exact-device regression matrix. Ride Setup remains deferred until routing freezes.

## Completed recovery checks and concrete QC/ON blocker

The restored phone lookup-cache lifetime fix is a separate four-line behavioral
repair, not restoration of the routing overhaul. `cachedPack === pack` prevents
an object-address reuse from selecting an unloaded pack's spatial lookup. The
prior suite exposed this as Yarmouth `.cannotSnapStart`. After the fix, all 82
focused iOS checks passed, including all 73 itinerary checks and V4 pack/snap
checks. JS uses weak object-keyed caches already; this does not retune routing.

Additional local V4 recovery results:
- NS→NB pump route: complete in 6.276 s; departure from that pump with the carried
  last 256 road IDs: complete in 4.333 s. These unconstrained connectivity probes
  are not fuel-range qualification (443,265 m and 405,646 m respectively).
- QC→ON failed in 0.759 s before any path search. Both endpoints had eligible
  nearby road candidates; they belonged to separate components. The generic
  error incorrectly described this as no eligible road at the start.
- The runtime topology file exactly matches the sealed topology SHA-256:
  `2d775556a7560a40f87bc74f5a66030626cc5a9b302cfef0f3bbd5043f0c51fa`.
- All 128 advertised QC↔ON seams occupy the southern Akwesasne area. None
  connects to the starting point's 838,139-node strict-access QC component.
  Their QC components contain only 4, 19, and 383 nodes.
- Read-only inspection of the unchanged QC/ON graphs found 1,044 common OSM
  nodes joining their main strict-access components. At 981 of those nodes,
  coordinates, full edge/access/layer/structure proofs, barrier decisions, and
  relevant turn-restriction proofs agree between packs.
- Root cause: `scripts/pack-fabric/scripts/build-v4-seams.js:selectProofs` sorts
  distinct-way proofs by latitude then longitude and retains only the first
  128. It proves each advertised connection but does not prove geographic or
  main-network coverage. The sealed zero-unproven count remains true and does
  not establish end-to-end route completeness.
- A DRAFT-ONLY topology document outside the repository preserves the existing
  128 records and adds 1,642 matching proof records at those main-network nodes.
  A local process substituted this draft in memory only. The exact same QC→ON
  request then completed in 16.551 s over the original sealed graph/geometry
  hashes. This is an unconstrained route connectivity demonstration, not fuel
  or full evolution qualification. No sealed file, catalog, or service changed.

Richard has explicitly authorized publishing the matching service to stable
DIRT DEV once verified; do not ask for that authorization again. Actual
production remains untouched. The prior frozen-V4 boundary still prohibits
changing connection sidecars/catalog metadata. A separately versioned DEV
connection-metadata correction needs an explicit exception before publication
or activation. Preserve the original sealed release and reuse unchanged road,
geometry, fuel, and Rider Services bytes. Do not silently ship the draft as if
it were already part of the sealed release.

The complete evolution remains unfinished, particularly one-operation fuel
planning and the exact 234 km Dirt-quality regression. Do not invite physical
qualification as if these open items have passed.

## September 8 authorized continuation

Richard authorized all necessary revisions and explicitly reopened the frozen
connection boundary. The original sealed release remains unchanged. Created
connection-only revision `connections-v4-20260908-02`: 7,099 QC/ON legal proofs,
source topology SHA unchanged, revised catalog SHA
`3f4c804854775490f15832784cf0942e640ca2078381b35592c5cf3e2239c184`.
The builder no longer drops proofs after 128 southern ways. A reproducible
one-graph-at-a-time revision tool verifies source graph hashes and matching node,
edge, directional access, layer, structure, barrier, and restriction evidence.

Retaining all proofs exposed a second failure: nearest-only shortlists exhausted
attempts on disconnected fragments. Both runtimes now give distinct component
pairs an attempt, prioritizing the larger network before repeats. This is an
attempt-order policy, not a proof of directed connectivity or permission.
The full revised QC/ON fixture completed in 16.974 seconds, 927,639 metres, on
original graph identities. Seven new focused JS checks passed; ten focused
V4 pack/snap iOS checks passed. The requested environment-method filter did not
appear in the executed test count, so environment tests still need a full suite
run. No claim of complete JS/Swift regional-path parity is made: their older
geographic ranking and backtracking differ and remain to be reconciled.

The new catalog preserves every graph/geometry/fuel identity. App DEV file URLs
select the revision for seams only; Rider Services remains on the original
release. Seam top-up now verifies the current catalog checksum before reusing
an existing file and after a download attempt. Publication of the 66 metadata
objects is in progress with read-back hashes; catalog goes last. No stable DEV
service deployment or physical acceptance has happened at this checkpoint.
Fuel, seed lifecycle, and remaining-road evolution work remain open.

The connection publication completed: all 66 remote metadata objects were
read back and SHA-256 verified, with catalog published last. No production
catalog or original candidate object was overwritten. The foundation-advisory
reuse slice passes all 47 JS fuel checks and 81 iOS itinerary/general checks,
including the DEV environment URL checks and a regression requiring zero second
route requests after a failed fuel proof. Saved foundation reuse is scoped to
its original departure and does not mark fuel complete. Full fuel-quality
recovery, 30-second atomic behavior, and physical qualification remain open.

## Broader coverage and directional-access audit

All 63 original graphs were hash-verified and their advertised seams checked
against strict-access weak components, one graph per process. Four pairs lacked
advertised access to one region's largest component: QC/ON, DE/NJ, NT/YT, OR/WA.
Revision 03 retains all re-proven shared connections for those pairs (7,099,
1,302, 298, 4,546 respectively). All 66 metadata objects for 03 were published
and read-back verified. Original roads and catalogs remain unchanged. NT/YT
has no shared main/main connection in these graphs; its proven crossings serve
a separate network and must not be represented as universal connectivity.

OR/WA Clean between packed pump locations completed: 32,871 m in 4.617 seconds.
DE/NJ reaches NJ but Clean hits a pop cap and Balanced a time cap approaching
station `osm:w1158884119` (39.731886,-75.460113). Inspection shows a real 13–25 m
customer-access approach spanning multiple edges. Existing endpoint permission
covers only the snap edge, not the connected forecourt. This is an unresolved
routing defect, not evidence to widen public-road permissions.

A separate JS/Swift discrepancy was found and corrected in JS: V4 real-edge
search still applied aggregate access after the directional transition, while
Swift correctly skips the aggregate table. The JS transition also now enforces
the directional unknown gate explicitly. Reverse-distance lower bounds match
Swift's directional interpretation. 68 focused JS tests passed. Exact Yarmouth
at 234 km usable now completes in 23.768 seconds with two stops, 563,713 metres,
52.3956% known Dirt. The 55% acceptance floor remains unmet; foundation partition,
forecourt proof and full routing evolution remain incomplete.

A protected DEV deployment of earlier checkpoint `53eb0d6` was built without
moving the stable alias: `dpl_Fj9nFE9FVUNFBsb8Q9X5MCAV2ffj`, URL
`https://pack-fabric-5yjp3j18p-goricksmith-7678s-projects.vercel.app`.
Its health identity and short NS route passed (7,303 m, exact sealed hashes).
It carries revision 02; do not promote it as the matching revision-03 service.
Stable DEV remains unchanged until a later matching deployment is verified.
