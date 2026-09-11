# Device-first workload experiment

The owner chose device-first planning with **no automatic server escalation**.
An ambitious personal route can consume a bounded device budget. At the limit,
stop, retain the last valid itinerary and report incomplete calculation. Online
connectivity does not itself authorize a server calculation. Server access remains
a separately controlled option. Splitting a trip must preserve its fuel and legal
arrival history; independent point-to-point routes do not establish that contract.

This is a private prototype, not an app behavior change or iPhone qualification.
GraphHopper–DIRT remains the server foundation. The native component is retained
for bounded local work; this does not restart bespoke continental graph-search
development or competing-engine comparisons.

## Existing capabilities and gaps

Read-only inventory used the current main SIDECAR app source, then the standalone
builder took content-hashed snapshots. The main checkout contains work beyond its
HEAD, so the source hashes in each build receipt are the authoritative identity.
No app files were edited.

- `RoutingSourcePolicy` chooses live whenever online, even when packs are present.
  Pack routing, fuel discovery/chain code, road geometry, V4 access and restriction
  decoding already exist on the phone. Local execution is not a new engine port.
- `GraphPackStore` memory maps input bytes, decodes native arrays, builds a reusable
  spatial index and has cross-pack seam logic. Small files do not prove small
  total working memory. Existing cross-pack code is not newly qualified here.
- `RoutePlannerModel` already cancels task handles and rejects stale generations.
  The detached native search does not consistently observe cancellation. The
  experiment below directly reproduced this and added bounded search checks.
- Pack routing currently rejects custom `ridePreferences`. Its fuel orchestration
  carries a set of prior edges and a single arrival edge. This is not evidence of
  preserving arbitrary ordered via-way restriction history across fuel legs.
  Local failures also need distinct incomplete/budget outcomes. A full fuel and
  continuation parity claim is therefore withheld.
- The private GraphHopper adapter also rejects arbitrary waypoints/arrival-history
  imports and does not yet implement the full product preference contract. A
  handoff cannot fix this by silently dropping fields.
- No actual phone's installed packs, hardware limits, battery, heat, memory
  pressure or UI responsiveness were inspected or measured.

## Download economics and data footprint

