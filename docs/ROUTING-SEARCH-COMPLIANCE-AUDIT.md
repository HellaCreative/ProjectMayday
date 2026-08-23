# DIRT — Routing Search Compliance Audit

**Status:** local read-only audit; no routing behaviour changed

**Canonical authority:** `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`

**Checkpoint:** `321282ef45065dac0dbf82988012794ccaa3bfc2`

**Branch:** `feature/routing-itinerary-rebuild`

**Pack/release identity supplement:** completed independently in
`docs/CURSOR-PACK-IDENTITY-AUDIT.md`

## 1. Executive assessment

DIRT does not need another wholesale routing rewrite. The repository contains a
substantial canonical itinerary builder, forward fuel planner, live and
installed-pack routers, profile search, endpoint resolver, map projection,
fuel-stop replacement, and regression suite.

The principal risk is contract divergence: several important paths are built
and tested against older rules that no longer match the approved product. A
test can therefore pass while proving the wrong behaviour. The highest-risk
examples are online source selection, Direct's benchmark contract, automatic
Clean triggers, transient fuel-gap acknowledgement, and a benchmark that accepts
any detected backtracking as self-explaining.

The efficient repair is bounded reconciliation, not replacement: prove the
client/service/pack identity, correct the dependency contracts, update the
fixed tests to assert current product law, and then repair only the rows that
fail.

Cursor's independent pack audit confirms that identity proof is the first
dependency, not a precautionary extra. Production live NS and the downloadable
NS objects are the same promoted `ns-osm-20260821-02` bytes, but this worktree's
local graph and fuel sidecars are the older `ns-osm-20260820-01`. The benchmark
loader prefers those local files while its result metadata claims the 02
candidate URL. Therefore the current NS table is historical evidence, not a
valid same-pack baseline for subsequent search changes.

## 2. Baseline evidence

- Documentation authority was committed separately as `321282e`.
- No routing code or pack bytes were changed for this audit.
- `npm test` on the checkpoint: **74 tests, 73 passed, 1 skipped, 0 failed**.
- Latest committed NS benchmark: `1da4442-20260822T160913Z.json`, **35/40
  green**. Its metadata names `ns-osm-20260821-02`, but Cursor proved the local
  loader can shadow that candidate with 20-01 graph/fuel files; it must not be
  used as the comparison baseline until the loader is made identity-safe.
- Swift test source was inspected. No simulator was created or duplicated and
  the Swift suite was not executed during this read-only pass.

Passing tests below are recorded as evidence, but they do not override the
canonical product contract.

## 3. Entry-point convergence

| Entry point | Canonical builder | Finding |
| --- | --- | --- |
| From Here | Yes | Replaces rider intent with Point 1/Point 2, then calls the canonical builder. |
| Plan | Yes | Append/insert/move/profile/Allow mutations go through the reducer and canonical builder. |
| From Here → Plan | Yes | Preserves the built itinerary without another network call; tested. |
| Route to POI | Yes | Becomes a From Here request. |
| Add POI as waypoint | Yes | Appends canonical Plan intent. |
| Route to Member | Yes | Becomes a From Here request, although no focused regression protects the complete group-to-route flow. |
| GPX Continue Planning | Partial canonical entry | Imported geometry is seeded as the first built rider section; new points use the canonical builder. |
| Saved route display | No rebuild by design | Reopens stored geometry. Continuing from it must be treated as a separate transition. |
| Navigation obstruction recovery | Separate controlled path | Intentionally replaces only active remaining geometry and records avoided edges; it must not become a second ordinary planner. |

There is one ordinary itinerary builder, which is a strong foundation. The
remaining entry-point work is regression protection and eliminating small state
differences, not creating more pipelines.

## 4. Compliance matrix

### 4.1 Product objectives and profiles

