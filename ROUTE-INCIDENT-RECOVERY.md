# Route Incident Recovery

## Instruction

Implement this feature in `/Users/richardsmith/SandBox01/Mayday`.

This is a focused feature request. Do not modify unrelated functionality. Do not change the NSTDB graph, existing route profiles, route colors, navigation cue geometry, POI behavior, or base-map styling unless a change is strictly required by this feature.

The product problem is simple: a rider may encounter a closure, trespass warning, gate, flooded crossing, or blocked route while navigating. The rider needs a quick way to report it and find a verified way out or around it.

The central rules are:

- Never silently reroute.
- Never create a free-space connector.
- Never draw a straight-line escape through unmapped land.
- Never permanently modify the authoritative NSTDB network from a rider report.
- Always show the rider what changed and require confirmation before applying a replacement route.

## 1. Navigation report affordance

When navigation is active, add a compact `Report` affordance to the existing navigation HUD.

Tapping it opens a simple, touch-friendly report sheet with these choices:

- Access closed / no trespassing
- Gate or seasonal closure
- Flooded or impassable crossing
- Blocked route
- Unsafe condition
- Other

The initial report must not require typing. Optional notes, photos, and voice input are future work.

The report sheet must not place route points. Stop event propagation so its controls do not trigger map clicks, POI clicks, or route-planning clicks.

Capture these fields when available:

```js
{
  id,
  category,
  lat,
  lon,
  routeId,
  stageId,
  edgeId,
  direction,
  status: "unverified",
  confidence: "unverified",
  createdAt,
  expiresAt,
  source: "rider_report",
  note: null
}
```

Use the current GPS position. If GPS is unavailable, use the current map position only when it is already associated with the active route. Never invent a location.

## 2. Report status and community data

Keep rider reports separate from the authoritative road and trail data.

Supported report statuses:

- `unverified`
- `confirmed`
- `dismissed`
- `expired`

Reports shown to riders must include their age and status. Temporary conditions must not become permanent truth.

Use a freshness model. An unverified report should expire unless it is confirmed or renewed. Choose a sensible default based on existing project conventions and document the value in the audit.

## 3. Current-route recovery actions

After submitting a report, offer these actions:

- `Find a way around`
- `Backtrack`
- `Return to nearest verified network`
- `End stage`

The report should be applied immediately to the current route only if the rider chooses a recovery action. It must not automatically alter the route.

## 4. Find a way around

Use the existing route service and routing graph.

If necessary, extend the route request with an optional field:

```js
options: {
  avoidEdgeIds: []
}
```

The server must enforce the avoidance. Do not filter a returned route only in the browser.

For `Find a way around`:

- Start from the rider's current matched network position.
- Preserve the current destination.
- Preserve the active route profile.
- Preserve the current unknown-access policy.
- Avoid the reported edge or affected route segment.
- Return a complete verified network route or a clear failure.
- Show that the reported section was avoided.
- Require confirmation before replacing the active route.

If no alternate route exists, show:

```text
No verified alternate route found.
Backtrack to the last verified junction or end this stage.
```

Do not draw a fallback line.

## 5. Backtrack

`Backtrack` must follow the existing verified route backward to the last valid junction or known route node.

- Use the existing route geometry and graph metadata.
- Do not use a straight line.
- Do not use a proximity stitch.
- Do not route through unmapped land.
- Show the rider the backtrack route before applying it.

## 6. Return to the verified network

If the rider is off the active route or the route is interrupted, find a path to the nearest reachable verified network edge using the routing graph.

If no verified escape route exists, say so clearly. Never create an arbitrary connector to a nearby road.

## 7. Rejoining the original route

Preserve the original route before calculating a recovery route.

When an alternate route is found:

- Identify the next downstream point where the replacement route can rejoin the original route.
- Show where the route rejoins.
- Label the result, for example:

```text
Reported closure avoided. Rejoins original route in 4.2 km.
```

- Do not discard the original route until the rider confirms the replacement.

If reliable downstream rejoining cannot be implemented with the existing graph, do not fake it. Offer the alternate route as a replacement and clearly report that automatic rejoining is not available yet.

## 8. Report map layer

Add a separate report layer. It must not be part of the normal road/trail legend.

Show reports only when:

- The map is zoomed in enough for detail, or
- The report is near the active route corridor, or
- The rider explicitly enables report visibility.

Do not load all reports across Nova Scotia at startup.

Use these visual categories:

- Access closed: red
- Gate or seasonal closure: amber
- Flooded crossing: blue
- Blocked route: orange
- Unsafe condition: yellow

A report popup should show:

- Category
- Status
- Age
- Whether it affects the current route
- Confirmation count, if available

Do not add report markers to the existing road, track, or Rider Services legend.

## 9. Persistence and sharing

Inspect the existing repository and Vercel configuration before adding persistence.

If a durable shared data store already exists, use the established storage pattern.

If no durable store exists:

- Do not use an in-memory Vercel function variable.
- Do not claim reports are shared between users.
- Do not add client-side secrets.
- Implement the normalized report model and local IndexedDB fallback.
- Isolate shared persistence behind a clear API or adapter boundary.
- Report shared persistence as blocked by missing durable storage.

Local reports must still work for the current rider's route session.

## 10. Interaction safety

Preserve all existing interactions:

- Report controls must not place route points.
- POI markers must continue to open their popups.
- POI actions must not trigger route-planning map clicks.
- Layers must continue to work during navigation.
- The navigation HUD, active turn instruction, and End control must remain usable.
- Respect mobile safe-area insets.
- Keep the report interaction compact and usable with a quick glance.

## 11. Verification

Use a known-good existing routing fixture or known-good deployed route. Do not use ocean coordinates or arbitrary points.

Verify on the Vercel preview only:

1. Start a real navigation route.
2. Open the Report affordance.
3. Submit an access-closure report.
4. Confirm the report contains the correct route, stage, location, and edge metadata when available.
5. Choose `Find a way around`.
6. Confirm the reported section is excluded server-side.
7. Confirm the rider must approve the replacement route.
8. Test `Backtrack`.
9. Test a case where no alternate route exists.
10. Confirm no straight-line or free-space segment appears.
11. Confirm POI popups still work.
12. Confirm Layers still works during navigation.
13. Confirm there are no console errors or obvious memory regressions.

Do not claim PASS for behavior that was only simulated with CSS or injected state.

## 12. Completion report

After implementation, create a repository-root Markdown audit file named:

```text
AUDIT-YYYY-MM-DD-route-incidents.md
```

The audit must include:

- Files changed
- API and schema changes
- Persistence status
- Routing behavior
- Exact test results
- Vercel production and preview URLs
- Verification evidence
- Known limitations
- Any behavior that remains blocked

Do not modify unrelated files. Do not regenerate or revise other build guides as part of this task.
