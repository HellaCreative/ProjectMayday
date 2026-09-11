# Hybrid outcome and first shared DIRT selection

The hybrid is the selected development foundation. On the strict NS→WV admission
case, the best configured bespoke solver found a road but exhausted 500,000 fuel
labels without an itinerary certificate. The hybrid now produces a continuously
audited fuel itinerary in about 36 seconds. This establishes a useful capability
improvement on that case; it is not an all-profile, all-region or hosting win.
The bespoke failure took 28 seconds, not 90 seconds. The earlier 90-second
failure was the previous GraphHopper fuel integration. Neither failure proves
that other changes to that solver could not work.

Following checkpoint `c9e077b698b71ac8b8a0b2e6eca2391d252113c8`, implemented a
private DIRT selection layer over the persistent GraphHopper service. It reuses
the existing JavaScript `compareSurface` and `proveFuel` functions. No product
router, deployed API, app or pack was changed. No Android behavior is shipped.

## Implemented behavior

`hybrid-rides.js` generates a fixed shared pool using dirt30, dirt10, paved and
distance objectives, with one total request deadline. All three riding styles
select from that same pool. Dirt maximizes known-dirt percentage; Balanced uses
the existing distance from known 50/50 and its dirt-side tie preference; Clean
maximizes known pavement, using backroad cost as a tie-breaker. Unknown surface
counts toward neither side of Balanced. No new search weights or threshold for
acceptable dirt percentage were introduced.

Every selected fuel itinerary retains its exact roads, refills and destination
escape. DIRT independently recomputes fuel arithmetic before admitting the
candidate. An unverified dirt-rich road cannot displace a fuel-feasible ride.
If no candidate is fuel-feasible, a road can remain with `fuel_unresolved`.
Station evidence remains a legal road projection, so the new boundary accurately
returns `fuel_provisional`, not physical fuel-access verification.

Changing the riding style can reuse the same completed pool. One serialized pool
is cached, limited to 16 MiB; this is an output-cache bound, not graph memory or
total RSS. Oversized pools are still returned and simply not cached. The cache
key includes graph/build identity and all supplied constraints, including fuel,
exclusions, endpoints, access and deadline. It excludes only riding style.
Partial/cancelled work is never stored as a completed pool. Callers cannot mutate
the stored pool by editing a returned result.

Only one uncached selection runs per service instance; extra direct module calls
are explicitly rejected. Candidate requests use the existing bounded Java
service and cancellation. Request deadlines include candidate generation and
selection, with preparation-boundary checks and a bounded transport grace period;
this is not hard real-time scheduling. Unsupported waypoints and arrival history
are rejected explicitly. Initial fuel must be supplied when fuel is requested.

The strict cost/mask benchmark has identical search weights for every additive
profile, so its shared pool runs one dirt30 objective instead of four duplicate
searches. All three selections consequently coincide. This is explicitly labeled
`fixed_500x_cost_and_mask_shared_by_all_styles`; it is not Clean/Balanced product
qualification and cannot demonstrate profile diversity.

## Integrated matrix results

One bounded run per case, using existing verified fixtures and immutable graph
artifacts. These are local observations, not repeated hosted timing comparisons.
Times cover generation of the entire shared pool; subsequent style selections
are in-process cache hits and exclude network/UI latency.

| Case | Fuel assumption | Pool generation | Dirt selected | Balanced selected | Clean paved share |
| --- | --- | --- | --- | --- | --- |
| NS shorter fixture | Off | 0.699 s | 78.11% dirt | 38.85% dirt | 99.99% |
| NS long | 120 miles, full initial | 1.575 s | 56.95% dirt | 53.18% dirt | 99.93% |
| NS→NB | 180 km usable, 90 km initial | 1.818 s | 57.51% dirt | 55.18% dirt | 99.85% |
| NS→NB | 120 miles, full initial | 1.575 s | 55.26% dirt | 54.65% dirt | 100% |
| Quebec long | 120 miles, full initial | 17.788 s | 9.53% dirt | 9.53% dirt | 99.06% |
| Strict NS→WV | 120 miles, full initial | 36.644 s | 49.72% dirt | Same fixed-cost candidate | Same fixed-cost candidate |

