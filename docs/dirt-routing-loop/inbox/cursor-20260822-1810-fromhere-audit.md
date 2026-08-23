# Cursor audit — 2026-08-22 18:10 ADT — From Here functions

**TEST/AUDIT ONLY. No product change.** No stash pop. No packs / manifest. No Vercel.

Worktree: `Dirt-pack-rebuild` / `feature/pack-rebuild-2026-08`.

## How this was tested

| Layer | Result |
| --- | --- |
| `xcode-select -p` | `/Applications/Xcode.app/Contents/Developer` — **not blocked**; no sudo needed |
| Unit tests (iPhone 17 simulator, Dirt scheme) | **PASS** — `ItineraryBuilderTests`, `RoutePlannerModelItineraryTests`, `RiderItineraryTests`, `FuelAssistTests` (ran twice via parallel clones; all cases green) |
| DirtUITests | **Stubs only.** `DirtUITests.swift` launches the app / launch-performance. **Zero From Here flow coverage.** Not a substitute for a device ride. |
| Code audit | `Dirt/Features/RoutePlanning/` + map fuel pins + `ItineraryBuilder` + pack `fuelChain` |
| Live 500/800 km From Here on a real graph | **Not run this turn.** Physical miss already recorded in SoT §10. |

## Per-function table

| # | Function | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | Drop dest pin → route (Point 1 = GPS, Point 2 = pin); single leg when no fuel needed | **WORKS** (code + paint contract). GPS/off-graph still **UNCERTAIN** on-device. | Short tap with `!hasRoute` calls `beginFromHereDestination` then `routeFromHere` (`RoutePlannerModel.swift` 544–558, 621–639, 712–762). Origin is `fromHereStartOverride ?? locationService.currentCoordinate`; apply is `[origin, dest]` source `"fromHere"`. Dest paints immediately; toast `"Calculating route"`. **Passed:** `DirtTests.fromHereTapShouldPaintDestinationBeforeRouteReturns`. No UI test of an actual tap. Off-graph GPS (> `preferredMatchMeters`) asks the rider to tap Point 1 instead of routing. |
| 2 | ~500 km dest + 250 km tank → exactly one auto fuel waypoint (reserve respected) → two editable legs | **UNCERTAIN** (fake path works; live station quality not proven / already failed physically) | **Passed:** `ItineraryBuilderTests.single475KmLegBuildsOneFuelStopAndTwoInRangeLegs` — 475 km OD, usable 237.5 km (250 km × 5% reserve), planted stop → `legs.count == 2`, both hops ≤ usable. **Passed:** `RoutePlannerModelItineraryTests.fromHereFuelBuildSwitchesToPlanWithoutNetworkCalls` — same fake 475 km From Here apply → 2 built legs. Fake `fuelChain` **returns the planted stop**; it does not search stations. Live path is `source.fuelChain` (`ItineraryBuilder.swift` 243–298) then split. **SoT §10 (2026-08-22):** Dirt Dartmouth→Truro-ish, usable 237.5 km, first hop 237.278 km, pump Gulf `osm:n11084635754` ~71 km off-axis, itinerary inflated to 356.7 km / 9% dirt. Spec “sensible in-range station” is **not** currently proven on the live graph. |
| 3 | ~800 km → two fuel waypoints → three legs | **MISSING** as a test; **UNCERTAIN** in product | No DirtTests / DirtUITests case for 800 km, two stops, or `legs.count == 3` from a two-stop chain. Builder **can** emit N+1 hops from `chain.stops` (`ItineraryBuilder.swift` 257–298). Pack `fuelChain` loops up to 12 stops (`RoutingSource.swift` 163–223). JS `fuel-chain.js` `maxStops = 12`. Nothing asserts From Here 800 km → F1 + F2 → three sheet rows. |
| 4 | Each leg individually editable: ride type + Allow Unknown | **BROKEN** on From Here fuel hops. **WORKS** for Plan rider legs / single no-fuel From Here row. | No-fuel From Here uses one global `planner.profile` / `allowUnknown` (`RoutePlannerCard.swift` 329–363) — correct for one rider leg. Fuel-assisted From Here expands `stageList` with per-row chips (`stageBlock` → `setStageProfile` / `setStageAllowUnknown`, `RoutePlannerModel.swift` 675–684). Those hop rows **share one `riderLegID`** (`Stage.init` 44–47). Changing hop 1’s Dirt/Clean/Allow retunes the **entire** Point 1→Point 2 rider leg, not that hop. Reducer per-leg profile **passed** only for distinct rider legs: `RiderItineraryTests.setProfileForOneLegRebuildsFromThatLeg`, `ItineraryBuilderTests.changingSecondLegProfileReusesFirstBuiltLegExactly`. SoT §5: “no hidden subleg hierarchy. Each row may expose its own profile control.” Implementation is the opposite: fuel hops are built children of one rider leg. |
| 5 | Delete a fuel-stop leg → recalc next sensible station | **MISSING** (and blocked by current model) | `canDeleteStage` is false when `endsAtFuelStop` (`RoutePlannerModel.swift` 326–328). `deleteStage` deletes the **rider waypoint after that rider leg**, collapsing fuel hops first so an F pin cannot be stranded (698–708). Card swipe (`RoutePlannerCard.swift` 941–954) only fires when `itinerary.legs.count > 1` — From Here is **one rider leg** (A→B), so swipe never appears. `canDeleteStage` / `deleteStage` are unused by the card. No test: delete F → pick next station. **Conflict:** Rick’s prompt wants delete-and-repick; SoT §5 says fuel rows are **not** deletable and should be **replaced**. Neither delete-repick nor replacement (see #7) is implemented. |
| 6 | Cannot manually add a leg in From Here | **WORKS** | `handleRouteTap` is Plan-only (`RoutePlannerModel.swift` 567–577). From Here short tap does not append (`guard !hasRoute`, 553). Long-press relocates B (`607–616`), does not `appendPlanPoint`. No Add-leg control in `fromHereContent`. |
| 7 | Fuel stop cannot be MOVED; can SELECT an alternate in-range station (halo/pulse) | **BROKEN** as specified. Cannot-move **WORKS**; alternate/halo **MISSING**. | Fuel markers `isLocked: true` (`RoutePlannerModel.swift` 1385–1394). From Here `moveWaypoint` returns immediately (1034–1036). Plan path only accepts `wp:` IDs (1049–1053). **Passed:** `fuelMarkerCannotMoveCanonicalIntent`. Fuel pin tap only `selectPlannerPin` + name callout (`MapLibreMapView.swift` 976–993). No replacement mode, no candidate halo/pulse, no `replaceFuel` / select-alternate in RoutePlanning. `fuelPreviewStops` are locked “Checking fuel stop” pins during planning (1351–1363). `pickFuelStop` (`1767–1798`) is **dead** — only `FuelAssistTests` call it; live routing uses `fuelChain`. SoT §6 replacement mode is documentation, not code. |
| 8 | From Here → Plan a Route prompts keep-current-or-start-new | **WORKS** | `requestMode` from From Here → Plan with a draft sets `showFromHereToPlanConfirm` (`RoutePlannerCard.swift` 306–310). Dialog: Keep → `switchToPlanKeepingFromHere()`, Clear → `switchToPlanClearing()`, Cancel (109–127). Copy: “Keep this as stage 1, or clear it and start fresh.” Keep requires `waypoints.count == 2` else clears (`RoutePlannerModel.swift` 1141–1159). **Passed:** `fromHereFuelBuildSwitchesToPlanWithoutNetworkCalls` — after Keep, still 2 waypoints / 2 built legs, no extra network. |

## Concrete defects (do not fix this turn)

1. **Live auto-fuel station quality (blocks physical From Here acceptance).**  
   Repro already in `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md` §10: Point 1 `44.764823,-63.340271` → Point 2 `45.636595,-63.056267`, Dirt, usable 237.5 km → Gulf `osm:n11084635754` at `45.962505,-63.883625`, hop 237.278 km, 356.7 km itinerary, 9% dirt, 5.5% backtrack. Client/service fuel-planner mismatch also recorded there.

2. **Per-hop profile/Allow is a UI lie on From Here fuel plans.**  
   `RoutePlannerCard.swift` ~961–979 shows independent chips per fuel hop; `setStageProfile` uses `stages[index].riderLegID` (`RoutePlannerModel.swift` 675–678) which is shared across those hops.

3. **Fuel-stop replacement (halo / alternate select) is not implemented.**  
   Spec: SoT §6 “Fuel-stop replacement”. Code: pin select + locked F markers only.

4. **Delete fuel-stop → next station is not implemented.**  
   `canDeleteStage` 326–328 + swipe 941–954 + unused `deleteStage` 701–708.

5. **No automated coverage** for: map-tap From Here; 800 km / two-stop / three-leg; live (non-fake) fuelChain pick; fuel replacement UX. DirtUITests are empty launch stubs (`DirtUITests.swift` 26–34).

6. **`pickFuelStop` is leftover geometry-along-line scoring**, unused by From Here / builder (`RoutePlannerModel.swift` 1767). Live insertion is `fuelChain`.

## What still works

- Canonical A→B From Here apply, dest paint-before-route, Plan-only insert, From Here cannot add a leg, F pins not movable, Keep/Clear mode switch, fake 475 km → 2 in-range hops, per-**rider**-leg profile in Plan.

## Next

**Next agent: Claude.** Plan from this table. Do not treat fake `fuelStops = [...]` tests as proof of live station selection. Physical SoT §10 still blocks fuel-device acceptance until client and service versions match.
