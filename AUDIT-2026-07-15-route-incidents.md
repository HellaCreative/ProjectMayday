# Audit — Route Incident Recovery (2026-07-15)

Implementation of `ROUTE-INCIDENT-RECOVERY.md`. Focused feature only. The NSTDB
graph, existing route profiles, route colors, navigation cue geometry, POI
behavior, and base-map styling were not modified except where strictly required
by this feature (a single additive `routeId` passthrough on the client route
mapper, and additive server avoidance).

## Product rules honored

- **Never silently reroute** — a report never changes the route. A recovery
  route is only computed when the rider explicitly picks a recovery action, is
  previewed, and requires explicit confirmation before it replaces the active
  route.
- **Never create a free-space connector** — recovery routes come from the
  existing server routing graph (`/api/route`) or from existing route geometry
  (Backtrack). No connectors are synthesized.
- **Never draw a straight-line escape through unmapped land** — Backtrack is a
  reversed slice of the existing route polyline; "Find a way around" / "Return
  to network" are full graph routes or a clear failure (no fallback line).
- **Never permanently modify authoritative NSTDB from a rider report** — reports
  live in a separate IndexedDB store and a separate map layer. The graph is
  untouched. Server avoidance is per-request only (`options.avoidEdgeIds`); it
  never mutates the graph.
- **Always show what changed; require confirmation** — the replacement is drawn
  as a preview (dashed) with the reported section highlighted, labeled with the
  rejoin distance, and only applied on "Apply route".

## Files changed

- `routing/lib/router.js` — added optional, server-enforced `options.avoidEdgeIds`.
  Excluded edges are removed from both snap-matching (`matchPoint`) and graph
  traversal (`findPath` neighbors). Reported in `debug.avoidedEdgeIds` and an
  `avoided_edges` warning. No change to profiles, costs, access policy, or
  geometry for requests that do not pass `avoidEdgeIds`.
- `routing/test/run-fixtures.js` — added two focused tests:
  - `avoidEdgeIds excludes a reported edge server-side` (alternate never uses
    the avoided edge, or a clean failure with no geometry).
  - `avoidEdgeIds is a no-op when the edge is off-route`.
- `app/index.html` — the entire client feature (HUD Report affordance, report
  sheet, recovery sheet, confirmation/preview sheet, report map layer,
  IndexedDB persistence + adapter boundary, and the four recovery actions).
  Plus one additive line in each route mapper to carry `api.routeId` onto the
  active route object.

No other files were modified. No build guides were regenerated or revised.

## API and schema changes

### Route API — `POST /api/route`

New optional field only:

```jsonc
{
  "options": {
    "avoidEdgeIds": ["ns-gov-...", "..."]   // optional; default [] → no change
  }
}
```

- Enforced **server-side**: the browser never filters a returned route. Avoided
  edge IDs are removed from candidate snapping and from A* traversal.
- Response additions when `avoidEdgeIds` is non-empty:
  - `debug.avoidedEdgeIds: string[]`
  - `warnings[]` includes `{ code: "avoided_edges", avoidedEdgeIds, containedAvoidedEdge }`
- Backward compatible: requests without `avoidEdgeIds` are byte-for-byte
  unchanged in behavior. `debug.avoidedEdgeIds` is `[]` in that case.

### Report model (client, normalized)

```js
{
  id, category, lat, lon, routeId, stageId, edgeId, direction,
  status: "unverified",          // unverified | confirmed | dismissed | expired
  confidence: "unverified",
  confirmations: 0,
  locationSource,                // "gps" | "map_on_route"
  createdAt, expiresAt,
  source: "rider_report",
  note: null
}
```

- Categories: `access_closed`, `gate_seasonal`, `flooded`, `blocked`, `unsafe`,
  `other`.
- Statuses supported: `unverified`, `confirmed`, `dismissed`, `expired`.

## Persistence status

- **Repository / Vercel inspection:** no durable shared datastore exists. Vercel
  functions here are stateless (`api/route.js`, `api/overpass.js`,
  `api/ns-trails.js`); only static assets and the routing graph ship. `vercel.json`
  defines no storage. The project already uses IndexedDB (Dexie) for tile chunks
  and saved routes.
- **Implemented:** local IndexedDB store `dirt_reports_v1` (Dexie), behind a
  `ReportPersistence` adapter boundary with a `remoteSync()` method that returns
  `{ ok: false, blocked: true }`.
- **Shared persistence: BLOCKED** by missing durable storage. The UI never
  claims reports are shared between riders. No in-memory Vercel function
  variable is used for reports. No client-side secrets were added.