The app's routing-pack URL points directly to Cloudflare R2. R2 has no egress
charge for these downloads; storage/read charges still apply. At the owner's
illustrative 450 MB per download, 500 downloads transfer approximately 225 GB
without an R2 data-transfer charge. This is not a total bill estimate and does not
cover unrelated map-display providers. See [R2 pricing](https://developers.cloudflare.com/r2/pricing/), checked September 11, 2026.

Existing local test artifacts, decimal MB, without extra GraphHopper indexes:

| Region | Graph + geometry + fuel | Nodes | Source edges |
| --- | ---: | ---: | ---: |
| NS | 39.11 MB | 187,354 | 220,770 |
| NB | 23.57 MB | 165,871 | 196,252 |
| QC | 180.19 MB | 1,203,111 | 1,469,141 |
| ON | 220.16 MB | 1,554,755 | 1,948,176 |
| YT | 3.73 MB | 17,314 | 21,265 |
| BC | 142.76 MB | 817,946 | 983,179 |

These are test-pack files, not verified current phone installations or the entire
navigation download. Map-display tiles, supporting metadata, future index files
and update downloads add to storage. Native tests use unchanged NS pack bytes
matching the hybrid's graph, geometry and fuel identities. No published packs
were rebuilt. Local routing presently builds indexes in memory; this first
experiment adds no downloadable indexes or pack update burden.

## Execution-policy prototype

`scripts/routing-architecture/device-workload/execution-policy.js` is an isolated
JavaScript policy/state-machine reference, not wired into the Swift app. It
compares region-first, distance-first and capability-based selection. All three
retain mandatory data, feature and resource checks. The suggested 1,000 km
threshold is only a synthetic test value for **straight-line** distance.

No device is qualified by default. Admission requires a matching source/device
qualification identity, supported request features, current legal data, a complete
search domain and tested bounds. Endpoints in one region are not proof of domain
coverage. Bounds in tests are synthetic and must never be copied into production
as measured iPhone limits.

The coordinator snapshots every JSON itinerary field, fingerprints it, enforces
one active computation, cancels superseded work and waits for acknowledged stop.
Late/wrong-identity/unverified results cannot replace the retained valid route.
Local timeout or memory-event outcomes remain incomplete. Default server calls
are zero. If explicitly enabled, fallback starts a fresh search with identical
constraints after local work stops; no search-state transfer is claimed.

Sixteen tests pass, including dense short routes, sparse long routes, short
crossings, missing/stale data, unsupported settings, reduced starting fuel,
unqualified devices, huge NS→BC request shape, cancellation, recovery and stale
results. Executor responses and device qualifications in these policy tests are
controlled doubles. They do not establish real native fuel or server integration.

## Native diagnostic and cancellation change

`build-native.py` snapshots the actual native router, decoders, cost/retrace/turn
helpers and domain models into an isolated optimized macOS executable. It retains
source hashes and fails if source changes during compilation. UI-independent
POIFeature/FuelGap declarations are extracted unchanged; routing is not replaced
by a toy implementation. Native urban metadata must be present. Initial build
attempts exposed missing native dependencies; those were added before any route
measurement. No iOS app or simulator was built or installed.

The optional `--cancellation-prototype` adds a callback to five existing heap
search loops and the road-guidance builder in the generated router only. The
diagnostic wrapper rejects interrupted results as incomplete. Costs, topology,
turn checks and pack contents are unchanged. Pack decoding, allocations and all
preparation stages are **not** yet cooperatively interruptible; this is a measured
improvement, not a hard memory or universal cancellation guarantee.

The first unmodified run completed six NS road routes on an 8-core, 16 GiB Mac:

| Fixture/profile | Search seconds | Distance | Known dirt |
| --- | ---: | ---: | ---: |
| First NS fixture / Dirt | 5.623 | 202.31 km | 66% |
| First NS fixture / Balanced | 11.392 | 188.00 km | 54% |
| First NS fixture / Clean | 0.366 | 194.53 km | 0% |
| Long NS / Dirt | 11.540 | 510.71 km | 52% |
| Long NS / Balanced | 11.746 | 641.26 km | 46% |
| Long NS / Clean | 0.647 | 335.15 km | 0% |

Decode/preparation before requests was 1.027 seconds; process-group peak RSS was
250.953 MiB. The existing fixture name includes "short", but this is a regional
ride, not a short urban hop. This is a fresh process, not a flushed OS disk cache.
Long-route coherence/backtracking and profile differences still require review.

The independent V4 oracle passed source-direction, access, continuous turn-history
and distance-accounting checks for all six road walks. Explicit start approach
lines of approximately 79–82 m are reported separately and remain unverified
off-road approaches. No fuel chain or physical station access was certified.

Cancelling the unchanged native search after 20 ms still yielded a route **5.525
seconds after cancellation**. The private callback prototype returned incomplete
in **0.204 seconds after cancellation**; a 20 ms search budget returned incomplete
after 0.215 seconds. This overshoot exposes remaining preparation work, so 20 ms
is not a strict deadline guarantee. Clean and Dirt recovery searches then returned
the same distances/surface percentages. The repeat six-case matrix returned exactly the same legs, coordinates, distances
and surface percentages in every case; all six independent source audits pass.
Its sampled peak was 242.203 MiB, and the six search times were 5.584, 11.688,
0.504, 12.305, 11.691 and 0.656 seconds. One before/after matrix is insufficient
to assign small latency changes to overhead rather than noise. See
[the evidence receipt](device-workload-evidence.json).

## Economics and qualification limits

`workload-assumptions.json` models several hypothetical regional/border/long-haul
mixes and local success rates. It uses prior serial laptop route times only as a
rough work proxy, not CPU or hosting cost. For example, assuming 80% regional
requests and 80% successful regional offload avoids 64% of requests but about 45%
of that time proxy. With 30% long-haul requests, the corresponding 40% request
reduction saves only about 10% of the proxy. None of these are observed usage or
predicted savings. With server escalation disabled, declined/incomplete local
requests also avoid server work, but are not successful rider outcomes.

Regional execution, request validation, route retention and cache edits are the
credible starting scope. Continental phone routing, complete fuel continuity,
custom settings, multi-region equivalence and actual iPhone budgets remain open.
Do not test a huge matrix against the known unsupported fuel/history path.

Next integration is a native lifecycle adapter carrying this same immutable
contract, complete preparation/search cancellation and memory-pressure handling,
then an authorized physical-device test. Policy scaffolding is small; fuel/history
parity is substantive work. A rough planning allowance is 1–2 engineering days for
app harness/lifecycle wiring and a further 2–4 for initial device qualification and
budget calibration, excluding fuel/history repairs. This is an estimate, not a
delivery commitment or a qualification claim.

## Recovery

Private worktree: `/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/.build/engine-architecture`.
Large evidence/build root:
`/Users/richardsmith/.codex/experiments/routing-architecture-20260911/device-workload`.
Use new output directories for every native build; source snapshots and receipts
must remain paired. The source checkout is the main SIDECAR Dirt folder and can
contain work newer than the experiment branch. Never replace its files with these
snapshots. No physical device is authorized by this report; identify a specific
test phone and obtain the owner's installation authorization before device use.

SIDECAR briefly disconnected during setup. The policy prototype was preserved on
internal storage, then copied back byte-for-byte when the owner reconnected it.
All earlier hybrid checkpoints and results remain intact.
