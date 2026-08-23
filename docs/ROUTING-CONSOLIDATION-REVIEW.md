# DIRT — Routing Consolidation Review Queue

**Status:** review only — not routing authority

**Prepared:** 2026-08-22

**Canonical document under review:**
`docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`

This document protects useful product behaviour, engineering contracts, and
test evidence while DIRT consolidates routing documentation. It does not change
the product. No item below becomes policy until Richard marks it Keep or Modify
and it is added to the canonical source of truth. Rejected material remains in
the archive as history.

Some capabilities below are not proposals: they are already-built product
functionality that was omitted from the canonical description. Richard's
reported acceptance level is recorded separately from automated coverage so a
missing focused regression is not mistaken for an unfinished feature.

## How to review

For each numbered item choose:

- **Keep:** add the proposed rule or capability to the canonical document.
- **Modify:** preserve the capability, but revise the proposed contract first.
- **Reject:** do not restore it as active routing authority.

Items marked **Already covered** require no policy change; they are included to
show that the archived material was not lost.

## A. Routing entry points and adjacent product functions

### 1. Route to a group member

**Evidence:** implemented in `RootView`, `GroupsViewModel`, and
`RoutePlannerModel.routeToMember`. A rider can select a group member from the
roster or the member's map pin and create a From Here route to that member. The
group member's live pin is retained when planner markers refresh.

**Proposed canonical rule:** Route to Member is not a separate routing engine.
The member's current coordinate becomes the rider destination and the request
uses the same profile, fuel-range, pack-acquisition, snapping, itinerary, and
failure rules as any other From Here route. Group presence and planner marker
refreshes must not erase one another.

**Disposition:** Preserve. Review only the proposed canonical wording.

### 2. Route to a POI and add a POI as a waypoint

**Evidence:** implemented through the map POI action sheet,
`routeToCoordinate`, and `addPlanWaypoint`.

**Product status:** established and functioning at 100% in rider testing. This
must be preserved during routing consolidation.

**Proposed canonical rule:** Route to POI uses the ordinary From Here pipeline.
Add as Waypoint uses the ordinary Plan pipeline and creates rider intent, never
a special POI-only route or a generated fuel waypoint.

**Disposition:** Preserve. Review only the proposed canonical wording.

### 3. Saved routes, GPX import, continue planning, and export

**Evidence:** saved routes reopen from SwiftData; GPX parsing and import have
tests; an imported track can be displayed or seeded as the first Plan section;
fuel gaps are exported with `FUEL GAP START/END` markers.

**Product status:** GPX import and Continue Planning are established and
functioning at 100% in rider testing. Save Route is also established product
functionality and must not be treated as a future feature merely because focused
end-to-end regression coverage should be strengthened.

**Proposed canonical rule:** Saved and imported routes remain first-class entry
points. Continuing from an imported GPX preserves the imported geometry as the
first planned section unless the rider explicitly asks to rebuild it. Any new
sections use the canonical routing/fuel pipeline. Export must preserve visible
fuel-gap and unknown-fuel warnings.

**Disposition:** Preserve as established functionality. GPX Import and Continue
Planning are accepted at 100%. Review only the proposed canonical wording and
the protective regression scope.

### 4. Navigation obstruction and recovery tools

**Evidence:** implemented incident categories, impassable-edge capture,
confirmed replacement previews, Find Way Around, Backtrack, Return to Network,
and End Stage. The implementation explicitly says it never silently replaces a
route.

**Product status:** already built and approximately 90% complete/accepted. It is
not sufficiently field-tested to call 100%, but consolidation must preserve it
as an existing capability rather than reopening its product design from zero.

**Proposed canonical rule:** During navigation, a rider-reported obstruction is
the approved exception to ordinary zero-backtracking route creation. Recovery
must preserve the remaining itinerary where possible, avoid reported edges,
show a replacement preview, and require rider confirmation. Find Way Around,
Backtrack to a verified junction, Return to Network, and End Stage remain
distinct actions. Incident data must be available to the installed-pack offline
path; shared incident synchronization remains a separate future gate.

**Disposition:** Preserve at its current approximately 90% maturity. Review only
the proposed canonical wording and the remaining hardening scope.

### 5. Map-layer and route-rendering agreement

**Evidence:** the map maintains separate planner, group-member, POI, general
fuel, committed fuel, and navigation markers. The graph lens is intended to
show current Allow eligibility. Route paint and surface totals are derived from
route segments.

