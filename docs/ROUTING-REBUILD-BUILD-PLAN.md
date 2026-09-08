# Routing replacement: staged build plan

8 September 2026. Executable sequence with explicit experiment gates; not a claim that the algorithm is already chosen or that implementation has started. Product contract: [specification](ROUTING-REBUILD-SPEC.md). Verification: [scenarios](ROUTING-REBUILD-SCENARIOS.md). Historical decisions: [workbook](ROUTING-REBUILD-WORKBOOK-2026-09-08.md).

## Outcome and scope

Replace the accumulated decision/search orchestration while retaining validated legal-road and pack capabilities. Deliver From Here, Plan and Loop through shared contracts. Live JavaScript first; app/offline parity follows accepted live behaviour. Do not bundle unfinished main-tree experiments, modify factory-owned packs, deploy production or push GitHub during this work.

## Evidence-based starting map

The earlier reviewed live source was `b3cb2fa2a9ef32f1f8f3b47ed860eb30ab792fdc` in `.build/atlantic-live-fuel`; reverify service/source identity before implementation.

| Existing responsibility | Evidence location under scripts/pack-fabric/routing/lib | Disposition |
| --- | --- | --- |
| Legal graph and matching | legal-topology/, pack-v4 tests, snap-v4 tests | Retain validated semantics; review reusable interfaces and any defects. |
| Repeated profile searches | find-path-v2.js: findPathV2, searchBalancedResource | Replace orchestration after experiments. Reuse useful primitives only where contracts match. |
| Endpoint, regional and fallback coordination | router.js: routeRequestCore, routeOnRuntime | Retain required API/graph behaviour; consolidate overlapping decision ownership. |
| Fuel candidate selection and route-first branching | fuel-chain.js: rankForwardFuel and routeFirstPlan branches | Replace duplicated policy/work with one feasibility and candidate-selection contract. |
| Existing legal/fuel/regional regressions | routing/lib/*.test.js; bench/run-fuel-regressions.js | Reuse factual invariants; rewrite assertions that encode rejected product rules. |

Observed risk: nested width/profile/repair/fallback searches multiply work, while fuel can construct rides differently by request type. Existing reuse improvements show value but do not establish the best replacement algorithm. Do not declare all old tests authoritative or all old code expendable.

## Milestone 1 — lock the comparison and expose work

1. Reverify live revision, pack/fuel identities and current deployment ownership. Preserve dirty main tree and previous isolated fixes. Establish a new isolated implementation baseline from the verified revision.
2. Extract exact existing failures/successes into a small replay manifest. Add synthetic R01–R14 cases where real geography cannot prove an invariant cheaply.
3. Add/collect phase timing and repeated-search counters at request ownership boundaries. Use existing diagnostics before adding duplicates.
4. Run the bounded baseline once in consistent cold/warm conditions. Record hardware/runtime, incomplete results and candidate evidence.

Deliverable: reproducible baseline report and fixture manifest. Exit: sources identifiable, failures replayable, major time/work contributors visible. Do not commence broad engine replacement on unmeasured claims.

## Milestone 2 — one request, result and policy contract

Define versioned request fields for mode, rider anchors, owned styles, access, loop intent, fuel assumptions and variation identity. Separate fixed anchors from generated service stops. Define result fields for committed geometry, exact surface statistics, fuel proof state, diagnostics and generation/source identity.

Implement one policy evaluator for eligibility, profile preference, necessary access and settlement handling. Keep fuel feasibility distinct from desirability. Define editing ownership and cancellation at the request boundary. Keep an adapter for the current API while callers migrate.

Deliverable: contracts and small policy fixtures with no deployed behavioural switch. Exit: conflicting current constants are mapped to either an accepted rule, removable workaround or explicit unresolved tuning choice. No universal opaque score or per-case geographic exceptions.

## Milestone 3 — compare candidate search designs

Prototype behind the same contract, not as production branches:

- Bounded multi-candidate graph search using reusable lower bounds, with fuel-continuation checks before committing a ride. Reuse candidate geometry and cheap reachability; avoid full preference reroutes for every pump.
- A resource-constrained search carrying fuel feasibility and surface information, with deliberate dominance/pruning rules and measured state growth. Evaluate whether its richer state becomes prohibitive on province-scale graphs.

These are experimental families, not a predetermined winner. Research primary algorithm references for the actual selected techniques. Check lower-bound admissibility against preference costs and turn state. Compare candidate quality, actual fuel correctness, expansions, memory and total latency on Milestone 1 cases. Compare Dirt and Balanced evidence directly. Evaluate reuse/precomputation before proposing extra infrastructure or factory changes.

Resolve the unbounded Dirt-ranking question with concrete route outcomes: retain strong dirt intent without rewarding cycles or promising exhaustive global optimality. Keep one end-to-end work budget; resource exhaustion reports incomplete search, never infeasibility.

Deliverable: architecture decision with measured tradeoffs and selected algorithm, including exact pruning/termination rules. Exit: selected approach meets legal/fuel invariants and improves the measured work problem without degrading representative riding quality. If neither does, revise the experiment; do not merely increase timeouts.

## Milestone 4 — destination ride replacement

Implement the selected search for From Here and primary legs in Plan. Integrate directional regional handoffs and fuel selection using shared request data. Preserve fixed anchors and necessary access. Route completeness and fuel verification remain independent. Reuse unaffected sections during edits; check downstream range dependencies. Expose reasons for omitted fuel candidates.

Deliverable: isolated live API candidate supporting destination rides and fuel. Exit: R01–R16 and R21 pass with bounded performance evidence; known missed-pump and border failures are either fixed or explicitly unresolved. No claim of a completed replacement if required cases remain open.

## Milestone 5 — Loop and meaningful variety

Add loop candidate generation over the same legal/fuel/policy foundation. Insert first fuel, preserve the original return anchor, interpret exploration direction over the ride rather than as a forced first turn. Evaluate approximate distance/time and connected alternatives. Reuse generation data instead of running several entire independent searches solely for novelty.

Persist chosen geometry and generation identity; edits may produce new alternatives while save/reopen/start remain stable. Shared access does not invalidate variety. Define measured overlap and target-error acceptance using rider-reviewed examples.

Deliverable: live Loop candidate and reproducible alternative rides. Exit: R17–R18 pass; same inputs can request useful alternatives where the network supports them. Duration estimates and unavailable alternatives remain honest.

## Milestone 6 — comparison, DEV rollout and retirement

Run the agreed scenario set on old and new implementations with identical source data. Set explicit release thresholds for responsiveness and quality before declaring acceptance. Verify cancellation, stale-result handling and repeated edit behaviour. Keep a switch/rollback to the known deployment and record source identity.

Coordinate one verified DEV publication with the pack/deployment owner. Provide precise rider tests and record feedback. After acceptance, remove old overlapping orchestration and obsolete tests/constants; do not retain permanent competing fallback engines. Update canonical routing contract and deferred parity records.

Deliverable: verified DEV release, comparison evidence, rollback procedure and retired-path inventory. Exit: automated plus rider acceptance, not merely a passing local benchmark. Production/GitHub remain separately gated.

## Milestone 7 — app navigation, saved rides and parity

After accepted live behaviour, implement app flow for Loop and route persistence/resume; existing reroute integration; confirmed refills, fuel countdown and missed/unavailable pump recovery; end-navigation summary. Resolve initial fuel estimate and partial-refill state before claiming live fuel coverage. Preserve cues/HUD behaviour outside the agreed changes.

Port accepted routing contracts to offline Swift and document/verify Android parity. Run shared deterministic fixtures and offline/low-memory/recovery checks. GPX conversion and named-place search use the established request/anchor interfaces as later additions; provider choice and full scope remain separate work.

Deliverable: rider-facing integration and explicit per-platform acceptance. Exit: R19–R23 and applicable device tests; no live-only evidence represented as offline qualification.

## Immediate next execution

Start Milestone 1. The documents are now concrete enough to compare against code. No further broad questionnaire is needed. Ask only when a scenario exposes an unresolved product choice affecting the selected architecture or its acceptance.
