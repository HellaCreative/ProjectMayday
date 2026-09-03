# Android parity catch-up — iOS Aug 8–27, 2026

**Authority snapshot.** iOS repository: `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt`; branch: `feature/routing-itinerary-rebuild`; HEAD: `f353405cc538f8e67388a7de4135014c426c8a0b`; reconciled: 2026-08-27. The checked-in app target is version **2 (build 6)** (`Dirt.xcodeproj/project.pbxproj`, `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`). Android workspace: `/Users/richardsmith/SandBox01/MAYDAYAndroid`; its last meaningful product commit is `8e79931` (2026-08-07).

Production route endpoint: `https://dirt-mayday.vercel.app/api/route`. Before release, Android must `GET` that URL, require `serviceContract == "dirt-routing.r0.v1"`, and record `serviceBuild`; on 2026-08-27 the live response reported `e9bc05fbb76672feb33d23e236b2e0da8604ab6b`, so do **not** assume the iOS repository HEAD is the deployed service build. A different `serviceBuild` is diagnostic unless the Android release deliberately pins one; a contract mismatch is fatal. See `Dirt/Networking/AppConfig.swift:4-20` (`AppConfig`) and `Dirt/Networking/RoutingClient.swift:28-35` (`validateServiceContract`).

Pack manifest: `https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/manifest.json`. Routing authority: `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md` (last reconciled 2026-08-22). Navigation authority: `docs/00-NAVIGATION-SOURCE-OF-TRUTH.md` (last reconciled 2026-08-25). Current Swift and pack-fabric code resolve implementation details; `docs/CHANGELOG.md` is historical evidence and may describe superseded behavior.

Android may assume the production service already runs the current deployed server search and consumes the published R2 graph/fuel fabric, but it must port every client behavior below—including the on-device twin used offline—and must not infer that unpublished iOS HEAD server changes are live.

## 0. Executive work order

1. **P0 — Freeze the contracts and migrations.** Add the service-contract/build probe, current manifest decoding, V2/V3 graph selection, retired-pref cleanup, and live-online routing-source policy. Do this before UI work (`AppConfig`, `RoutingClient.validateServiceContract`, `GraphPackStore`, `RoutingSourcePolicy`).
2. **P0 — Port the routing laws to Android's on-device router.** Bring profile costs, graph-shortest extra-distance budgets, no-backtrack, metro wall, Clean rules, ferry treatment, access semantics, and honest timeout/fallback behavior into parity with Swift and JS (`OnDeviceProfileCosts`, `OnDeviceRouter`, `HopSearchPolicy`; pack-fabric twins).
3. **P0 — Port canonical itinerary and fuel-hop construction.** Build A → F₁ → … → B, use packed `fuel.v1.json`, run bounded forward construction and fuel-hop backtracking, preserve a completed prefix, and distinguish proven gap from unknown/timeout (`ItineraryBuilder`, `RiderItinerary`, `BuiltItinerary`).
4. **P0 — Rebuild pack and Start Nav preparation behavior.** Planning is LIVE whenever online even if a same-province pack is installed. Start Nav still prepares missing published routing packs and first-stage corridor tiles, gates Begin Ride, and offers the same explicit degraded choices (`RoutingSourcePolicy`, `GraphPackStore.prepareForNavigation`, `OfflineMapPrepOverlay`).
5. **P0 — Port navigation truth.** Consume graph maneuvers authoritatively, keep geometry cues as fallback/rally enrichment, implement two cue modes, stable stage identity, monotonic cue phases, named-waypoint countdown, active-stage reroute continuity, keep-awake lifecycle, and ferry presentation (`NavigationSession`, `NavigationCueSettings`, `NavigationHUD`).
6. **P1 — Match fuel/itinerary UI.** Port automatic/manual planning, reserve and usable-range display, stage cards, pump replacement, manual fuel-waypoint actions, gap acknowledgement, prefix-preserving edits, progress, and exact strings (`RootView`, `RoutePlannerCard`).
7. **P1 — Match map and chrome.** Use the iOS dock, control order, paint semantics, Shortbread health-gated source/fallback, landscape packing, and remove Network Lens (`MapControlStack`, `LayersSheet`, `ShortbreadTileSourceManager`, `NavigationHUD`).
8. **P1 — Harden Groups and add stopped-rider tracking.** Match validation, presence freshness, realtime/poll fallback, pins, and stop-trigger thresholds/actions (`GroupsViewModel`, `GroupSafetyPolicies`, `RoutePlannerModel`).
9. **P2 — Reconcile remaining preferences, copy, onboarding, and visual details.** Preserve Google-only authentication and Android's existing freemium/legal behavior; do not introduce iOS-only commerce or auth surfaces.
10. **P0 release gate — Run shared oracles in both routing modes.** Compare Android offline results with Swift/JS fixtures, then smoke-test LIVE, installed-pack-online, offline-pack, cross-region, fuel miss, timeout, ferry, reroute, and degraded Start Nav. Exact geometry may vary only where an explicitly different published pack hash explains it.

## 1. Product laws that changed or were clarified after 2026-08-07

