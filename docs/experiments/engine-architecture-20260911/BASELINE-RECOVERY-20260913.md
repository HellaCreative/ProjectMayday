# Baseline recovery — September 13, 2026

Status: **recovery investigation; not accepted for phone installation or release**.
 
## Superseding owner direction: production app foundation

The owner clarified that DEV must start from the production/TestFlight app code,
preserving its onboarding, UI, and launch-ready functionality while adding
installed offline-pack computation. Restoring the older app shell was the wrong
foundation. The investigation below records an unqualified historical experiment;
it does not establish the approved product UI or a usable DEV candidate.

The production 2 (19) release record in the main worktree identifies release
source `582fcb1` and archive `DIRT-Production-2-19-Final.xcarchive`, with additional
workspace changes recorded at archive time. The later `91cc3cc` app checkpoint
must be reconciled with that release evidence before selecting the exact source.
Historical native revision `71aa7fd` remains routing comparison evidence only.

The obsolete simulator replay was interrupted following this clarification;
its build and test-app processes have exited. The suite did not complete or pass.
No phone installation or production modification occurred. Product parity must
be established on the production-derived DEV candidate before route qualification
and any owner review on the phone.

## Production-derived DEV foundation — build 40

Owner explicitly authorized installing DEV on September 13 to verify the current
production app foundation, before completion of the on-device migration. This
supersedes the earlier no-install boundary for this foundation build only; it
is not route acceptance or permission to modify production.

- App, resources, configuration, Xcode project, and test sources restored from
  `91cc3ccdd9f51fa6ff503f3f06e7cab59b00393e`, the current production app workspace
  checkpoint immediately before graph-loading experiments. Every file in `Dirt/`
  matches that revision. This includes onboarding, Loop, preferences, pin
  confirmation, navigation, profile, Groups, audio, and launch-preparation fixes.
- This is the current production-line source, not a claim of binary identity
  with uploaded TestFlight 2 (19). That archive predates the later workspace
  checkpoint; its release record identifies `582fcb1` plus workspace changes.
- DEV identity remains `com.mayday.dirt.dev`, development accounts/services, with
  the source's immutable `fabric-v4-20260909-02` pack catalog. Production identity
  and release build 19 remain unchanged. DEV build number is 40.
- Only foundation adjustments relative to the source: DEV build number and
  disabling parallel testing. No app routing, fuel, or UI edits are included.
- Foundation planning therefore still follows the production source's existing
  online policy. Build 40 does **not** claim completed local-only routing.
- Historical experiment and replay source are preserved in `4d467b7`; original
  hybrid checkpoint remains `165eac4`. They are not merged into this app baseline.
- Next enhancement must move route and fuel computation to installed graphs,
  preserving the production app and accepted routing contract. Border seams,
  fuel progress, repeated roads, profile semantics, limits/cancellation, and
  full requested/reached destination reporting require replay and phone review.
- Target: White iPhone only. Red and `com.mayday.dirt` are untouched.

Build, installation and owner acceptance results will be appended when observed.

## Historical investigation (superseded as an app foundation)

Worktree: `/Volumes/SIDECAR/LIVE/MAYDAYiOS/Dirt/.build/engine-architecture`.
Branch: `audit/baseline-recovery-20260913`. Production, published packs, physical
phone installation, and remote Git refs are untouched.

## 1. Recovered identities and approved presentation

| Boundary | Exact identity | What it establishes |
| --- | --- | --- |
| Frozen service | `94b467a11375e3ea3233c127b07af2ef039d0658`; tag `routing-rc1-2026-09-03`; `dirt-routing.r0.v1` | September 3 routing/fuel contract; accepted build 2 (13) |
| Native restoration source | `71aa7fd6d396bbf215bc1637ba1e3959f6fcdd6a` | September 6 legal routing, profile selection, fuel and itinerary implementation |
| Accepted physical NS/NB Dirt record | build 2 (23); `fabric-v4-20260908-02`; live `67425f53c32f26bf81911331931462389205bc2b` | Three rider-accepted NB route builds; 250 km tank, 10% reserve, unknown off, automatic fuel on |
| Accepted NS continuity record | build 2 (23); NS02; live `9c15324e6ace23df668c6061e2d4ba2a04b99bc8` | Rider's “Looks really good. Pass” at the recorded Cape Breton pin |
| Preserved experiment | `165eac4`; experimental `fabric-v4-20260909-01` | Rollback/reference for the hybrid work; **not** the accepted routing baseline |