**Proposed canonical rule:** Route paint, profile statistics, graph eligibility,
and the route used by navigation/export must describe the same edge data.
Refreshing one marker family must not remove unrelated marker families.

**Decision:** Keep / Modify / Reject

### 5a. Planning versus navigation map controls

**Evidence:** the canonical source reflects the latest approved planning tools:
Packs, Graph, Fuel, Show Entire Route, Re-centre, and compass reset. The active
UI design document still says only Re-centre remains while the planner is open,
and therefore conflicts with the approved behaviour.

**Proposed disposition:** keep the canonical control set. After consolidation,
replace the stale UI-design sentence with a link to the canonical interaction
section. Navigation-only 3D, cue, and rider-status controls remain hidden until
navigation begins.

**Decision:** Keep current / Modify

## B. Itinerary, mutation, and fuel contracts

### 6. Separate fuel-stop and hop-profile overrides

**Evidence:** implemented and tested. `fuelStopOverrides` chooses a station for
a departure anchor; `hopOverrides` changes the routing profile departing a
station. A rider-leg profile change clears both, and orphaned overrides are
pruned when their station disappears.

**Proposed canonical rule:** preserve these as two different intent mechanisms.
They must never be collapsed into one dictionary or inferred from generated
geometry.

**Decision:** Keep / Modify / Reject

### 7. Single mutation door and stale-work protection

**Evidence:** the itinerary reducer, generation guards, immutable build outputs,
and replay log are implemented and tested. Archived law specifies one mutation
door, deterministic waypoint/leg invariants, and coalesced waypoint dragging.

**Proposed canonical rule:** every rider-intent mutation passes through the
canonical reducer. Asynchronous route/fuel results carry a generation and may
only commit if still current. Each adjacent waypoint pair owns exactly one
RiderLeg; IDs remain unique; derived Point/F legs never become durable intent.

**Decision:** Keep / Modify / Reject

### 8. Replayable routing evidence

**Evidence:** itinerary action logging and replay tests exist. Archived phases
used fixed coordinates to reproduce device failures.

**Proposed canonical rule:** a routing defect report must be replayable from
waypoints, order, profile, Allow Unknown, fuel range/reserve, pack revision,
service contract, overrides, avoided edges, and deterministic seed. Logs should
contain state transitions and decisions, not only human-facing strings.

**Decision:** Keep / Modify / Reject

### 9. Precise fuel-gap proof and acknowledgement

**Evidence:** implemented gap states and GPX markers exist. The archived
contract contains useful detail not fully stated in the canonical document.

**Proposed canonical rule:** a proven gap records the best reachable prefix,
last reachable anchor, first known downstream station or waypoint, routed gap
distance, and shortage beyond usable range. It is measured on routed geometry,
not air distance. Proof requires materially different station-chain attempts;
repeating an identical station set is not another attempt. Gap acceptance is
bound to a fingerprint of route, range, reserve, waypoints, stations, profiles,
access policy, and pack revision, and is invalidated when any of those change.

**Decision:** Keep / Modify / Reject

### 10. Fuel failure taxonomy and proof-gated Carry Fuel

**Evidence:** the canonical source already distinguishes Ready, Gap, Unknown,
Interrupted, and Failed. The archived correction adds an operational proof
payload: candidates considered, regions searched, rejection reasons, and
whether search was exhaustive.

**Proposed canonical addition:** Carry Fuel appears only when the proof payload
establishes an exhaustive physical gap. A timeout, cancellation, missing region,
station-source mismatch, seam error, decode failure, or service error offers
Retry/Repair instead. Dense-station territory returning Carry Fuel is a defect.

**Decision:** Keep / Modify / Reject

### 11. Fuel map visibility and replacement interaction

**Evidence:** implemented visible-bounds caching, deterministic clustering, and
candidate halos have local coverage. Archived thresholds are: below zoom 6.5
hidden; 6.5–8.5 clusters; 8.5–10.5 progressively split; 10.5 and above
individual pumps. Failed refresh retains previous same-source data. Reduce
Motion uses a static double ring.

**Proposed canonical rule:** preserve the behavioural contract—stable stations
across actionable zooms, deterministic clusters, retained data on refresh
failure, committed F pins visible independently of the general layer, valid
replacement candidates visually distinct, and Cancel restoring the committed
stop. Treat the exact numeric zoom thresholds as tunable presentation values,
not routing law.

**Decision:** Keep / Modify / Reject

## C. Endpoint, topology, and regional continuity

### 12. Region ownership must not use overlapping bounding boxes