| Law | Old Android assumption | Current iOS law | iOS file:lines | Android must change? |
|---|---|---|---|---|
| Allow unknown | A broad “dirt/unpaved” permission gate may have been inferred. | It permits only `unproven` / `motorized_unknown` access. Ordinary OSM dirt is not gated. Clean forces it off. Unknown access is not permission. | `Dirt/Routing/OnDevice/OnDeviceProfileCosts.swift:343-406` (`accessMultiplier` / paint classification); `Dirt/Features/RoutePlanning/RoutePlannerCard.swift:55-66,984-1005` (`showUnknownAck`, `stageUnknownToggle`) | **P0 must port/verify.** |
| Online versus packs | Installed same-province pack might win, or packs might be acquired so LIVE and PACKS match. | `isOnline ? .live : .pack`; installed packs do not replace LIVE while connected. Planning-pack consent remains a separate pre-build acquisition affordance. Never auto-download merely to make a successful LIVE result match PACKS. | `Dirt/Networking/AppConfig.swift:4-20`; `Dirt/Features/RoutePlanning/Itinerary/RoutingSource.swift:643-701` (`RoutingSourcePolicy`); `Dirt/Features/RoutePlanning/RoutePlannerModel.swift:3035-3037` | **P0 policy change.** |
| Live graph | “Longhaul” or a different server extract may be needed. | LIVE and PACKS use files from the same R2 publication family; no longhaul extract. Production service owns its deployed pack selection. | `AGENTS.md`; `Dirt/Networking/AppConfig.swift:10-20,41-52` | Server already; remove client longhaul behavior. |
| Packs consent | Pack-first means silent acquisition. | Route planning pack acquisition is opt-in. Consent can be declined; online planning then remains LIVE with warning. Start Nav preparation is a separate safety gate. | `Dirt/Features/RoutePlanning/Itinerary/PackAcquisition.swift:28-93,107-192,195-300` | **P0.** Do not conflate the two flows. |
| Foundational versus capillary graph | Provincial supplemental edges might be assumed active everywhere or join spatially. | Current foundational production fabric is OSM-only. If a provincial capillary supplement is activated, it is same-region only, exact/grade-gated shared-node or qualified near-junction joins only, never free-space. Cross-region seams remain OSM/neutral. | `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md` (“Graph fabric”); `scripts/pack-fabric/routing/schema/region-registry.json` | Mostly server/factory. Preserve invariant in on-device loaders; do not invent joins. |
| Dirt versus Balanced | Different labels over substantially the same cost/paint. | They have distinct surface/road costs and objectives. Dirt strongly hunts earned dirt; Balanced targets a dirt percentage band. Paint reports actual routed surface/access, not the selected label. | `Dirt/Routing/OnDevice/OnDeviceProfileCosts.swift:37-109`; `Dirt/Routing/HopSearchPolicy.swift:98-141`; `Dirt/Routing/OnDevice/OnDeviceRouter.swift:2919-3097` | **P0 must port on-device.** Server already for deployed LIVE. |
| Corridor metric | Great-circle cross-track band or route-length stretch. | The Aug-19 product law is extra route distance over the shortest **graph** path, not great-circle XT. **HEAD discrepancy:** `route()` currently enters Dirt/Balanced hard cross-track envelope branches and returns before its later graph-extra block. This is a current iOS defect/contradiction, not permission to call XT the law. | `Dirt/Routing/HopSearchPolicy.swift:225-241`; `Dirt/Routing/OnDevice/OnDeviceRouter.swift:655-746,778-871`; `docs/CHANGELOG.md:33-35` | **P0:** implement graph-extra as the acceptance law and add a parity test; record that literal HEAD results may differ until iOS removes the bypass. |
| Profile extra budgets | Historic Direct/Dirt/Balanced/Clean values may include Direct 15 km and Dirt 50 km. | Direct is retired and must not be exposed or ported (historical 15 km only). Declared/current constants are Dirt = **60,000 m**, Balanced = **40,000 m**, Clean = no corridor/pass 2. HEAD's contradictory envelope path interprets them as base XT widths: Dirt compares 120/60 km then 180/240 km/unbounded for connectivity; Balanced tries 40/80/120/160/240/320 km/unbounded. | `Dirt/Routing/RoutingModels.swift:4-37`; `Dirt/Routing/HopSearchPolicy.swift:5-24,225-241`; `Dirt/Routing/OnDevice/OnDeviceRouter.swift:655-746` | **P0.** Delete/ignore Direct; implement 60/40 km graph-extra law, and keep a regression test exposing the HEAD XT discrepancy. |
| Balanced target | Dirt-metres buckets. | Target final dirt ratio is **45–55%**, chosen in 20 buckets; prefer in-band candidates, otherwise closest to 50%. | `Dirt/Routing/HopSearchPolicy.swift:5-24,98-141` | **P0 must port.** |
| Itinerary | One A→B Dijkstra followed by pumps placed near its line. | Canonical rider intent is a hop chain A → F₁ → … → B. Each hop is routed; fuel candidates become locked/replaceable waypoints. | `Dirt/Features/RoutePlanning/Itinerary/RiderItinerary.swift:107-225`; `Dirt/Features/RoutePlanning/Itinerary/ItineraryBuilder.swift:684-1110` | **P0 client and on-device.** |
| Fuel source | Overpass can drive planning. | Planning fuel comes only from the selected pack's `fuel.v1.json`. Overpass remains viewport POI discovery for non-planning services and must not prove fuel reachability. | `Dirt/Routing/GraphPackStore.swift:1109-1166`; `Dirt/Features/RoutePlanning/Itinerary/ItineraryBuilder.swift:784-1110`; `Dirt/Networking/AppConfig.swift:54-55` | **P0.** |
| Metro-core wall | Generic city preference or Vancouver city-centre only. | Dirt and Balanced prevent crossing a metro core as a shortcut; Vancouver is metro-wide. Clean uses its own paved/town rules. | `Dirt/Routing/HopSearchPolicy.swift:280-345` (`HopSearchContext.cityWall`); `Dirt/Routing/OnDevice/OnDeviceProfileCosts.swift:213-272` | **P0 must port;** server already for LIVE. |
| Immediate backtracking | Search may reuse the edge just ridden. | Hop construction rejects the just-ridden edge (`noBacktrack = true`, factor **4** where scoring a backtrack). Fuel construction may retry earlier pump choices, but that is not permission to U-turn onto the predecessor edge. | `Dirt/Routing/HopSearchPolicy.swift:280-345`; `Dirt/Features/RoutePlanning/Itinerary/ItineraryBuilder.swift:284-572` | **P0.** |
| Clean | A weak “prefer paved” skin over Balanced. | Clean has pavement gravity, no dirt hunt/pass 2/corridor, town local/service penalties, major-highway joining relief, and connector use only as last resort. Unknown access is off. | `Dirt/Routing/OnDevice/OnDeviceProfileCosts.swift:81-109,213-317`; `Dirt/Routing/OnDevice/OnDeviceRouter.swift:748-777` | **P0 must port.** |
| Variety and pass 2 | Unbounded alternative exploration or old route stretch. | Variety window **0.08**, **3** slots; steal a predecessor without re-expanding and guard cycles. Declared pass-2 cap is **18 s / 400,000 pops**; Dirt candidate is **7 s / 200,000 pops**. **HEAD discrepancy:** the early Balanced envelope multiplies the pop cap by 10 (**4,000,000**) and disables variety. `timedOut` must remain honest even when a shortest fallback is returned. | `Dirt/Routing/HopSearchPolicy.swift:5-24,144-227`; `Dirt/Routing/OnDevice/OnDeviceRouter.swift:655-746,778-871,2289-2412` | **P0:** use 18 s / 400k as the shared-law target and test the current iOS discrepancy explicitly. |
| Fuel safety | Tank range alone or decorative stops. | Default tank range **200 km**, reserve **10%**, usable range = tank × (1−reserve). Automatic planning inserts only required stops; a station within **150 m** of a waypoint resets fuel. Forward candidates start at **8 km** and preserve **5 km** destination clearance; prefer candidates near 70% and watch from 50% of usable range. | `Dirt/Features/RoutePlanning/FuelRangePrefs.swift:3-121`; `Dirt/Routing/HopSearchPolicy.swift:5-74` | **P0.** |
| Inter-region routing | All local overlays may participate. | Inter-region hops are OSM-only at seams; supplemental provincial capillary data never leaks across region ownership. | `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`; `Dirt/Routing/GraphPackStore.swift:1109-1166` | Loader/search invariant; server already for LIVE. |
| Graph versions | All packs decode `graph.v2.bin`. | NS, NB, PE, NL, QC prefer `graph.v3.bin` with V2 fallback; all other published regions remain V2. Geometry remains `geometry.v1.bin`; fuel is optional `fuel.v1.json`. | `scripts/pack-fabric/routing/schema/v3-regions.json`; `Dirt/Routing/GraphPackStore.swift:1109-1166` | **P0 loader change.** |
| Start Nav | Offline corridor must be ready, but planning packs may be treated the same way. | The gate remains. Start Nav automatically prepares missing **published routing packs** and first-stage offline basemap tiles, then enables Begin Ride. It also offers explicit degraded choices: live maps only or no offline rerouting. This safety preparation is not planning auto-download. | `Dirt/Features/RoutePlanning/RoutePlannerModel.swift:2680-2842`; `Dirt/Routing/GraphPackStore.swift:529-615`; `Dirt/Features/Navigation/OfflineMapPrepOverlay.swift:28-305` | **P0 behavior change/clarification.** |