- Local reports work for the current rider's route session (and persist on the
  device across reloads via IndexedDB). A memory fallback is used only if
  IndexedDB is unavailable.

## Freshness model (documented default)

- **Default freshness for `unverified` reports: 72 hours** (`REPORT_FRESHNESS_HOURS`).
  Chosen to match a multi-day ride-planning horizon while ensuring temporary
  conditions do not become permanent truth.
- On load, any `unverified` report past `expiresAt` is transitioned to `expired`
  (persisted) and rendered dimmed. Reports shown to riders always include age
  and status.

## Routing / recovery behavior

- **Report affordance (item 1):** compact `Report` button added to the existing
  nav HUD; visible only while navigating. Opens a touch-first sheet with the six
  categories — no typing required. All report/recovery controls stop event
  propagation (pointerdown/mousedown/touchstart/click) so they never place route
  points or trigger POI/map clicks. Location is captured from GPS, or from the
  current map position only when it is already on the active route (≤150 m),
  otherwise the report is refused — a location is never invented.
- **Recovery actions (item 3):** offered only after submit; the report is applied
  to the current route only if the rider chooses a recovery action.
- **Find a way around (item 4):** routes from the rider's current matched
  position to the preserved destination, preserving profile and access policy,
  passing `options.avoidEdgeIds = [reported edge]`. Server-enforced. Full
  verified route or the exact failure copy:

  ```
  No verified alternate route found.
  Backtrack to the last verified junction or end this stage.
  ```

  No fallback line is drawn.
- **Backtrack (item 5):** reversed slice of the existing route geometry back to
  the last segment/junction boundary. No straight line, no proximity stitch,
  no unmapped land. Previewed before applying.
- **Return to nearest verified network (item 6):** graph route from the rider to
  the nearest reachable verified point on the original route downstream of the
  report (avoiding the reported edge). Clear failure if none — never an arbitrary
  connector.
- **Rejoining (item 7):** the original route is preserved until confirmation.
  Downstream rejoin is detected via shared authoritative **edge identity** (not
  geometry proximity): the first detour edge that re-uses an original edge past
  the report is the rejoin point, labeled e.g. *"Reported closure avoided.
  Rejoins original route in 4.2 km."* When a reliable shared-edge rejoin cannot
  be found, the UI does not fake it — it offers the alternate as a full
  replacement and states *"Automatic rejoining is not available yet."*
- **Report map layer (item 8):** separate `reportMarkers` source/layers, not part
  of the road/trail or Rider Services legend. Shown only when zoomed in
  (≥ z13), near the active route corridor (≤300 m), or when the rider explicitly
  enables visibility (toggle button). Only local session reports are used — no
  province-wide preload. Category colors per spec (access=red, gate=amber,
  flooded=blue, blocked=orange, unsafe=yellow). Popup shows category, status,
  age, whether it affects the current route, and confirmation count.
- **Interaction safety (item 10):** report controls place no route points; POI
  markers still open popups (report hit-test runs before POI/route handling and
  POI logic is unchanged); Layers works during navigation; the HUD, active turn
  instruction, and End control remain usable; sheets respect safe-area insets.

## Exact test results

### Server unit/fixture tests (local, real graph — 300,582 edges)

`node routing/test/run-fixtures.js` → **12/12 PASS**, including:

- `avoidEdgeIds excludes a reported edge server-side` — PASS
- `avoidEdgeIds is a no-op when the edge is off-route` — PASS

`node routing/test/stages.test.js` → 21/21 PASS (unchanged).
`node routing/test/roadbook-curves.test.js` → 13/13 PASS (unchanged).

### Live Vercel production verification (real routing, known-good fixture)

Fixture: Porter's Lake `(44.7427, -63.2985)` → Musquodoboit Harbour
`(44.787, -63.148)`, profile `balanced`. Not ocean coordinates.

- Baseline route: `status=complete`, `distanceMeters=20288`, 78 segments,
  mid-route edge `ns-gov-8fd6016b8375`.
- With `options.avoidEdgeIds=["ns-gov-8fd6016b8375"]`:
  - `status=complete`, `distanceMeters=19180` (a genuinely different path)
  - avoided edge **absent** from the returned segments (confirmed programmatically)
  - `debug.avoidedEdgeIds=["ns-gov-8fd6016b8375"]`
  - `warnings[]` contains `avoided_edges`
- Non-existent avoid id → complete route, `debug.avoidedEdgeIds` echoes the id
  (proves the parameter is honored, not silently dropped).
- `GET /api/route` → `200 { ok: true, service: "dirt-route" }`.