**Evidence:** the archived correction identifies NS/PEI overlap as a systemic
failure mode. It requires compact administrative coverage plus an eligible-edge
probe. Current source reports an eligible-edge resolver and an overlap
regression, but the full contract is not in the canonical document.

**Proposed canonical rule:** endpoint ownership is resolved from compact
administrative coverage and nearby eligible routing edges, never a first-match
rectangular region. The resolved endpoint records region, edge ID, access class,
snap distance, and resolver version. Client and service use the same resolver
contract. Overlap tests cover every touching province/state pair, not only NS
and PEI.

**Decision:** Keep / Modify / Reject

### 13. Eligible-edge snapping contract

**Evidence:** a device pin exposed `snap_no_eligible_edge` until moved to a major
road. Earlier Halifax work established nearest eligible edge within 500 m.

**Proposed canonical rule:** snapping is profile/access aware. It evaluates only
edges eligible under the current profile and Allow Unknown setting, returns the
chosen edge ID/access class/distance, and reports `snap_no_eligible_edge` when
none exists within the approved radius. It must not silently snap to an
ineligible nearer edge. Whether 500 m is the correct universal rider-facing
limit remains a tuning decision.

**Decision:** Keep / Modify / Reject

### 14. OSM normalization and motorized eligibility table

**Evidence:** the archived locked pack standard contains the exact adapter rules:
road classes included/excluded, explicit-surface precedence, major-road paved
default, access precedence, and path/cycleway motor-tag requirements.

**Proposed canonical rule:** restore the exact normalization table as an
appendix inside the single canonical document. In particular, footway,
pedestrian, and steps remain excluded; abandoned/disused and known no/private
access remain excluded; path/cycleway require an affirmative motor tag to be
permissive; lower-class roads without explicit surface remain unknown.

**Decision:** Keep / Modify / Reject

### 15. Safe pack-time stitch law

**Evidence:** archived pack law allows only a tightly bounded repair: a
permissive degree-one local/resource/recreation/track endpoint may connect to a
permissive through node within 150 m. It forbids unknown, restricted, excluded,
or free-space island joins.

**Proposed canonical rule:** preserve this as the only ordinary synthetic stitch
rule unless a new one is separately approved. Every stitch remains auditable
and cannot invent access across space merely because roads appear close.

**Decision:** Keep / Modify / Reject

### 16. Cross-region seam law and seam acceptance matrix

**Evidence:** archived law requires OSM-only seam identity, exact quantized
vertices on the same OSM way, zero artificial gap, bidirectional tests, and
urban clearance. Historical Atlantic seam doors include NS–NB at Tantramar,
NB–PE at Confederation Bridge, and NB–QC at Dégelis.

**Proposed canonical rule:** preserve the topology laws and a maintained seam
acceptance matrix for every touching province/state pair. Treat named historical
doors as regression fixtures, not hard-coded route instructions or the only
legal crossings.

**Decision:** Keep / Modify / Reject

### 17. Urban-core and settlement avoidance detail

**Evidence:** archived Clean law used population-derived walls and labelled
fallbacks, including edge-segment intersection, overlapping adjacent urban
boxes, and seam clearance. Its exact historical thresholds were cities at
20,000 and towns at 50,000, with missing city population treated as core.

**Proposed decision:** preserve the behavioural law—recognized major cores are
walls, intersection is evaluated along the full edge, adjacent cores cannot be
threaded through a box gap, and relaxation requires a proved no-path with an
explicit fallback. Review the numerical thresholds and data derivation before
restoring them because “city 20k / town 50k” is counterintuitive and may be
historical implementation rather than desired product policy.

**Decision:** Keep / Modify / Reject

## D. Pack build, release, and reproducibility

### 18. Full immutable pack release gate

**Evidence:** archived pack quality law documents a repeatable gate that is more
complete than the canonical summary.

**Proposed canonical rule:** each release records the OSM source URL/timestamp/
checksum; adapter version; graph/geometry/fuel sizes and checksums; edge and
station counts; access/surface audit; stitches; seam tests; route matrix;
benchmark; service contract; and physical acceptance. A single-region promotion
must never overwrite unrelated manifest entries. Live validation and installed
consumer use must resolve to the exact same approved bytes.

**Decision:** Keep / Modify / Reject

### 19. Real-world data corrections

**Evidence:** archived pack law says a surface/access mismatch is investigated
by OSM way ID; correct OSM upstream or record a known source limitation. Do not
invent a private local surface override merely to make a benchmark green.