Two written-source contradictions matter. First, the product SoT's aspirational pack-first consumer policy is not the current selector: Swift explicitly chooses LIVE online. Second, older UI notes say pack management moved away from Layers, while current Swift still exposes **Offline routing → Downloaded maps** inside Layers. Follow Swift in both cases. The navigation SoT's old “not yet implemented” defect list is also superseded by Aug 26–27 Swift cited below.

## 2. Routing engine + on-device (CRITICAL)

### 2.1 Profile costs, access, paint, and ferries

Port `OnDeviceProfileCosts` as data, not a loose approximation. Surface multipliers in `Dirt/Routing/OnDevice/OnDeviceProfileCosts.swift:37-69` are Balanced `[1.42, 0.98, 0.92, 0.88, 0.96]`, Dirt initial `[16, 0.28, 0.12, 0.06, 0.28]` with unpaved multipliers `[1, 0.58, 0.38, 0.28, 0.55]`, and Clean `[1, 60, 80, 100, 12]` for the source-defined surface order. Preserve named categories rather than relying on array positions in Android. The corresponding final Dirt factors include gravel **0.1624**, access **0.0456**, track **0.0168**, and unknown **0.154**.

Road-tier multipliers in `OnDeviceProfileCosts.swift:81-109` are: Clean freeway `.94`, arterial `.98`, collector `1.18`, ramp `.96`, local `2.6`, service `3.2`; Balanced freeway `3.2`, arterial `2.4`, collector `1.08`, ramp `2.8`, local `1`, service `1.15`, resource `.92`, recreation `.90`, track/double `.92`, unknown `1`; Dirt freeway `14`, arterial `9.5`, collector `2.4`, ramp `12`, local `.78`, service `1.4`, resource `.40`, recreation `.38`, track/double `.30`, unknown `.95`. Also port late-join, Clean town behavior, and highway relief from `OnDeviceProfileCosts.swift:189-317`: major-highway pin radius **18 m**, join relief **6 km**, Clean arterial avoidance ×**8**, freeway/ramp ×**40**, and away gravity **2–2.5 per km**. Keep access/paint classification at `:343-406` and ferry fallback speed **18 km/h** at `:417-430`. Ferry distance/time is real, but is excluded from paved/dirt/unknown percentage denominators (`Dirt/Routing/OnDevice/OnDeviceRouter.swift:3017-3025`).

The live twin is `scripts/pack-fabric/routing/lib/profile-costs.js` (`surfaceMultiplier`, `roadClassMultiplier`, highway/town/access helpers, lines 29-127,182-288). Port/re-run `DirtTests/OnDeviceProfileCostsTests.swift`, `DirtTests/RoadTierE4Tests.swift`, `DirtTests/FerryLockstepTests.swift`, and JS `profile-costs.highway.test.js` / `ferry*.test.js`.

Inputs are edge surface, road tier, access state, ferry flag, location/context, profile, and Allow Unknown. Outputs are eligibility, cost multiplier, paint/access family, and warning/stat contributions. An unproven access edge without acknowledgement is ineligible; do not translate “unknown” into “dirt.” Never synthesize a connector merely because snapping or component search failed.

### 2.2 Graph-shortest baseline, pass 2, and honest fallbacks

The declared algorithm in `HopSearchPolicy.extraBudget` (`Dirt/Routing/HopSearchPolicy.swift:225-241`) first finds an eligible shortest graph route. Dirt and Balanced then search inside shortest distance plus **60,000 m** or **40,000 m** respectively; Clean stops after its paved-gravity search. Shared-law pass 2 is **18 seconds / 400,000 pops**, while Dirt candidate work is **7 seconds / 200,000 pops**. If objective search times out and a valid shortest route exists, return the fallback but stamp `searchMeta.timedOut = true`; never present it as fully optimized. Reverse-shortest and timeout stamping live at `Dirt/Routing/OnDevice/OnDeviceRouter.swift:2289-2412`.