This confirms **item 6 of §11 (“the reported section is excluded server-side”)**
against a real deployed route — not a CSS or injected-state simulation.

### Browser verification (live production UI)

**Not interactively verified.** An interactive browser click-through
(start navigation → open Report → submit → Find a way around → confirm) was
attempted via the Cursor browser MCP against production but could not be run:
no browser tab was available in this environment (`browser_navigate` returned
"No browser tab available", `browser_tabs list` returned no tabs). No headless
Chrome/Playwright is provisioned here either, and per the recovery spec no local
server was stood up.

What was verified without a browser (see below):

- **Server-side avoidance** — verified end-to-end against the live production
  routing API with a real known-good fixture (Porter's Lake → Musquodoboit
  Harbour). This is the one behavior §11 explicitly requires to be enforced
  server-side, and it is confirmed live, not simulated.
- **Client feature presence in production** — the deployed `/app` HTML is
  byte-for-byte identical to the reviewed source (SHA-256
  `c546a577…f39de9d1`, 320,569 bytes) and contains all report/recovery feature
  markup and logic (28 feature markers: report sheet, `data-recovery="around"`,
  `dirt_reports_v1`, `REPORT_FRESHNESS_HOURS`, etc.).
- **Inline client script compiles** — 0 syntax errors (`vm.Script`).

The following §11 steps remain **NOT interactively verified** (require a live
browser session): opening the Report affordance on the running HUD (2–3),
on-screen report metadata (4), the on-screen confirm-before-replace gate (7),
Backtrack UI (8), the no-alternate UI copy (9), absence of any on-screen
straight-line/free-space segment (10), POI popups during nav (11), Layers during
nav (12), and console-error/memory checks (13). Their supporting logic is
present in source and reviewed, but on-screen behavior was not exercised.

## Vercel URLs

- **Production (public):** https://dirt-mayday.vercel.app
  - App: https://dirt-mayday.vercel.app/app
  - Route API: https://dirt-mayday.vercel.app/api/route
- **Production deployment (git-triggered by this commit, Ready):**
  https://dirt-mayday-iaru9qyah-goricksmith-7678s-projects.vercel.app
- **Preview deployment:**
  https://dirt-mayday-ksd7futil-goricksmith-7678s-projects.vercel.app
  (team SSO / deployment protection is enabled on `*-goricksmith-7678s-projects`
  preview URLs, so automated curl verification was run against the public
  production alias instead; the same build serves both.)

## Git / deploy provenance

- Feature commit: `135f0fd` — "Add route incident recovery (report + verified
  detour/backtrack)", pushed to `origin/main`
  (`github.com/HellaCreative/ProjectMayday`), advancing `bc72a4e..135f0fd`.
- The push triggered a git-based Vercel **Production** deployment that reached
  **Ready** (`dirt-mayday-iaru9qyah-…`, 18s build).
- The public alias `dirt-mayday.vercel.app` serves this build: the deployed
  `/app` HTML is SHA-256 `c546a577…f39de9d1`, byte-identical to the committed
  source, and the live `/api/route` re-confirmed server-side avoidance after the
  git deploy (baseline 20,288 m → avoided 19,180 m, avoided edge absent,
  `avoided_edges` warning present).

## Verification evidence

- Server avoidance verified end-to-end against live production routing (see
  results above), using a real known-good fixture.
- Inline client JS syntax validated (`vm.Script` compile of the app script:
  0 errors).
- Local fixture + unit tests all pass with the full 300k-edge graph.

## Known limitations / blocked items

- **Shared persistence is BLOCKED** — no durable server store is configured.
  Reports are local to the device/session (IndexedDB). The remote adapter is a
  stub reporting the block; wiring a durable store (e.g. Vercel Postgres/KV or a
  Blob-backed index) is the follow-up to enable cross-rider sharing.
- **Report verification workflow** — only rider-submitted `unverified` reports
  are created in-app; `confirmed`/`dismissed` transitions and confirmation
  counts are modeled and rendered but not yet driven by a moderation/community
  backend (blocked on the same durable store).
- **Automatic rejoining** — provided when a reliable shared-edge rejoin exists;
  otherwise the recovery route is offered as a full replacement to the
  destination and the UI states rejoining is not available yet (never faked).
- **Multi-stage plan rendering** — the primary verified path is single-stage
  ("From here"). When a replacement is applied during a multi-stage plan, it
  drives navigation guidance and is drawn on a dedicated applied-route layer;
  the per-stage plan list is not rewritten by the recovery.
- **Preview deployments are SSO-protected**, so automated verification used the
  public production alias (same build artifact).