**Proposed canonical rule:** restore this as release law. Product telemetry may
record field evidence, but changing foundational eligibility/surface requires a
traceable source correction and pack rebuild.

**Decision:** Keep / Modify / Reject

### 20. Pack/search separation and benchmark discipline

**Evidence:** already substantially covered in canonical Sections 9 and 12.

**Disposition:** **Already covered.** Retain archived tables and hashes only as
historical evidence. Do not restore stale candidate IDs or green counts as
current truth.

## E. Performance and diagnostics

### 21. Route-response cache identity

**Evidence:** archived engineering contract keys a route by exact anchors,
profile, Allow Unknown, routing source, pack revision, arrival edge, and the set
of prior edge IDs. Prior edges are meaningful anti-backtracking input; they
cannot be removed from cache identity. Sorting and hashing identical sets
allows legitimate hits.

**Proposed canonical rule:** restore this cache identity contract. A cache hit
must never cross pack revisions, service contracts, access policy, profiles, or
anti-backtracking history.

**Decision:** Keep / Modify / Reject

### 22. Bounded progressive fuel planning

**Evidence:** current/archived implementation uses progressive fuel windows,
historically up to three stops per request, a six-second window budget, an
itinerary-wide budget, a two-retry bound, and a station-set signature to prevent
no-op retry loops.

**Proposed canonical rule:** keep the principle, not necessarily the historical
numbers: long chains commit proven hops progressively; each search window and
the whole itinerary have explicit budgets; retry is bounded; an identical
station-set signature ends a no-op retry; timeout is Interrupted, never Gap.
Numeric budgets are benchmark-controlled operational settings.

**Decision:** Keep / Modify / Reject

### 23. Diagnostics and client/service compatibility

**Evidence:** the current blocker exists partly because production exposes no
contract/commit identity. Archived phases require pass status, fallback reason,
pop/time caps, candidates, rejection reasons, source, and pack revision.

**Proposed canonical rule:** every route/fuel response exposes client contract,
service contract/build, source, pack revision, snap result, successful search
tier, caps, fallback, considered candidates, and final selection. A contract
mismatch blocks acceptance and is reported honestly; it never masquerades as a
route or fuel failure.

**Decision:** Keep / Modify / Reject

## F. Conflicts that must not be restored silently

### 24. Clean-first threshold

**Conflict:** archived documents variously say Clean-first for every cross-region
route, for long fuel chains, or for more than three pumps. The latest canonical
decision says automatic Clean-first only for a rider segment of at least
1,000 km.

**Recommendation:** Reject the older triggers and retain the current 1,000 km
rule unless Richard deliberately broadens it.

**Decision:** Keep current / Modify

### 25. Live-first versus installed-pack-first

**Conflict:** many archived documents and current source comments describe live
routing whenever online. The approved canonical intent is installed-approved-
pack first, with live candidate validation and an explicit live route after a
declined download.

**Recommendation:** Keep current canonical policy. Treat old live-first text as
implementation debt, not competing authority.

**Decision:** Keep current / Modify

### 26. Exact corridor tiers and progress guards

**Conflict:** archived search uses fixed 50/100/150/200 km tiers and historical
forward-progress limits. Current canonical policy makes corridors adaptive,
internal, benchmark-driven, and subordinate to profile intent.

**Recommendation:** do not restore historical numbers as product law. Preserve
them only as tunable implementation candidates measured by fixed benchmarks.

**Decision:** Keep current / Modify

### 27. Mid-navigation reroute collapsing the itinerary

**Conflict:** archived behaviour says off-route rerouting may collapse a Plan
into a new From Here route from GPS to the preserved destination. That can erase
rider waypoints, fuel intent, and route character.

**Recommendation:** treat collapse as a defect or last-resort recovery requiring
rider confirmation. Normal recovery should replace only the affected remaining
section and preserve downstream rider/fuel anchors.

**Decision:** Keep recommendation / Modify / Reject

### 28. Offline map-corridor implementation state

**Conflict:** active and archived documentation disagree about whether Start
currently downloads corridor basemap layers; source contains a preparation path,
while older notes report it disabled after a MapLibre regex crash.

**Recommendation:** retain the canonical target but mark the as-built state
unverified until a device test proves corridor tiles, regional packs, offline
zoom, and obstruction rerouting after connectivity is removed.

**Decision:** Keep recommendation / Modify / Reject

## G. Future ideas found in the archive — not approved functionality

### 29. Surface-dependent fuel economy

