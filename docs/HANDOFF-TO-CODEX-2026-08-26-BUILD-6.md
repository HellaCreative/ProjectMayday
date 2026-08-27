# Dirt Build 6 Handoff — Navigation Start Performance and R2 Preparation

Date: 2026-08-26  
Workspace: `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt`  
Branch: `feature/routing-itinerary-rebuild`  
Starting commit: `7a7b23e7f002109dd4b3730f8f4329a2afda90fe`  
Release at handoff: app version 2, build 5

## Read first

1. This document in full.
2. `AGENTS.md`.
3. `docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md`.
4. `docs/00-NAVIGATION-SOURCE-OF-TRUTH.md`.
5. Read other documents only when the scoped work requires them. Do not reopen routing architecture or cleanup work that is already accepted.

## User-approved operating rules

- Work in the Dirt repository above, not its parent directory.
- Preserve unrelated and Cursor-authored work. Never reset or overwrite a dirty worktree.
- One focused change, then test, revise if needed, and report the result.
- Do not change routing or fuel behavior during this performance pass. The rider has physically tested the current routes and reported that they work very well.
- Do not rebuild or republish live map packs. Cursor is responsible for the repeatable pack builder and pack publishing work.
- Nova Scotia, New Brunswick, Prince Edward Island, Newfoundland and Labrador, and Quebec are all V3 regions and must remain available.
- Live routing is complete only when deployed and a live request reports `serviceBuild == HEAD`.
- Use Wrangler for any deliberate pack publish. There is no pack publish in the current scope.
- **Never create or clone a simulator.** Use only the existing iPhone 17 simulator:
  - Name: `iPhone 17`
  - ID: `CC6035EE-9C03-48A2-ACBA-DDE3B068642A`
  - Disable parallel testing with `-parallel-testing-enabled NO`.
  - Prefer `-only-testing:DirtTests` unless a specific UI test is genuinely required.

## Release state at handoff

- The user reports that version 2 build 5 has been uploaded to Apple App Store Connect.
- Archive created locally at `build/Dirt-2-5.xcarchive`.
- Current production routing deployment:
  - URL: `https://dirt-mayday.vercel.app`
  - Vercel deployment: `dpl_FyHbdNxhFP21p2CUCZnNpexaN8vz`
  - Verified live `serviceBuild`: `7a7b23e7f002109dd4b3730f8f4329a2afda90fe`
  - Contract: `dirt-routing.r0.v1`
- Verification already completed at this commit:
  - iOS unit tests: 185 passed, 0 failed.
  - JavaScript tests: 195 total, 194 passed, 0 failed, 1 intentionally skipped.
  - All 18 live routing-oracle requests completed. Its stored expected-value file predates the accepted routing/fuel improvements and therefore reports value drift; do not treat that stale comparison as a new navigation-performance failure.
- The public pack manifest contains graph V3, geometry, and fuel for `ns`, `nb`, `pe`, `nl`, and `qc`. Do not alter it in this pass.
- Known unrelated legacy check: the whole-Canada pack assertion reports a BC V2 local/R2 byte mismatch. It is not part of this Atlantic Build 6 performance repair.

## User-verified success in build 5

- Route construction is working.
- Starting navigation ultimately works.
- The first spoken navigation cue was accurate for distance, turn location, and direction.
- Ending navigation and returning to route planning works.
- The remaining problem is that preparation feels slow and clunky.

## New field report and evidence

Primary log: `/Users/richardsmith/Downloads/dirt-app-debug-2026-08-26T145601Z.txt`

The tested route contained 3,413 geometry points and used an already-installed Nova Scotia V3 routing pack.

### Problem 1 — first tile preparation is very slow

Log evidence:

- `14:54:00` — navigation map preparation began.
- `14:54:05` — 341 tiles planned; 186 cached and 155 missing.
- `14:55:05` — preparation became ready after 65,095 ms.
- Only 333 of 341 tiles were cached at completion, so eight requests failed during the first pass.
- The next attempt fetched the remaining eight tiles.

This was not a 500 Mbps Wi-Fi bandwidth problem. The current implementation makes many individual public Shortbread requests with six concurrent tasks:

- `Dirt/Map/CorridorTilePlanner.swift` points at `https://vector.openstreetmap.org/shortbread_v1/...`.
- `Dirt/Map/OfflineTileManager.swift` downloads each tile separately through `URLSession.shared`.
- It has no per-request timing/status diagnostics and no bounded retry inside a preparation pass.
- A direct cold-cache request during diagnosis returned successfully in about 0.4 seconds, but the device's 155-request batch took about 60 seconds. This is latency/provider behavior, not useful bandwidth saturation.

Do not try to solve this by aggressively increasing concurrency against the public OpenStreetMap service. Self-hosted Shortbread on Cloudflare R2 is the agreed long-term source.

### Problem 2 — repeat Start Navigation wastes 5–6 seconds with everything cached

Log evidence:

- Second start: map preparation completed in 6,436 ms with only eight tiles missing.
- Third start: all 341 tiles were cached, but readiness still took 5,511 ms.
- Every attempt spent roughly 5.3–5.4 seconds in `navigation routing pack prep`, even though Nova Scotia was installed and already active.