| Canonical requirement | Status | Evidence and divergence |
| --- | --- | --- |
| Dirt works backward from 100% and avoids purposeless meander | Implemented and locally tested | JS tests explicitly cover highest dirt, less pavement, and no corridor consumption when quality ties. NS Dirt rows are generally strong. |
| Balanced targets closest feasible 50/50 | Partial | Search and tests use 45–55. Current NS baseline has two known misses: 38% and 58%. |
| Direct follows crow-flies alignment and pushes toward 60–70% dirt | **Implemented against an obsolete contract** | Search is geometry-first, but the benchmark only asserts `meters ≤ shortest + 15 km`. Current green Direct rows include 11%, 19%, 33%, 38%, and 47% dirt. The iOS resource-label picker also treats Direct like Dirt by maximizing dirt among available labels. Neither layer expresses the approved “push 60%, prefer 60–70%, normally below 75%” contract. |
| Direct is not a shortest-route profile | **Conflict** | Current benchmark and comments define Direct primarily by shortest graph route +15 km. This is the largest profile-contract mismatch. |
| Clean works from 100% pavement and treats major urban cores as walls | Implemented with evidence | Paved-only first, then unpaved only after proved no-path; urban and settlement relaxation requires `noPath`, not a cap. Tests cover walls, edge intersection, and labelled fallbacks. |
| Clean avoids major highways and major population centres | Partial but substantial | Major-highway penalties and urban walls exist. Some source comments still call Clean “Google/Apple shortest practical pavement,” which is misleading and should not drive future tuning. |
| Corridors are internal adaptive performance controls | Partial | Server ellipse attempts widen adaptively for most profiles; iOS still exposes fixed Direct/Balanced/Dirt corridor constants. Tests lock historical widths. Values are implementation settings, but current tests may block product-correct tuning. |
| Ordinary route backtracking is zero unless proved necessary | **Partial / proof is inadequate** | Prior-edge penalties and metrics exist. However `backtrackSummary` assigns `dead_end_or_only_connector` whenever any prior edge reappears; it does not prove that condition. The benchmark then accepts any non-null reason, making its assertion tautological. |

### 4.2 Road eligibility, surface, and pack fabric

| Canonical requirement | Status | Evidence and divergence |
| --- | --- | --- |
| OSM-only foundational fabric | Implemented in current adapter/tests | Tests prevent provincial capillary edges in foundational OSM output. Cursor will verify current published bytes. |
| Explicit surface wins; untagged minor roads remain unknown; conventional major roads may default paved | Implemented and tested | Node tests passed for all three laws. |
| Access precedence and Allow Unknown semantics | Implemented and tested | Motorcycle override, restricted/private handling, path/cycleway gating, and source identity tests passed. Clean forces unknown off in request construction and router normalization. |
| Safe topology and no free-space joining | Substantial evidence | Component failures are explicit; seam/stitch tests exist. Complete touching-region coverage awaits Cursor's pack audit. |
| Eligible-edge, profile-aware snapping | Implemented server-side and tested | Tests cover nearer ineligible edge rejection, no eligible edge within 500 m, and NS/PE overlap. On-device/live parity and full-border coverage remain unproved. |

### 4.3 Pack source and acquisition

| Canonical requirement | Status | Evidence and divergence |
| --- | --- | --- |
| Approved installed pack is primary consumer source online or offline | **Not implemented** | `RoutingSourcePolicy` logs pack coverage but returns live whenever online. Installed packs are selected only offline. |
| Planning requests missing required packs and asks for download consent | **Not implemented** | The client still exposes a manual Offline Packs browser and downloads required packs at Start Navigation. Waypoint placement does not run the approved consent/acquisition flow. |
| Rider may delete but not arbitrarily pre-download packs | **Not implemented** | The current Offline Packs sheet permits manual province/state downloads. |
| Declined download permits explicit live routing with offline warning | Not implemented as approved | Live routing is automatic online rather than the result of an explicit decline. |
| Update comparison uses immutable identity/checksums and pins itinerary revision | Partial / unproved | Manifest checksums and revision storage exist, but itinerary intent does not visibly persist the exact revision used. Cursor will audit release identity. |
| Start verifies corridor layers and every touched routing pack | Partial | `prepareForNavigation` downloads touched published routing packs. Active documentation conflicts over whether basemap corridor packs are currently operational. Requires device proof. |

### 4.4 Itinerary and rider-facing Point/F legs

| Canonical requirement | Status | Evidence and divergence |
| --- | --- | --- |
| RiderItinerary is durable intent; fuel and geometry are derived | Implemented | Reducer, invariants, immutable BuiltItinerary, and generation guards exist and are tested. |
| Flat Point/F rows, no aggregate parent/subleg hierarchy | Implemented and tested | Two-waypoint/one-stop produces two rows; two-stop produces three rows. Rows are generated from BuiltLegs. |
| Fuel waypoints are rigid station anchors with replacement alternatives | Implemented and tested locally | Fuel marker drag cannot mutate intent; selecting a valid alternative records a station override and replans. Device acceptance still depends on correct fuel candidate selection. |
| Per-hop profile and fuel-stop overrides are separate | Implemented and tested | Separate dictionaries, rebuild behavior, and pruning exist. |
| From Here uses Points 1/2 and Plan preserves/renumbers intent | Implemented and tested in reducer/model | Route tap insert and From Here → Plan paths exist. |
| Deleting a rider-ending leg removes its rider waypoint; primary leg only clears | **Partial / conflict** | Generated F-ending rows cannot delete, but `canDeleteStage` permits every non-fuel row, including the sole Point 1→Point 2 primary leg. A current test explicitly expects deleting from two points to leave one waypoint. This conflicts with the latest primary-leg rule. |
| Accepted fuel-gap fingerprints are durable rider intent | **Not implemented as documented** | `acknowledgedFuelGapIDs` is transient RoutePlannerModel state, not RiderItinerary. Its ID omits station set, profile, Allow policy, and pack revision, so it cannot provide the approved invalidation contract. |