Archived roadmap proposes consuming more range on dirt than pavement. DIRT
currently models routed kilometres only and has no tank-volume/consumption
model. This should remain a future research item, not be restored as active
routing law.

**Decision:** Future / Reject

### 30. Multiple complete route alternatives per leg

Archived roadmap proposes two or three complete candidates with dirt, distance,
backtrack, and meander comparisons. This may improve rider choice but has not
been approved and would materially increase search cost and interface scope.

**Decision:** Future / Reject

### 31. Secondary government road/trail overlays

Archived material contains DRA, FTEN, NRN, NSTDB, and similar overlay plans.
Current product law is OSM-only foundational routing. Secondary sources should
remain a future evidence project after OSM passes, never silently re-enter pack
normalization.

**Decision:** Future / Reject

## H. Recommended consolidation sequence after review

1. Richard marks each undecided item Keep, Modify, or Reject.
2. Only accepted language is merged into
   `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`.
3. The canonical document receives an implementation-status table separating
   product law, implemented-and-tested, implemented-but-unverified-on-device,
   and not-yet-implemented.
4. Active non-routing documents link to the canonical sections for Route to
   Member, POI routing, GPX/saved routes, map presentation, and navigation
   recovery instead of restating routing law.
5. Archived routing documents remain intact under `docs/archive/routing/` as
   evidence. They are not deleted.
6. A repository-wide reference check confirms no active document or source
   comment treats an archived file as authority.

## I. Implementation evidence and missing regression coverage

This distinction matters: product acceptance, source presence, and automated
coverage are three different facts. Missing focused coverage identifies a
hardening task; it does not demote rider-accepted functionality to a proposal.

| Capability | Product status reported by Richard | Present in source | Automated evidence / remaining hardening |
| --- | --- | --- | --- |
| Route to Member | Existing; acceptance level not assigned in this review | Yes | Add a focused route-to-member regression |
| Route to POI | 100% functioning | Yes | Add focused regression to protect it |
| Add POI as Plan waypoint | 100% functioning | Yes | Add focused regression to protect it |
| Save/reopen route | Established and functioning | Yes | Strengthen end-to-end reopen/navigation coverage |
| GPX parse/import | 100% functioning | Yes | Parser and fuel-gap export tests exist |
| Continue planning from GPX | 100% functioning | Yes | Add focused continuation regression to protect it |
| Hop-profile override | Existing | Yes | Itinerary/model tests exist; device acceptance remains separate |
| Fuel-stop replacement override | Existing | Yes | Builder/model tests exist; current fuel-selection defects remain separate |
| Incident avoid/backtrack/recovery | Approximately 90% | Yes | Complete offline/device recovery audit remains |
| Group pins surviving planner refresh | Existing intent; acceptance level not assigned | Yes | Add focused integration regression |
| Fuel station clustering/candidate halos | Existing | Yes | Local tests recorded; current physical acceptance should be reconfirmed |
| Offline corridor and pack preparation | Target approved; as-built state disputed | Conflicting evidence | Requires end-to-end connectivity-loss proof |

Recommended permanent integration tests, if the corresponding capabilities are
kept, are: Group Member → From Here → fuel-ready route; POI → Route; POI → Add
Waypoint; Saved → reopen → Start; GPX → continue planning; planner refresh while
group pins remain visible; and obstruction → offline replacement while all
downstream anchors survive.

## J. Stale references discovered during the audit

These are cleanup findings, not policy decisions:

- `docs/CHANGELOG.md` contains a historical link to the old
  `docs/SOON-PHONE-PACKS-AND-OVERLAYS.md` location.
- `experiments/bc-osm-only/build-dra-resource-test.js` cites the old
  `docs/08-MAP-REFINEMENT.md` location.
- `RoutePlannerModel.swift` contains a source comment pointing at the former
  `docs/itinerary-refactor` location.
- Several current source comments still describe live-first routing. They are
  accurate descriptions of portions of the as-built client, but conflict with
  the newly approved installed-pack-first target policy.
- `docs/06-UI-DESIGN.md` says only Re-centre remains when the route planner is
  open, which conflicts with the latest approved planning-tool set.
- `docs/07-FUTURE.md` still describes GPX import as future work even though GPX
  parsing, import, display, and continue-planning code now exist.

After Richard approves the final consolidation, historical links should point
to `docs/archive/routing/…`, while active implementation comments should point
to the canonical source and explicitly distinguish current behaviour from
approved target behaviour.

## Audit boundary

This review changed documentation only. It did not change routing code, pack
bytes, manifests, service deployment, simulator state, or device builds.
