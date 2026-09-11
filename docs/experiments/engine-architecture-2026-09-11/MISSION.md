Continue **Explore fog of war search** with a broader architectural mission.

Your previous work produced useful preparation improvements. Preserve that work, but it did not resolve the central problem: long national routes still exhaust memory, and production scalability remains unproven.

I want you to investigate whether we should substantially change—or replace—the routing architecture. Do not assume that improving our existing engine is the best investment.

## Mission

Find and demonstrate a practical routing architecture for DIRT that substantially improves long-distance, cross-region routing speed and memory efficiency while supporting concurrent users.

Prioritize established open-source implementations, especially **Valhalla, GraphHopper, and OSRM**. Use BRouter and OsmAnd as additional implementation references where relevant. OpenStreetMap supplies map data; it is not itself a routing engine.

Study actual source code and working implementations. Documentation and recommendations alone are insufficient. An engine’s popularity is not proof that our deployment can support thousands of users; measure capacity.

## Continue autonomously

Work through:

**Research → implement → build → test → review → revise → test again.**

My questions do not pause this mission. Answer briefly and continue.

Do not stop because you have:

- Found another bottleneck.
- Improved a cache or removed duplicated allocation.
- Produced a promising design.
- Passed a small-region test.
- Obtained one successful long route.
- Written a list of next steps you could implement yourself.

Do not end a turn merely to say what you would do next. Perform the next authorized step.

If work spans context limits, maintain durable notes and resume from them. If a long-running process finishes, inspect its results and continue. Report an actual external blocker precisely; do not treat an unfamiliar library, missing local installation, or difficult implementation as a blocker by itself.

## Preserve existing work and boundaries

Preserve candidate 571123c, evidence checkpoint c12bab7, and the accepted recovery checkpoints.

Work in isolated experimental directories, branches and private preview deployments. You may install required open-source development tools, build engines locally, and obtain bounded public test extracts. Check available disk and memory first and avoid interfering with other active work.

Do not change stable DEV, production, published map packs, native builds, Apple submissions or GitHub remotes. Do not provision paid infrastructure without authorization.

You may derive experimental server-side indexes or engine-specific datasets from existing verified data or public source extracts. These are separate experimental artifacts, not replacements for our published packs. Account for their creation time, size and update requirements.

## First: evaluate alternatives before more cleanup

Read the existing research report and your architecture review. Identify which major approaches remain untested.

Then conduct a practical comparison of:

1. **Valhalla:** tiled graph access, dynamic costing, hierarchy, and its serving model.
2. **GraphHopper:** flexible/custom routing, landmark acceleration and prepared hierarchies.
3. **OSRM:** prepared routing, partition/customization, and shared or memory-mapped data.

Build and run representative candidates. Do not rule out an engine because it is not currently installed.

Evaluate whether DIRT should:

- Adopt an established engine and extend its routing preferences.
- Use an established engine beneath DIRT’s fuel and itinerary planning.
- Retain DIRT’s solver but replace graph access and search acceleration.
- Retain the present architecture only if measurements justify doing so.

Compare adaptation effort and ongoing maintenance, not just benchmark speed. Avoid rebuilding proven infrastructure ourselves without a clear reason.

## Preserve the product’s routing requirements

Document the current routing contract before comparing engines:

- Dirt, Balanced and Clean preferences.
- Intermediate rider settings.
- Allow Unknown and motorized-access rules.
- Directed roads and turn restrictions.
- Cross-region continuity.
- Waypoints and route refinement.
- Fuel range, starting fuel, reserves, station reachability and continuation history.

Separate an ordinary road-routing benchmark from full DIRT qualification. A fast paved route does not establish equivalent dirt routing or fuel coverage.

Where an alternative cannot preserve a feature directly, implement a bounded integration prototype or demonstrate the specific incompatibility. Do not silently remove the feature, and do not reject the engine merely because an integration layer is needed.

## Investigate meaningful architectural changes

Prioritize evidence from established implementations:

- Prepared, reusable routing data rather than whole-network preparation per request.
- Regional or tiled graph traversal without copying everything into a joined graph.
- Geographic loading of topology and essential attributes.
- Hierarchical connections and appropriate lower-bound guidance.
- Compact private search state.
- Shared immutable graph data with bounded request execution.
- Fuel-specific acceleration that preserves feasible alternatives.

The failed random geometry/topology paging adapters do not answer whether genuine geographic loading works. If pursuing selective loading, remove the global scanning/joining requirements that defeated the earlier experiment.

Do not spend the night making minor allocation improvements while the architectural alternatives remain untested.

## Use demanding, reproducible comparisons

Use the existing successful and failing fixtures, including:

- Small-region controls.
- Dense Quebec and Ontario.
- NS→NB and NS→Maine.
- NS→Ontario.
- NS→West Virginia.
- A longer multi-region stress route.

Compare identical inputs where possible. When engines require different datasets, disclose source dates, road eligibility and coverage differences; do not present an unmatched comparison as equivalent.

Measure:

- End-to-end cold and warm latency.
- Data loading and preparation.
- Search and fuel-planning time.
- Peak and retained memory.
- Shared data versus additional memory per active request.
- Bytes fetched and reread.
- Preprocessing time, artifact size and update costs.
- Correctness and route-character differences.
- Failure and cancellation behaviour.

Repeat measurements enough to distinguish improvements from noise. A timeout, incomplete alternative search or missing fuel proof is not a successful route.

## Establish concurrency evidence

Test mixed destinations and profiles, not repeated copies of one cached route.

Increase active searches gradually while measuring memory headroom, throughput, queue delay and response latency. Distinguish hundreds of connected or queued clients from hundreds of simultaneous searches.

Compare serving approaches where relevant: the current request lifecycle, reusable workers, and shared or memory-mapped prepared data. Do not assume an always-running service is necessary, but do not reject one without comparing its measured operational tradeoffs.

Show a defensible capacity estimate and its limits. Do not extrapolate a small local batch into a claim of production readiness.

## Completion criteria

The mission is complete only when you have:

1. Practically evaluated the credible established-engine alternatives, with evidence for advancing or rejecting each.
2. Implemented the most promising architecture or integration far enough to exercise DIRT’s relevant routing and fuel contract.
3. Demonstrated repeated success on the previously failing NS→West Virginia case and representative dense/cross-region cases within the stated resource budget.
4. Demonstrated materially improved speed and memory behaviour, with measured concurrent-workload capacity.
5. Produced a reproducible review candidate, clear limitations, migration requirements and recovery instructions.

A cleanup-only candidate does not satisfy these criteria.

If no candidate meets them, continue through materially different credible approaches. Stop only when further meaningful progress genuinely requires an external resource, authorization or product decision. Identify exactly what is needed, why the remaining approaches cannot proceed without it, and what evidence supports that conclusion.

Do not claim every conceivable option is exhausted. Give an honest accounting of the credible options tested and remaining.

## Keep the work visible and durable

Maintain an experiment ledger recording:

- Hypothesis and implementation.
- Why it was selected.
- Exact inputs and versions.
- Measured outcome.
- Correctness limitations.
- Decision and next action.

During active work, give concise updates explaining what you learned and what you are doing next. Preserve commands, fixtures and raw results so the work can be reproduced and resumed.

The desired outcome is a demonstrated architectural path to a scalable consumer product. Keep working toward that outcome without requiring me to sit beside the computer and repeatedly tell you to continue.