These boundaries are not interchangeable. The physical build-23 records explicitly
identify **live** canary computation and leave offline parity unqualified. The
older numeric oracle is a historical measurement on different V3 bytes and an
older service build, not proof of expected exact V4 geometry. Its Clean multi-stop
row even contains repeated tiny Sydney-area stops; that observation does not
override the frozen forward-progress law.

The restored app shell, theme, planner card, map controls, Groups, Layers, Profile,
and navigation HUD match both `71aa7fd` and the accepted continuity revision
`9c15324`. This task makes no view/layout changes. See
`RECOVERY-SOURCE-INVENTORY.json` for per-file blob identities and comparisons.
Existing later files for unused ride preferences/Loop and pack acquisition are
not evidence that those product flows are accepted or enabled by this recovery.

DEV configuration selects the immutable candidate `fabric-v4-20260908-02`.
Production continues to use its public catalog and ordinary online source policy.
Installed-pack preference is explicitly limited to DEV. Replay checks every
accepted graph, geometry, fuel and seam file against its manifest byte count and
SHA-256. `RECOVERY-JS-CANARY-SUMMARY.json` records the full NS/NB identities.

## 2. Execution and compatibility changes

Relative to `71aa7fd`, the retained compatibility changes are:

- DEV source selection prefers installed coverage, without changing profile,
  fuel, access or route options. This is an execution location choice; it is
  not proof that live and native results already agree.
- Little-endian scalar/array decoding uses unaligned-safe reads.
- V4 compact edge IDs are derived from the pack's canonical OSM way and node
  endpoints when flag bit 4 is present. This restores existing checkpoint code,
  matching the JavaScript V4 decoder; no pack bytes or costs change.
- Accepted seam sidecars fill absent embedded seam metadata. No coordinate-near
  rescue connector or new seam ranking is added.
- The spatial-index cache retains the existing `3da6de4` live-pack identity
  safeguard explicitly required by the September 8 rollback notes. A recycled
  object address must not reuse another pack's spatial index.
- Pack-source failures use the existing typed failure mapping, so a search limit
  or cancellation is not rewritten to a blanket “no route”.
- Test-only injected cache roots and optional catalog refresh isolate replay
  storage. Ordinary construction keeps its existing defaults.
- Both DEV test targets are nonparallel. All test runs use only existing simulator
  `CC6035EE-9C03-48A2-ACBA-DDE3B068642A`, with `-parallel-testing-enabled NO
  -maximum-concurrent-test-simulator-destinations 1`.

The compact-ID omission was a real compatibility defect in the inherited recovery:
V4 omits the old string table, but the reader read it anyway. Empty IDs then made
postprocessing associate different roads with the same prior metadata. The rural
Dirt replay incorrectly reported zero known dirt. Restoring compact IDs changes
that result to approximately 71%, without altering route-selection code.
Whole-table JavaScript edge-ID digests are asserted in the real-pack replay;
a small legacy-versus-derived-ID fixture is also covered.

## 3. Behavioral changes and exclusions

The inherited recovery removes the hybrid fast-search envelope, forced early
pump qualification, destination-escape deferral, Balanced pump-approach fallback,
forecourt snap enlargement and later universal settlement wall. Those were
behavior changes, not performance-only changes. The recovered `FuelItinerary`,
`HopSearchPolicy`, `UrbanCore`, profile costs and `ItineraryBuilder` match
`71aa7fd` exactly. The sole difference inside `OnDeviceRouter` is the documented
spatial-index cache identity safeguard; route selection remains equivalent to
`71aa7fd` on the same correctly decoded graph.

The recovered contract keeps major urban cores as walls with labelled fallback,
and smaller settlements as finite costs. It does not turn every town into a
hard wall. Tests introduced for the later wall were restored to the accepted
`71aa7fd` expectations rather than changing the runtime to satisfy the experiment.

No new Dirt/Balanced definition, dirt percentage target, corridor width, station
ranking threshold, or location-specific repair is introduced.

## 4. Replay protocol and evidence