Surface shares describe the selected road through the destination, excluding
the escape path used for fuel feasibility. Unknown surface explains why dirt
and paved shares may not sum to 100%. The fixture named `ns-short-balanced-road`
is not a neighborhood ride: its selected Dirt road is 280.45 km. Fixture names
are preserved for reproducibility rather than used to imply shorter distances.

The Quebec selector now chooses dirt10's 49.769 km known dirt over 522.288 km
(9.53%) instead of dirt30's 18.067 km over 517.172 km (3.49%). This fixes the
selection reversal but does not create a good Dirt adventure: both Dirt and
Balanced remain far from their targets. Richer feasible corridor generation
and riding-coherence acceptance remain open.

All six pools completed. Eighteen cached style edits reused byte-identical
candidates in 0.97–6.83 ms locally, with no additional engine search. Sampled
process-group peaks (Java plus Node/harness) were 646.4 MiB for the NS matrix,
1,497.5 MiB for Quebec and 2,398.8 MiB for strict WV. No concurrency or hosted
capacity conclusion follows from this sequential selection benchmark.

## Verification and limits

Twenty-one generated candidates passed independent V4 source-walk audits:
four fuel-off roads and seventeen fuel itineraries, including continuous escape
history. The audit now also checks the surface classification and backroad-cost
metadata used for selection against immutable source data and the existing DIRT
cost function. Previously omitted fuel surface metadata is now preserved for
this audit; older records without it remain supported.

The strict WV itinerary and escape exactly match the preceding strong-LM result
after removing the newly added scoring metadata. Zero blocked source edges occur.
The Java change only emits surface and backroad-score metadata; it does not alter
the search, fuel repairs or graph. The public pack bytes and prepared graph are
unchanged.

Nine focused tests pass: shared-pool order independence, 48% versus 65% Balanced
selection, unknown-surface treatment, false-fuel rejection, provisional station
evidence, feasible-versus-unresolved selection, cache identity/isolation/bounds,
partial-work handling, cancellation and unsupported inputs. A real-service check
cancels in about 29 ms, rejects overlapping generation, recovers successfully,
reports a 1 ms deadline as incomplete and retains the prior completed cache.

This is first shared-style selection, not full product qualification. Urban
necessity, physical fuel entrances, richer corridor discovery, riding coherence,
waypoints/continuation, Ontario, every-region coverage, offline/navigation and
commercial load remain open. `navigationReady` and `productProfileParity` stay
false. Fuel arithmetic and shared selection are reused from DIRT; this is not
an independent rewrite of those product laws.

## Reproduction and candidate identity

Private branch `experiment/engine-architecture-20260911` in
`/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/.build/engine-architecture`.
Preceding checkpoint is recorded above; the commit containing this report is
the next reviewable candidate. Exact Git identity is also retained in the external
recovery log. No deployment, remote push, native installation or owner decision
is required for this private milestone.

External root:
`/Users/richardsmith/.codex/experiments/routing-architecture-20260911`.
Compiled adapter identity:
`88fcfdbec8d452d7f5213772650cd84952efcf055099d22e4627d3417e11ce23`.
`hybrid-shared-selection-evidence.json` pins raw responses, inputs, audit results,
checks, guards and an immutable copy of the build receipt. Earlier compiled
receipts are retained in `tools/gh-adapter-previous-*` and copied by content hash
under `results/compiled-build-identities`; the active compiled directory changes
when a new candidate is built.

Run `node --test scripts/routing-architecture/hybrid-rides.test.js` and
`hybrid-rides-boundary-check.js <unused-output>` for boundary checks. Run
`hybrid-rides-bench.js --dataset nsnb|wv|strict-wv --out <unused-output>` through
`guarded-run.py` with a 4,096 MiB RSS limit. `wv` selects the Quebec fixture on the
six-region graph; `strict-wv` selects the masked WV stress route. Guard files
record the exact executed commands. Audit the emitted fuel/road inputs with
`audit-verified-fuel.js` and `audit-verified-routes.js` against their prepared
joins and stations. Source identity checks refuse stale compiled code.