**Committed-HEAD discrepancy to keep visible:** `OnDeviceRouter.route` at `:655-746` returns from newer Dirt/Balanced envelope branches before reaching the graph-extra implementation at `:778-871`. Dirt currently tries hard cross-track widths 120/60 km, then 180/240 km/unbounded for connectivity, at 7 s/200k per candidate. Balanced tries 40/80/120/160/240/320 km/unbounded at 18 s/**4,000,000** pops and returns the first success. The JS router also contains corridor-envelope behavior (`scripts/pack-fabric/routing/lib/router.js:2177-2418`). For Android catch-up, implement the named graph-extra product law and add an oracle that documents literal HEAD divergence; do not silently describe the envelope as graph-extra. This is the one routing area where behavioral parity and the explicit current product law cannot both be claimed.

Balanced optimizes final dirt ratio **45–55%**, not dirt metres. Search context sets no-backtrack, factor **4**, metro-core wall, and non-Clean variety at `HopSearchPolicy.swift:280-345`. Variety is a **0.08** window with **3** slots; `HopSearchPolicy.swift:144-227` steals a predecessor without re-expansion and guards cycles, so Android must not implement this as unbounded k-shortest-path search. Port the JS twin `scripts/pack-fabric/routing/lib/hop-search.js` (`HopSearchPolicy`, candidate/variety selection, lines 9-39,176-258) and validate with `hop-search.test.js`, `router.backtrack.test.js`, `router.dirt-objective.test.js`, and `scripts/pack-fabric/routing/bench/run-routing-oracle.js`. Do not port the uncommitted worktree's new “minimum 1 km earned dirt excursion” repair loop: it is not in documented HEAD `f353405…`.

Inputs are snapped graph nodes/edges, profile/access policy, region graph, predecessor edge, wall/seed context, and budgets. Output includes geometry, segments, maneuvers, stats, warnings, debug/search metadata, or a typed failure. Do **not** port FTEN, Direct, the old stretch-factor corridor, great-circle cross-track bands, a free-space join, or an unlimited second pass.

### 2.3 Canonical itinerary hop builder and fuel backtracking

The canonical model is rider intent (`RiderItinerary.swift:3-225`): ordered legs own profile, Allow Unknown, highway/back-road policy, hop/pump overrides; it does not store derived fuel geometry. `BuiltItinerary.swift:94-137` stores reusable route output and prefix state. `ItineraryBuilder.swift:684-1110` constructs A → selected packed fuel candidates → B one hop at a time. A waypoint within **150 m** of a packed station replenishes fuel. Automatic mode begins watching at 50% of usable range, prefers near 70%, requires at least **8 km** forward progress, retains **5 km** destination clearance, and never exceeds one full usable tank (`HopSearchPolicy.swift:5-74`).

On a dead-end candidate, backtrack through earlier pump choices for at most **2** itinerary-level attempts (`ItineraryBuilder.swift:284-572`). Fuel search uses at most **16** windows and **15 seconds** per window (`ItineraryBuilder.swift:1191-1334`). Only an exhausted, complete search proves `fuelGap`; timeout/service/pack uncertainty is `fuelUnknown`, not a scary false gap. Destination escape is checked at `ItineraryBuilder.swift:626-671`. A route build progress watchdog fires at **20 seconds** (`ItineraryBuilder.swift:4-24`). Completed stages/prefix geometry and fuel state survive downstream edits where still valid (`ItineraryBuilder.swift:38-70,1477-1564`; `BuiltItinerary.swift:94-137`).

Long regional LIVE chains also use resumable pump windows. If the selected
profile proves the approach to a forward pump inside that approach's deadline
but the continuation reaches the outer window deadline, accept the routed pump
prefix with `windowComplete=false` and resume from that pump. Never accept a
pump whose approach itself missed its deadline, and never reinterpret an
exhausted no-forward-station result as a timeout. Do not pre-measure the entire
multi-region profile ride before planning fuel: use the endpoint lower bound to
seed stop count and prove each regional route and tank-limited hop as it is
committed.

Android inputs: canonical rider legs, usable range/reserve, selected source and pack identities, packed stations, completed prefix, session seed. Outputs: built stages with stable IDs, route geometry/stats per hop, locked/replaceable pump choices, progress, and `none/pending/gap/unknown/error` fuel state (`BuiltItinerary.swift:25-48`). Port `DirtTests/Itinerary/*`, JS `fuel-chain*.test.js`, `router.cross-province-fuel.test.js`, and compare against the routing oracle. Do not query Overpass to fill a planning gap; do not drop a pump onto a prebuilt polyline; do not discard completed stages during a safe edit.

### 2.4 Maneuvers

Generate graph-decision maneuvers after the final graph path (`Dirt/Routing/OnDevice/OnDeviceRouter.swift:3100-3183`). Ignore parking aisle/driveway/service noise, require an alternative decision edge of at least **30 m**, and treat under **30°** as straight. Emit stable maneuver IDs so navigation can rebase rather than replay cues. The JS twin is `scripts/pack-fabric/routing/lib/router.js:706-776`; port `router.maneuvers.test.js`. Geometry heuristics remain a fallback when a response truly lacks graph decisions, not a co-equal source.

### 2.5 Failure contract

Use the typed on-device failures and rider copy in `Dirt/Routing/GraphPackStore.swift:1893-1912`, and preserve server warnings/failures from `scripts/pack-fabric/routing/lib/router.js:2433-2480`. At minimum distinguish snap failure, disconnected components, eligible-path failure, search safety limit/timeout, absent pack, and proven fuel gap. No failure permits a free-space connector.

## 3. Live API contract

`POST https://dirt-mayday.vercel.app/api/route` with the request model in `Dirt/Networking/RoutingModels.swift:87-297`: endpoints/coordinates; `profile` (`cleanest`, `balanced`, `dirt`); access/highway/back-road controls; region/graph selection; seed/session context; predecessor/no-backtrack context; and fuel-chain fields when requested. Direct is invalid. Keep Android's JSON decoder forward-compatible with optional fields.

Response modeling is `RoutingModels.swift:521-744`. Consume status/error/message; `distanceMeters`, `movingSeconds`, `elapsedSeconds`; geometry and typed segments; maneuvers; warnings; `stats` including dirt/paved, `unknownAccessPercent`, unknown-surface/surface-family data; backtrack and restricted-edge metrics; and `debug` including `routingRevision`, `graphMode`, `searchMeta`, fallback, pack identity/hash, diagnostics, `failureReason`, `searchMs`, and pop count. `searchMeta.timedOut` is authoritative even on a usable fallback. Record `serviceContract` and `serviceBuild` from every response.

The handler is `scripts/pack-fabric/api/route.js:12-60`: complete success **200**, request error **400**, incomplete/route failure **422**, unavailable/internal **503/500**; server max duration **300 s**, memory 2048 MB. iOS transport budgets are **90 s** for a normal single request and **240 s** for long multi-region work; resource/request timeout is **300 s** (`Dirt/Networking/RoutingClient.swift:4-26`). A fuel-chain call starts at **30 s**, but individual windows use **6 s** and the client bounds the request to the search budget plus **1.5 s** (`RoutingClient.swift:105-159`). “Long” here is a timeout class, not a longhaul extract.

At startup or diagnostics, GET `/api/route`, require `dirt-routing.r0.v1`, and log `serviceBuild`. The service sets the build from deployment git metadata (`scripts/pack-fabric/routing/lib/service-contract.js:3-18`). Do not hard-fail merely because it differs from this iOS HEAD; do fail a contract mismatch. Log response pack hashes so a LIVE/offline difference is explainable.

Region IDs are lower-case province/territory IDs from the manifest. NS/NB/PE/NL/QC prefer V3; remaining regions decode V2. This is a client loader concern offline; LIVE tells Android `graphMode`/pack identity and already performs deployed server search.

Rider-visible failures/warnings must preserve these exact meanings:

- `Could not snap to an eligible graph edge. No free-space connector was created.`
- `A and B are on different connected components. No free-space join was invented.`
- `Unknown access is not permission and may include closures, private land, seasonal restrictions, or enforcement.`

Clean-specific fallback copy comes from `router.js:2453-2467` and the current iOS mapping in `RoutePlannerModel.swift:2464-2477`; do not convert it to a generic “network error.” For on-device equivalents use `GraphPackStore.swift:1893-1912` verbatim after mapping Android error types.

Current source selection is decisive: online always LIVE, including an installed same-province pack; offline uses an eligible installed pack. `RoutingSourcePolicy` at `RoutingSource.swift:643-701` is the oracle. A successful LIVE route must not show “Grab it from PACKS.” Planning acquisition consent may occur before a build when required approved packs are missing (`PackAcquisition.swift:107-300`), but decline leads to LIVE—not a fabricated match download.

## 4. Packs / PACKS sheet / offline

The live manifest is `pack-manifest.v1`, pack format `graph.v2`, geometry format `geometry.v1`, publication version `v1`, and base path `/app/data/packs/v1`. Each region advertises files by `name`, `bytes`, and SHA-256. Android must validate size and SHA-256 before atomic activation; an incomplete download must never replace a working pack (`Dirt/Routing/GraphPackStore.swift:1931-1947,1995-2008`).

File selection in `GraphPackStore.swift:1109-1166` is:

- NS, NB, PE, NL, QC: prefer `graph.v3.bin`, allow advertised `graph.v2.bin` fallback.
- Other regions: `graph.v2.bin`.
- All: `geometry.v1.bin` where advertised.
- Planning fuel: optional `fuel.v1.json`; absence means fuel cannot be proven, not “no stations exist.”
- Basemap tiles are not graph-pack files. They are prepared separately through the Shortbread/public tile pipeline.

Planning pack download remains consented/opt-in (`PackAcquisitionPrompt`, `PackAcquisitionEvaluator`, `PackAcquisitionCoordinator` in `PackAcquisition.swift:28-300`). The pre-Aug-23 key `dirt.packs.autoDownloadNextRegion.v2` is retired and absent from current Swift. On Android migration, delete it or force it false so an old `true` cannot silently affect planning; do not add a replacement toggle. Current installed-region persistence is `dirt.packs.installedRegionIds` (`GraphPackStore.swift:96-98`).

Start Nav is different. `RoutePlannerModel.startNavigation`, `continueNavigationStart`, and `beginRideAfterOfflineReady` (`RoutePlannerModel.swift:2680-2842`) call `GraphPackStore.prepareForNavigation` (`GraphPackStore.swift:529-615`). Preparation automatically gets missing published routing packs required for offline rerouting and first-stage corridor basemap tiles. `OfflineMapPrepOverlay.swift:28-305` blocks **Begin Ride** until ready, while making degraded choices explicit: **Ride with live maps only** and **Ride without offline rerouting**. Port the state machine, progress, retry/cancel, and degraded acknowledgement; do not reinterpret this as a global planning auto-download preference.

Offline basemap preparation is first-stage-first, capped at **1,200 tiles**, with blocking concurrency **6** and lookahead concurrency **3** (`Dirt/Map/OfflineTileManager.swift:280,536`; `RoutePlannerModel.swift:2678-2842`). Rich basemap resolves through `https://dirt-shortbread-tiles.dirt-shortbread-edge.workers.dev/shortbread/v1/manifest.json`, contract `dirt.shortbread-manifest.v1`, then health-probes the same-host sample tile before use (`Dirt/Map/ShortbreadTileSource.swift:42-99,126-180`). Current release is `maritimes-20260607`, namespace `shortbread-v1`, zoom 0–14, bounds `[-69,43,-59,49]`, template `/shortbread/v1/releases/maritimes-20260607/tiles/{z}/{x}/{y}.mvt`. Outside bounds or on failed validation/probe, use public OSM; do not turn an R2/worker failure into a routing-pack failure.

Current pack management has **not** left Layers: `Dirt/Features/Layers/LayersSheet.swift:27-45,115-151` exposes **Offline routing** → **Downloaded maps**. Match that nesting and ignore older prose claiming it moved. After a successful LIVE route, offer route/navigation normally; do not append obsolete PACKS solicitation copy.

## 5. Fuel + itinerary UX

`Dirt/Features/RoutePlanning/FuelRangePrefs.swift:3-121` owns tank range, reserve, automatic mode, and usable range. Defaults: automatic **on**, range **200 km** (bounds 40–500), reserve **10%** (bounds 0–30). Automatic mode adds only stops needed to finish safely. Manual/off mode adds no automatic stops and makes no fuel-sufficiency claim, but a rider can still add a fuel POI as an explicit waypoint.

Mirror `Dirt/App/RootView.swift:958-1093`: label **Fuel range**, toggle **Automatic fuel planning**, derived **Usable X km**, and **X% reserve**. Supporting text is exactly:

- On: `Dirt adds only the fuel stops needed to finish safely.`
- Off: `Off — Dirt will not add fuel stops or check whether this route has enough fuel.`

During planning, a fuel POI action is **Add as fuel waypoint**; outside planning it is **Navigate to fuel station**. Non-fuel POIs retain waypoint/navigate equivalents (`RootView.swift:68-72`). Planning station candidates must come from `fuel.v1.json`, be listed with the current reachability/order, and become stable itinerary waypoints. `RoutePlannerCard.swift:687-800` renders the stage fuel block and pending/gap/unknown/error states; the replacement action is **Choose another pump**. A selection rebuilds only the affected suffix and keeps the valid completed prefix (`ItineraryBuilder.swift:1477-1564`).

The only proven-gap presentation is `BuiltItinerary.swift:25-48`: `No pump proven in range · X km gap · Y km beyond range. Carry extra fuel or reshape this leg.` A timeout or unavailable fuel sidecar is unknown, not gap. Either state preserves the complete road route; only road-geometry failure blocks completion. Starting a proven-gap route uses the alert **Fuel gap on this route** with actions **Review fuel gap** and **Continue without acknowledging** (`RoutePlannerCard.swift:148-170`). Preserve the distinction even if Android's visual component differs internally.

Progress advances through current stage/pump creation, including **No fuel stop required** and **Creating fuel stop N** paths in `ItineraryBuilder.swift`; the watchdog becomes visible at 20 seconds. Stage cards in `RoutePlannerCard.swift` show ordered Point/Fuel waypoint identity and per-stage profile/policy. Editing a profile, Allow Unknown, hop policy, or generated pump invalidates only its owning primary-to-primary rider leg; topology edits invalidate the affected suffix. A station within 150 m of an explicit waypoint replenishes range and must not be duplicated.

## 6. Navigation (Start Nav, cues, HUD)

Use `docs/00-NAVIGATION-SOURCE-OF-TRUTH.md` for the invariant model and current Swift for shipped status. The Aug-7 Android geometry `NavCueBuilder` is now fallback, not authority.

### Cue source and modes

There are exactly two rider modes (`Dirt/Features/Navigation/NavigationCueSettings.swift:125-174`): **Junction** with subtitle **Essential**, and **Rally** with subtitle **Everything**. Default is Junction. Migrate legacy `bends` to Junction; do not expose “Both,” “Bends,” or a surface-announcement mode. Audio is an independent on/off setting and surface type remains visual only.

Incoming graph-decision maneuvers are authoritative. `NavigationSession.swift:430-487` rebases them to the active stage and only invokes geometry fallback when none exist. Rally may merge geometry curve cues with essential graph cues; Junction does not announce every bend (`NavCueBuilder.swift:15-24`; `NavigationSession.swift:430-467`). Prepare is monotonic and clamped to **160–600 m** using speed × **20 s**; Now is **25–80 m** using speed × **3 s**; slow fallback speed is **8 m/s** (`NavigationCueSettings.swift:176-216`). The voice queue does not interrupt itself, stale Prepare cues are dropped, and voice volume is `.72` (`:218-315`).

### Stage and reroute continuity

Navigation stages are built from the itinerary with stable identity and rider-facing names (`RoutePlannerModel.swift:2876-2930`; `NavigationSession.swift:5-77`). The countdown targets the **next named itinerary waypoint**, not merely an anonymous route stage end; distance/ETA/elapsed are computed at `NavigationSession.swift:94-133`. Continuation preserves start/stage identity (`:136-196`). An off-route event requires distance over **50 m** for **3** strikes, with a **20 s** reroute cooldown (`:239-339`). Replacement rebases the active stage and preserves later stages (`NavigationSession.swift:215-237`; `RoutePlannerModel.swift:3251-3425`). While navigating, reroute tries on-device first, then LIVE when available (`RoutePlannerModel.swift:2990-3032`). Do not restart the whole itinerary or replay passed cues.

Named-stage voice countdown occurs at **2 km** and **120 m**, with monotonic phase transitions (`NavigationSession.swift:342-383`). Conceptual states in the nav SoT include preparation/recalculation/end even though current Swift's compact enum is `idle/prefetching/active`; match behavior, not enum spelling.

### Start, HUD, keep-awake, and ferries

Start Nav runs the offline preparation described in §4, then transitions smoothly into active navigation (`RoutePlannerModel.swift:2680-2930`; `OfflineMapPrepOverlay.swift:28-305`). The route-build progress state remains visible rather than freezing while fuel/stages are constructed.

Match the HUD composition, labels, and minimum targets in `Dirt/Features/Navigation/NavigationHUD.swift`: cue card (`:10-188`), speed/trip metrics (`:189-301`), **REPORT** and **END RIDE** buttons with **48 pt** targets (`:302-359`), bottom panel and next waypoint (`:365-478`), landscape packing (`:586-761`), and recenter (`:762+`). Android density-independent targets must be at least 48 dp; preserve hierarchy rather than substituting Material's default navigation layout.

Foreground active navigation always prevents sleep. Outside active navigation, `dirt.keepAwakeWhileUsing` defaults off and applies only while the app is active; background/inactive clears the request (`Dirt/Features/Profile/KeepAwakePrefs.swift:4-25`; `Dirt/App/RootView.swift:1590-1610`).

Ferry segments are dashed/marine on the map, excluded from dirt/paved percentages, and called out in the route card (`Dirt/Features/RoutePlanning/RoutePlannerCard.swift:850-895`; `Dirt/Map/MapLibreMapView.swift:651-682,871-876`; `Dirt/Routing/OnDevice/OnDeviceRouter.swift:3017-3025`). Navigation announces real graph decisions around the crossing but never TTSes “surface type.”

Stopped-rider group tracking is nav-adjacent but not tied to an active route: see §8. It must not be implemented as a nav reroute mode.

## 7. Map + chrome + Impeccable

The iOS SwiftUI layout is the UI source of truth; do not replace it with the web POC or default Material composition. `Dirt/App/RootView.swift:4-8,669-709` and `Dirt/Features/Map/DockSheetPanel.swift:68+` define the floating four-tab dock: **Layers, Profile, Group, Route**. Only one sheet is open; active treatment is orange with a white stroke; the planning dock is hidden/repacked for active navigation. Preserve spacing, hierarchy, glass/material role, and landscape packing rather than literal iOS APIs.

Control order comes from `Dirt/Features/Map/MapControlStack.swift:56-90`:

1. Active navigation: overview, 3D/2D, cues, compass, rider status, recenter.
2. Planning: 3D/2D, compass, rider status, fit route (only when a route exists), recenter.

Controls are **50 × 50 pt** on iOS (`MapControlStack.swift:95-170`); use equivalent 50 dp touch geometry on Android. Cue settings are a compact popover (`:273-354`). Compass/follow and recenter state must reflect camera state, not merely fire commands.

**Network Lens is removed.** Do not show its button, overlays, or settings; current `LayersSheet.swift:27-151` contains route legend, rider services, offline routing, and basemap only. If Android has persisted Network Lens flags, ignore/clear them. Current environment also resets legacy network presentation flags (`Dirt/App/AppEnvironment.swift:139-142`).

Rich basemap is the health-gated Shortbread source in `ShortbreadTileSource.swift:42-180`, with public OSM fallback as described in §4 and `docs/05-MAPS.md`. Route paint is factual: paved, gravel, loose, unknown surface, unknown access with purple halo, and dashed ferry (`LayersSheet.swift:48-85`; `MapLibreMapView.swift:651-682`). Dirt and Balanced must not share a hard-coded visual claim.

`RoutePlannerCard.StageCard` (`RoutePlannerCard.swift:1370-1445`) is the route-plan unit. The Allow Unknown control reads **Allow unknown access**, except Clean reads **Unknown access off for Clean** (`:984-1005`). Turning it on first shows the alert **Unknown access is not permission** and destructive acknowledgement **I understand — continue** (`:55-66`). Add the footnote/copy, not a generic checkbox tooltip. Navigation landscape uses the packed HUD at `NavigationHUD.swift:586-761`; verify Android small-width and landscape layouts rather than hiding required controls.

## 8. Groups

Android already had the basic Groups wave; verify it, then port these hardened rules and stopped-rider behavior.

Data contracts remain `groups`, `group_members`, `rider_presence`, `rider_alerts`, and `profiles`, with RPCs `join_group_by_invite_code`, `leave_group`, and `delete_group` (`docs/03-GROUPS.md`; current client use in `Dirt/Features/Groups/GroupsViewModel.swift:339-586`). Presence includes user ID, sharing flag/status, latitude/longitude, heading, speed m/s, accuracy m, and `last_seen_at`. Create enforces a 1–60-character name and compensates a partial failure (`GroupsViewModel.swift:425-479`). Join/leave/delete and detail refresh live at `:480-586`; sharing/presence publication at `:760-929`; alerts at `:930-1214`; realtime with polling recovery at `:1215-1483`.

Safety/freshness is exact (`Dirt/Features/Groups/GroupSafetyPolicies.swift:4-77`): local fix maximum age **45 s**; remote presence is live under **120 s**; accuracy must be ≤ **200 m**; reject 0/0, future, stale, or invalid fixes. Map targets remain independent of planner pins and show member name/status with status color. Match detail/status/list hierarchy and invite validation in `Dirt/Features/Groups/GroupsSheet.swift:245-381`.

Stopped-rider tracking uses `StopTriggeredTrackingPolicy` (`GroupSafetyPolicies.swift:92-137`): moving at ≥ **1.5 m/s**, stopped at ≤ **0.8 m/s**, hold **8 s**, and do not retrigger until the target moved ≥ **100 m**. `RoutePlannerModel.swift:3427-3653` owns route-to-member, start/stop tracking, re-evaluation, and rider notice. It routes to the member's valid location without corrupting the user's planner pins or active itinerary. Android `GroupsViewModel` should be audited for every range above; where the Aug-7 implementation is uncertain, **verify on Android** rather than assuming parity.

Authentication remains **Continue with Google only** on Android. Do not port Apple Sign In, email OTP, or magic-link UI while touching group identity.

## 9. Ride intelligence / incidents

Android already shipped around/backtrack/network/end recovery and local incident handling by Aug 7. Keep it and only reconcile interfaces affected by stable stage identity, active-stage reroute, ferry segments, and the new navigation source rules. Route contribution preferences/queue behavior should be verified against current iOS before changing existing Android recovery.

Cloud incident upload exists, but a downloaded cloud incident map/avoidance layer is **still deferred on iOS**. Current code records/uploads local reports and retries queued submissions (`Dirt/Features/Navigation/RouteIncidents.swift:42-85`; `Dirt/Features/Navigation/RouteIncidentCloudQueue.swift:3-62`; `Dirt/Features/Navigation/RideIntelligenceService.swift:14-73`). There is no shipped incident-fetch, cloud paint, or avoid-pull contract to port. Do not invent one this wave. Local per-request avoidance already present on Android should remain local unless current Android verification finds a regression.

## 10. Prefs / keys / first-run

Persist with Android-native storage but preserve meanings/defaults and perform one-time migrations.

| iOS key | Default | Android action / migration | Current authority |
|---|---:|---|---|
| `dirt.rider.fuelRangeKm` | 200 km | Add/verify; clamp 40–500. | `FuelRangePrefs.swift:3-121` |
| `dirt.rider.lastEnabledFuelRangeKm` | 200 km | Add; restore last non-off range when re-enabled. | `FuelRangePrefs.swift:3-121` |
| `dirt.rider.fuelReservePercent` | 10% | Add; clamp 0–30. | `FuelRangePrefs.swift:3-121` |
| `dirt.rider.automaticFuelPlanning` | `true` | Add; manual mode makes no automatic fuel claim. | `FuelRangePrefs.swift:3-121` |
| `dirt.packs.installedRegionIds` | empty | Keep installed/verified IDs only. | `GraphPackStore.swift:96-98` |
| `dirt.packs.autoDownloadNextRegion.v2` | retired/off | Remove or force false once; an old true must not survive. No replacement planning toggle. | Absence in current `GraphPackStore`; Start Nav is `prepareForNavigation` |
| `dirt.keepAwakeWhileUsing` | `false` | Add/verify; active nav overrides only while foreground. | `KeepAwakePrefs.swift:4-25` |
| `dirt_cue_mode_v1` | Junction | Migrate legacy `bends` to Junction; only Junction/Rally. | `NavigationCueSettings.swift:125-174,218-315` |
| `dirt_cue_audio_v1` | `true` | Keep independent from cue mode. | `NavigationCueSettings.swift:218-315` |
| `dirt.shortbread.forcePublicFallback` | `false` | Debug/diagnostic parity only; never enable by migration. | `ShortbreadTileSource.swift:126-180` and app environment |
| `dirt.route_incidents.pending.v1` | `[]` | Verify queued cloud upload retry; do not add cloud fetch. | `RouteIncidentCloudQueue.swift:3-62` |
| `dirt.contributeTracks.enabled.v1` | `false` | Verify consent remains explicit. | `RideIntelligenceService.swift:14-73` |
| `dirt.contributeTracks.asked.v1` | `false` | Verify one-time ask state. | `RideIntelligenceService.swift:14-73` |
| `dirt.onboarding.introDone.v2` | `false` | Likely present in Aug-7 Android; verify, do not replay for existing users solely for this wave. | `Dirt/Features/Onboarding/*` |
| `dirt.onboarding.coachDone.v2` | `false` | Already expected on Android; verify migration. | `Dirt/Features/Onboarding/CoachMarks.swift` |
| `dirt.lastUserLatitude`, `dirt.lastUserLongitude`, `dirt.lastUserTimestamp`, `dirt.lastUserAccuracy` | absent | Add/verify as last-known fallback only; still apply freshness/accuracy laws. | `Dirt/Location/LocationService.swift` |

`dirt_reports_v1`, existing recovery preferences, account/legal state, and map-style keys likely predate Aug 8; verify on Android rather than duplicating or renaming them. Never migrate a legacy Network Lens or auto-pack flag into an enabled current feature.

## 11. Copy catalog

Use these English strings exactly where the matching state exists; punctuation is part of parity.

| State | Exact iOS copy | Authority |
|---|---|---|
| Unknown toggle | `Allow unknown access` | `RoutePlannerCard.swift:984-1005` |
| Clean unknown toggle | `Unknown access off for Clean` | `RoutePlannerCard.swift:984-1005` |
| Unknown alert | `Unknown access is not permission` | `RoutePlannerCard.swift:55-66` |
| Unknown acknowledgement | `I understand — continue` | `RoutePlannerCard.swift:55-66` |
| Unknown warning | `Unknown access is not permission and may include closures, private land, seasonal restrictions, or enforcement.` | `router.js:2433-2480` |
| Automatic fuel control | `Automatic fuel planning` | `RootView.swift:958-1093` |
| Automatic fuel on | `Dirt adds only the fuel stops needed to finish safely.` | `RootView.swift:958-1093` |
| Automatic fuel off | `Off — Dirt will not add fuel stops or check whether this route has enough fuel.` | `RootView.swift:958-1093` |
| Fuel values | `Fuel range`; `Usable X km`; `X% reserve` | `RootView.swift:958-1093` |
| Fuel POI in planning | `Add as fuel waypoint` | `RootView.swift:68-72` |
| Fuel POI outside planning | `Navigate to fuel station` | `RootView.swift:68-72` |
| Pump replacement | `Choose another pump` | `RoutePlannerCard.swift:687-763` |
| Proven gap | `No pump proven in range · X km gap · Y km beyond planned range` | `BuiltItinerary.swift:25-48` |
| Gap alert/actions | `Fuel gap on this route`; `Review fuel gap`; `Continue without acknowledging` | `RoutePlannerCard.swift:148-170` |
| Fuel progress | `No fuel stop required`; `Creating fuel stop N` | `ItineraryBuilder.swift:827-986` |
| Snap failure | `Could not snap to an eligible graph edge. No free-space connector was created.` | `router.js:2433-2480` |
| Component failure | `A and B are on different connected components. No free-space join was invented.` | `router.js:2433-2480` |
| Nav cue modes | `Junction`; `Essential`; `Rally`; `Everything` | `NavigationCueSettings.swift:125-174` |
| Nav actions | `REPORT`; `END RIDE` | `NavigationHUD.swift:302-359` |
| Start Nav ready action | `Begin Ride` | `OfflineMapPrepOverlay.swift:28-305` |
| Degraded basemap | `Ride with live maps only` | `OfflineMapPrepOverlay.swift:28-305` |
| Degraded rerouting | `Ride without offline rerouting` | `OfflineMapPrepOverlay.swift:28-305` |
| Packs location | `Offline routing`; `Downloaded maps` | `LayersSheet.swift:115-151` |

For Clean urban/paved/town fallback and typed on-device no-path/safety-limit messages, copy the full current strings directly from `RoutePlannerModel.swift:2464-2477` and `GraphPackStore.swift:1893-1912` during implementation. Do not shorten them into “No route,” and do not display a proven fuel gap for `timedOut`/unknown. Remove any post-success **Grab it from PACKS** prompt.

## 12. Explicit non-goals for Android this wave

- No Apple Sign In, email OTP, or magic-link UI. Android remains **Continue with Google only**.
- No staging endpoint; production is `https://dirt-mayday.vercel.app`.
- No marketing site, App Store Connect, Play Store listing work, or iOS release mechanics.
- No StoreKit port. Keep Android Play Billing/freemium as its existing stub unless separately commissioned; do not invent purchase parity in this catch-up.
- No R2 pack rebuild, provincial ingestion, monthly pack operations, Shortbread generation, or deployment. Android only downloads, verifies, selects, and uses published artifacts.
- No Android rewrite of search changes that are server-only when using LIVE; **do** port the matching on-device behavior because offline routing otherwise diverges.
- No Direct profile, FTEN, longhaul extract, old stretch-factor, great-circle corridor, free-space connector/join, or Overpass-backed fuel planning.
- No Network Lens.
- No surface-type TTS. Surface is visual; speech is turns/junctions/rally and named-waypoint countdown.
- No cloud incident fetch/map/avoid-pull layer; it remains deferred on iOS.
- No silent planning download to make LIVE match PACKS. Start Nav's explicit offline safety preparation remains in scope.
- No Material-default redesign and no web POC as UI authority.

## 13. Suggested Android commit sequence

1. `parity: contracts and pack formats match iOS Aug8–27`
2. `parity: on-device profile laws match iOS Aug8–27`
3. `parity: hop search and timeout honesty match iOS Aug8–27`
4. `parity: itinerary fuel chain match iOS Aug8–27`
5. `parity: live-online and Start Nav pack policy match iOS Aug8–27`
6. `parity: graph maneuvers and navigation continuity match iOS Aug8–27`
7. `parity: fuel and StageCard UX match iOS Aug8–27`
8. `parity: map chrome and Shortbread match iOS Aug8–27`
9. `parity: groups safety and stopped tracking match iOS Aug8–27`
10. `parity: prefs copy and migration match iOS Aug8–27`
11. `test: routing and navigation oracles match iOS Aug8–27`

Each commit should compile independently and include its Android tests. Before the final commit, exercise four source states—online/no pack, online/installed pack, offline/eligible pack, offline/missing pack—and prove their source labels, prompts, and failure copy. Then exercise automatic fuel on/off, a proven gap, a timed-out unknown, a cross-region route, a ferry route, an active-stage reroute, and both Start Nav degraded choices. Record the production `serviceBuild` and pack SHA-256 identities with the parity test evidence.