The September 13 matrix now includes all four NS endpoints and all three profiles;
the temporary first-endpoint/Dirt-only restriction is removed. The NS→NB replay
and real itinerary check remain enabled. The full historical oracle matrix reads
all six cases directly from `scripts/pack-fabric/bench/routing-oracle-cases.json`.

Native oracle replay ports the original forward workflow: 230 km tank, 207 km
usable, unknown off, Clean motorway avoidance on, seed 3511091208, a one-stop
15-second fuel window, inherited road history, excluded committed/rejected pumps,
and at most 16 forward attempts. Every route, fuel request/response, reached
endpoint, original destination and failure is preserved as JSON. Reaching a
bounded prefix is not counted as reaching the destination.

JavaScript comparisons have two explicitly separate protocols:

1. `replay-recovered-v4.js`: historical `9c15324` canary with road-only and
   integrated-fuel requests, accepted V4 bytes and the oracle's coordinates,
   profiles and 207 km usable range. The integrated request permits 16 stops and
   a 20-second canary window; it is not the old one-stop oracle workflow.
2. `replay-recovered-oracle-local.js`: the unchanged `run-routing-oracle.js`
   request workflow against exported historical API handlers. Pack reads are
   served locally; no hosted routing service is invoked. Each case's actual
   request and response are saved, including failures.

Initial findings (not acceptance):

- Historical canary road results return the same 7.445 km/6% known-dirt shape
  for all three short profiles, and the same 95.231 km/~71% shape for rural
  Dirt and Balanced. This is present in the accepted service source, not just
  Swift. The older oracle expects different results on its older bytes.
- Corrected native rural Dirt is about 95.217 km/71%; Balanced about
  92.965 km/66%. Exact geometry parity is not established by these similar totals.
- The September 13 short Dirt request returns a usable result with `popCap`
  refinement diagnostics. It must not be labelled as exhaustive route quality
  or proof that no better Dirt route exists.
- Historical canary fuel requests at 207 km usable include `label_limit`/
  incomplete proofs. A road response retained inside an unknown fuel result is
  not a fuel-complete itinerary. Do not substitute the physical 225 km usable
  setting to make this oracle pass.

Final serial suite totals, output audits and comparison tables are appended below
when execution completes. Earlier diagnostic runs were interrupted after the
compact-ID and cache-identity defects were established; they are not passing
verification evidence.

## 5. Unresolved decisions and acceptance gates

- `71aa7fd` native behavior and build-23 live canary behavior are different
  algorithms. Shared pack identity does not make them exact behavioral twins.
  Where results disagree, preserve evidence and obtain a baseline decision;
  do not retune one algorithm to mimic a percentage.
- Some physical acceptance fixtures named in the September 8 documents are
  absent from both this checkout and the inspected accepted revision's tree.
  The documents preserve coordinates/settings and observed acceptance, but do
  not contain full geometry. This limits reconstruction of exact phone shapes.
- Dirt must retain its requested profile. An equal result can arise from an
  explicitly shared accepted candidate pool; it is not blanket permission for
  a silent Balanced substitute in the native fuel path.
- Fuel progress, repeated roads, tiny stops, partial destination preservation,
  city/town avoidance, legal access and seams require the complete output audit;
  a passing route-count or timing assertion is insufficient.
- The installed-pack lookup still supports previously installed revisions.
  Before any phone qualification, actual installed manifest and file hashes
  must match the accepted candidate; an AppConfig URL alone is not proof.
- All requested comparisons and physical phone acceptance remain gates.
  No phone install is authorized by this report and none has been performed.

## 6. DEV recovery checkpoint and rollback

This branch is the isolated DEV recovery candidate. It preserves the accepted UI,
native routing/fuel source and immutable accepted pack configuration, with the
compatibility corrections above. It is a coherent **recovery checkpoint**, not an
accepted replacement for the live canary.

`165eac4` preserves the original hybrid work. `71aa7fd` remains the native behavior
comparison point, and the September 3 tag remains the frozen service boundary.
Do not reset the primary worktree, publish packs, push remote refs or install on
the phone as part of rollback. The recovery commit containing this report provides
the local return point for subsequent comparison work.

Android outcome requirements remain unchanged: preserve profile and access intent,
prove useful fuel progress, distinguish incomplete calculation from no-path/gap,
and retain destination intent for partial output. Compact-ID decoding and cache
identity are platform implementation requirements; no Android parity pass is
claimed by native simulator results.