Confirmed mechanism:

1. `GraphPackStore.prepareForNavigation` calls `regionIds(containingAny:)` across all 3,413 route coordinates.
2. Each coordinate can invoke administrative polygon ownership checks.
3. `ensureActivePackAsync(for:)` then derives the preferred region from the entire coordinate array again.
4. The same full route/province analysis is therefore repeated twice on every Start tap.

Relevant code:

- `Dirt/Routing/OnDevice/GraphPackStore.swift` — `prepareForNavigation`, `ensureActivePackAsync`, `regionIds(containingAny:)`, and `primaryRegionId(containing:)`.
- `Dirt/Routing/OnDevice/RegionPolygons.swift` — polygon ownership checks.
- `Dirt/Features/RoutePlanning/RoutePlannerModel.swift` — `startNavigation()` passes all route geometry to both preparation systems.

This repeat-start pause is an app-side performance defect and is independent of the tile provider.

## Build 6 scope and ordered plan

### 1. Remove redundant routing-pack preparation work

Goal: if the route requirements are unchanged and the required verified pack is installed/active, reuse that result immediately.

Requirements:

- Determine required route regions once, not twice per Start.
- Cache/reuse the result for the unchanged route geometry.
- Preserve correct multi-province detection; do not replace polygon ownership with a loose whole-bounding-box answer that installs unrelated provinces.
- Keep pack revision protection during navigation.
- Add focused tests for same-route reuse and cross-province requirements.

Proof metric:

- On a fully cached repeat start, `navigation routing pack prep` should be under 250 ms.
- Total cached map preparation should be under one second before MapLibre style application.

### 2. Correct the blocking tile scope and failure handling

The agreed product policy is:

- Navigation is gated on the first fuel leg plus a practical buffer, not a bulk download of the entire route.
- Retain downloaded layers across rides until the rider explicitly deletes them.
- During navigation, continue downloading one fuel leg ahead while data is available.
- Do not offer or silently perform a whole-route bulk download.
- If there is no fuel stop in the first rider leg, that stage is the first download unit.

The current `startNavigation()` passes `allCoordinates`, so verify and correct this before optimizing request mechanics.

Add useful diagnostics without logging sensitive data:

- requested, succeeded, failed, retried;
- response status category;
- total preparation duration;
- cache-only fast path duration.

Use a small bounded retry for transient failures. Do not conceal a materially incomplete first-leg corridor as fully offline-ready.

Proof metrics:

- The planned blocking tile set corresponds only to the first navigation/fuel stage plus buffer.
- Transient failures are retried and visible in the diagnostic log.
- A fully cached repeat start remains under one second.

### 3. Physical verification and Build 6

After automated tests:

1. Run only on the existing iPhone 17 simulator if simulator verification is needed; no clones.
2. Build/install on the user's physical device or provide the next TestFlight build.
3. Test a cold first start, a warm second start, End Navigation followed by Start Navigation, one-fuel-stop routing, and a multi-province planned route.
4. Confirm navigation audio remains correct.
5. Increment the build number from 5 to 6 only when the repair is ready to upload.
6. Do not deploy the live routing service unless server code changes. If it does change, deploy and prove `serviceBuild == HEAD`.

## R2 Shortbread preparation — begin after the immediate Build 6 repair is green

Decision already made: use self-hosted Shortbread vector tiles on Cloudflare R2 rather than relying on the public OpenStreetMap tile endpoint for production offline use.

Domain note for the future R2 setup: the user already owns `dirtmoto.app`. Plan to serve the tile origin from an appropriate subdomain of that domain (for example, `tiles.dirtmoto.app`) once the required DNS records and Cloudflare/R2 custom-domain binding are deliberately configured. The exact subdomain is not yet a production decision, and no DNS change is part of Build 6.

Prepare, but keep migration reversible:

- Document the Shortbread generation/import pipeline, object naming, metadata, content type, compression, cache headers, and versioning.
- Put the basemap tile origin behind configuration rather than another hard-coded URL.
- Define development/public-provider fallback separately from production R2.
- Preserve the existing z/x/y disk-cache identity or explicitly migrate it without forcing unnecessary redownloads.
- Add an R2 health check and a rollback switch before changing the production source.
- Estimate storage, request volume, and egress from measured TestFlight usage before publishing a national dataset.

Do not repoint TestFlight to R2 until the objects, headers, cache behavior, attribution, and fallback have been verified.

## Worktree caution

At handoff, these existing documents are untracked and belong to the user/Cursor. Preserve them:

- `docs/AUDIT-2026-08-24.md`
- `docs/CLEANUP.md`
- `docs/ROUTING-RESEARCH-2026-08-25.md`

This handoff document is also initially untracked. Do not stage or commit unrelated files with it.

## First response in the new chat

Read this document, inspect the exact code paths named above, and briefly confirm:

1. the two delays and their mechanisms;
2. the first minimal code change;
3. the regression tests that will protect cross-province packs and navigation audio;
4. that only the existing iPhone 17 simulator will be used and parallel testing will remain disabled.

Then proceed with the Build 6 performance repair. Do not restart routing research, cleanup, or map-pack rebuilding.