### 4.5 Fuel-chain construction and failure honesty

| Canonical requirement | Status | Evidence and divergence |
| --- | --- | --- |
| Fuel is always part of product route creation | Implemented | Product UI always supplies FuelRangePrefs; only internal benchmark diagnostics can use route-only fuel. No product enable/disable toggle remains. |
| Fuel chain builds forward Point→F→…→Point | Implemented and tested | Builder discovers the ordered station chain first and routes only final Point/F hops. |
| Fuel carries across ordinary rider waypoints | Implemented and tested | Multiple tests cover carried fuel, lookahead, late station selection, and waypoint station resets. |
| Fuel recomputes from leg 0 while reusing route geometry | Largely implemented | The builder reuses unsplit rider routes but recomputes derived fuel. Focused tests cover later-leg changes and upstream reuse. |
| Coherent candidate selection rejects random lateral/backward pumps | Implemented in current local service with tests | Six geographically diverse candidates, forward validity, detour bounds, cross-track ranking, and the Gulf-class regression exist locally. Production parity is unproved. |
| Long chains use bounded progressive windows | Implemented | Three-stop windows, six-second request timeout, 20-second itinerary budget, bounded retries, and identical-station-set detection exist. Numeric values remain tuning constants. |
| Automatic Clean foundation only at ≥1,000 km | **Not implemented exactly** | Initial discovery uses Clean for cross-region **or** ≥1,000 km. A second pass also switches to Clean when ≥1,000 km **or more than three stops**. Both broader triggers contradict the latest rule. |
| Gap, Unknown, Interrupted, and Failed remain distinct | **Partial / conflict** | `LegStatus` has pending, built, gap, fuelUnknown, and failed—no Interrupted. Transport/service failures are generally converted to fuelUnknown, losing the approved retryable distinction. |
| Carry Fuel only after exhaustive physical proof | Partial | Carry is tied to `.gap`, but FuelGap lacks the complete proof payload: best prefix, last reachable station, first known far-side anchor, candidates/rejections, and exhaustive flag. Service interruption can be separated from gap locally, but the model cannot express Interrupted. |
| Start/GPX may proceed with a visible accepted gap | Implemented in part | GPX gap markers are tested. Durable acknowledgement and navigation-time visibility still need full contract coverage. |

### 4.6 Service, cache, diagnostics, and benchmarks

| Canonical requirement | Status | Evidence and divergence |
| --- | --- | --- |
| Client/service contract version must match | **Not implemented** | Local fuel service emits `2026-08-22.fuel-coherence.3` on GET and response payload, but Swift `FuelChainResponse` has no `serviceVersion`; the client neither decodes nor asserts it. Route GET/response exposes no equivalent service build contract. |
| Every result identifies routing source and exact pack revision | Partial | Source selection and cache logs include source/revision, and route debug has a routing revision, but no end-to-end enforced response identity proves the deployed service/pack combination. |
| Route cache cannot cross inputs/revisions/history | Mostly implemented | Key includes anchors, profile, Allow, normalized prior edges, arrival edge, backtrack factor, source, and pack revision. Avoid-edge IDs are absent from the key, which is safe only if recovery requests are never cached/reused across different incident sets; this requires explicit verification. |
| Timeout never becomes no-path/gap | Server route largely compliant; fuel client incomplete | Server distinguishes time/pop caps. Fuel service returns window timeout separately, but client model lacks Interrupted and may present it as unknown. |
| Fixed benchmark represents current product law | **Not compliant** | Direct assertion is obsolete; backtrack proof is tautological; five NS rows are red; latest pack is not Cursor's unrecorded rebuilt candidate. The table remains historical evidence, not a complete acceptance gate. |

## 5. Tests that currently protect obsolete or conflicting behaviour

These tests should be revised only after Richard approves the corresponding
repair. Their existence explains why broad “make tests pass” work can preserve
the wrong product:

1. Direct benchmark asserts shortest graph route +15 km rather than aligned
   60–70% dirt intent.
2. Backtrack benchmark accepts an automatically generated reason that does not
   prove necessity.
3. `planModeUsesTheInstalledPackRegistry` verifies only that coverage was
   logged. Its fake live and pack sources are the same object, so it does not
   prove that the installed pack was selected while online.
4. `deleteFromTwoLeavesValidSingleWaypoint` protects deletion of the primary
   leg, contrary to the latest Clear-only rule.
5. Long-route tests protect three-stop windows but do not isolate the approved
   ≥1,000 km Clean threshold from the obsolete cross-region/>3-stop triggers.
6. Corridor tests lock historical constants rather than asserting only profile
   ordering, bounded work, and objective preservation.

## 6. Dependency-ordered repair backlog

No item below is authorized for implementation by this audit alone.

### R0 — Prove release identity before more physical testing

- Make benchmark pack selection explicit and fail closed if local bytes do not
  match the requested immutable release; never let a local file shadow a
  labelled candidate.
- Add a shared client/service contract identity for route and fuel endpoints.
- Decode and enforce it in Swift.
- Report exact source, service build, and pack revision in every debug result.
- Deploy the current local service and replay the known Gulf-pump coordinates.
- Prevent the bare pack-publish path from replacing the 63-region catalog with
  the stale local catalog; promotion must merge and checksum exact release
  bytes.
- Add checksum verification and update detection to installed packs rather than
  accepting any existing file.

**Exit:** the benchmark and White can each prove which client, service, graph,
fuel sidecar, and immutable pack revision produced a route.

### R1 — Align the benchmark with actual profile law

- Replace Direct's shortest+15 km assertion with alignment, dirt-target, and
  bounded-lateral-journey assertions.
- Replace tautological backtrack acceptance with proof-aware evidence.
- Keep Balanced 45–55 and Dirt high-watermark assertions.
- Re-baseline only after the exact NS pack identity is frozen.

**Exit:** green means product-correct, not merely historically compatible.

### R2 — Correct pack-first source selection and acquisition

- Design one required-pack resolver for all entry points.
- Ask consent at waypoint placement, download approved immutable packs, then
  route locally.
- Make explicit live routing the declined-download path, with offline warning.
- Retire arbitrary manual pre-download without removing pack deletion.
- Pin the itinerary to the revision used.

**Exit:** installed-approved bytes are the normal source and behavior is
reproducible online/offline.

### R3 — Reconcile profile implementation

- Give Direct its own explicit 60–70% aligned objective, distinct from Dirt and
  Balanced.
- Remove shortest-route wording/acceptance while retaining useful geometric
  pruning.
- Run fixed profile cases before changing weights.
- Repair the two known Balanced misses without reducing Dirt or Clean quality.

**Exit:** all four profiles are measurably distinct and match the source of
truth.

### R4 — Reconcile long-route and fuel state contracts

- Restrict automatic Clean-first to the approved ≥1,000 km rider segment.
- Add a true Interrupted fuel state.
- Add exhaustive gap proof and a durable invalidating acceptance fingerprint.
- Preserve progressive windows and forward route construction.

**Exit:** long-route speed and fuel failures are both correct and honest.

### R5 — Reconcile itinerary deletion and edit regressions

- Enforce Clear-only removal of the primary leg.
- Preserve flat Point/F rows, station replacement, per-hop profiles, and
  upstream reuse.
- Add fixed regressions for From Here → Plan and every allowed deletion/edit.

**Exit:** rider editing exactly matches the canonical ownership rules.

### R6 — Multi-region, installed/live parity, and final Gate 1 matrix

- Run every touching-region seam/overlap case from Cursor's inventory.
- Run NS, Atlantic multi-region, BC–AB, and BC–WA fixed routes on matching
  installed and explicit live bytes.
- Verify no unexplained geometry, fuel, surface, or failure-state divergence.
- Only then resume White acceptance.

## 7. Recommended immediate decision

The first implementation package should be **R0 only**. It changes observability
and compatibility enforcement before route tuning. Without R0, any phone result
can still be produced by stale server code or different pack bytes, making every
later judgement unreliable.

After R0 and Cursor's pack report, approve R1 before touching search weights.
That order ensures the tests describe the product before engineers optimize the
implementation to satisfy them.

## 8. Audit boundary

This audit changed only this report after the documentation checkpoint. It did
not alter Swift routing behaviour, JavaScript routing behaviour, pack builders,
pack bytes, manifests, deployment configuration, simulators, or White.
