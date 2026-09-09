# Atlantic engine hardening — September 9, 2026

Scope: harden the accepted NS/NB live engine while national expansion is paused. No route-cost, ranking, fuel replacement UI, navigation, pack bytes, or visual-design changes. PEI/Newfoundland and Labrador remain outside the new-engine admission boundary; “Atlantic hardening” is not a claim of four-province qualification.

## Dependency audit and cleanup

- Live `/api/route` and `/api/fuel-chain` now share explicit dispatch. A new-engine complete, unknown, unsupported-control, or error result never falls through. An exception also does not retry on another engine. Only `null` (outside coverage or a legacy operation) enters compatibility routing.
- Removed eager old-router and old-fuel-engine imports from the HTTP entry points. Loading the handlers no longer loads those two modules; the compatibility request loads them only when needed.
- Retained `router.js` and `fuel-chain.js`: outside NS/NB, non-canary environments (including unchanged production), and supported legacy operations still depend on them. Retained shared graph loading, binary readers, legal topology, fuel data, and geometry utilities because the accepted engine imports them. Whole-engine deletion is not safe yet.
- Retained the Swift on-device router. `routeWhileNavigating` tries it first, including blocked-edge detours, and uses live routing only when necessary and online. Removing it would change frozen navigation and offline recovery.
- Existing NS/NB unsupported controls still return explicit incomplete results. In particular, blocked-edge live recovery is not newly supported by this pass. This is a pre-existing limitation, not a fallback to disguise.

## Hardening changes

- Malformed JSON bodies and invalid body/options/fuel containers return HTTP400 with service identity rather than an internal-server error.
- Requests already aborted do not start routing. Cancellation during awaited work suppresses a stale completed result and prevents a second-engine attempt. Search budgets and existing synchronous search semantics are unchanged; this does not promise instantaneous interruption of CPU-bound work.
- Both accepted NS/NB pack releases now require exact graph, geometry and fuel hashes. The older02 hashes were read from its immutable local pack manifests. Preserve the reviewed NB urban supplement for02 and embedded metadata for09, without double-applying it.

## Client recovery review

The planner cancels previous builds and validates task cancellation plus generation before committing results. The builder resumes at the first unfinished rider leg and preserves reusable upstream legs. Existing tests cover stale results, partial-prefix reuse, failed-leg handling and fuel-state continuity; these Swift tests were inspected, not executed on a simulator during this pass. A newly edited leg must not silently keep stale geometry as if the edit succeeded. The accepted fuel replacement cache/selection code and navigation code are unchanged.

## Verification

224 JavaScript tests pass: request dispatch and HTTP behavior, search cancellation/deadlines, cache invalidation, directed restrictions, fuel proof, replacement, pack admission and memory-grid behavior. Signed generic iPhone DIRT Dev build and development-isolation checks pass. No simulator, device installation, pack publication, national widening, or production deployment.

Hosted comparisons and final DEV source are recorded below after completion. Physical navigation and fuel replacement retain Richard's prior acceptance; this pass does not claim new device or offline qualification.

## Completed DEV publication

Stable DEV source `4e0fc370080acc0e6d1ae392cf758060dc9c2bd2`, preview `https://pack-fabric-rga65ldjm-goricksmith-7678s-projects.vercel.app`. Six hosted fuel-route comparisons (ordinaryNS, short/long frozen fuel replacements, three Inverness itinerary legs including NS/NB) reproduce exact geometry and fuel stops. A direct road-only request reproduces exact geometry and segments. Both endpoints return HTTP400 for a malformed container. Stable alias replay reconfirms the accepted replacement geometry/station identity. All63 candidate09 environment configuration and the BC–WA memory repair remain in place; national engine widening remains paused.

Evidence: `scripts/pack-fabric/routing/candidates/fabric-v4-20260909-01/atlantic-hardening-verification/`. This completes the bounded request/recovery/dependency hardening pass. No new White test is needed for these backend-only changes. Existing limitations remain explicit: PE/NL admission, some live recovery controls and offline/new-engine parity are not implemented by this pass, and the compatibility engine cannot yet be deleted wholesale.
