# Nova Scotia routing benchmark

Run the fixed-pin matrix with `npm run bench:ns`. Compare a run with a prior
recorded revision using `npm run bench:ns -- --compare <sha>`.

The benchmark reports assertions but never changes or relaxes them. Non-fuel
routing hops have a 4,000 ms budget. Fuel planning and fuel-routed hops have a
6,000 ms per-hop budget because the planner evaluates six (`K=6`) connected
station candidates. A multi-stop fuel plan is measured by its slowest planning
or routing hop, not by treating the entire chain as one hop.
