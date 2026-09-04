# GPX import → DIRT route plan

**Status:** post-launch product/engineering plan. Current import remains a
faithful traced GPX display and local save. This document does not reopen the
frozen routing release candidate.

This is one iOS/Android product contract. Platform presentation may be native,
but neither platform is complete until both implement the same import
preservation, entry/direction choice, graph alignment, fuel, warning, and
recovery behaviour with equivalent evidence.

## Rider job

A GPX track is evidence of a ride line, not necessarily a navigable itinerary.
The rider should be able to import it, reach it from their current position,
choose the direction when it is a loop, and turn it into a route that uses
DIRT's current graph while preserving the intent of the original track.

The smallest successful flow is:

1. Import and preview the original line unchanged.
2. DIRT identifies whether it is open or loop-like and finds safe nearby entry
   candidates from the rider's position.
3. The rider chooses **Ride clockwise**, **Ride counter-clockwise**, or, for an
   open track, **Start near this end**.
4. DIRT builds a short connector to the chosen entry, then rebuilds the GPX in
   bounded windows constrained to a corridor around the source line.
5. The result is shown as a new editable DIRT route. The original import stays
   available for comparison and recovery.

## Product laws

- Never silently replace or overwrite the imported GPX.
- “Closest point” means closest **reachable graph position**, not merely the
  nearest latitude/longitude vertex.
- A loop has no privileged first file point. Direction and entry are explicit.
- Preserve source geometry through ferries, disconnected islands, and sections
  that cannot be matched; do not draw a fake straight connector.
- Unknown/private-access policy is explicit and uses the same per-leg rules as
  native DIRT planning.
- A rebuild must report corridor departures, unmatched sections, and changed
  distance before the rider saves it.
- Fuel planning runs only after the corridor route is complete, using the same
  frozen native fuel contract.

## Geometry pipeline

1. Parse `<trkseg>` and `<rte>` separately and retain segment boundaries.
2. Remove only exact/near-exact duplicate samples; keep shape-defining points.
3. Classify a track as loop-like when its reachable first/last anchors are
   within a bounded threshold relative to total length.
4. Map-match samples to the eligible graph with monotonic progress along the
   GPX. Keep multiple hypotheses around crossings instead of choosing a global
   nearest road independently for each point.
5. Partition into bounded route windows with overlap. Each window carries a
   forward corridor and previous arrival edge so it cannot shortcut across a
   loop or reverse through a self-crossing.
6. Score candidates by source-line deviation first, then ride profile, access,
   backtracking, settlement avoidance, and route quality.
7. Stitch windows, validate continuity, and compare the finished route against
   the source: max cross-track distance, unmatched metres, reversals, and
   percentage within corridor.

## Safe defaults

- Preview first; no automatic network-heavy conversion on file open.
- Suggest the reachable entry with the shortest connector, while showing the
  other direction/entry choice.
- Use a tight initial corridor and widen only the failed window, never the
  entire track.
- For a closed loop, finish at the chosen entry. The rider's live connector is
  a separate first/last stage and is not baked into the loop geometry.
- Keep the source GPX visible as a thin reference line until the rider accepts
  the converted route.

## Failure and recovery

| Condition | Rider-facing result |
| --- | --- |
| No reachable entry | Show the original trace; offer manual entry pin or retry with a wider connector search. |
| One unmatched section | Preserve the source trace for that section and label it “not verified on DIRT roads.” |
| Access rule blocks conversion | Identify the exact section; offer a per-leg Allow unknown decision, not a route-wide switch. |
| Ferry/water discontinuity | Keep segment boundary and show a crossing notice; never bridge it with a straight road line. |
| Long conversion times out | Keep completed windows, retry only the failed window, and preserve direction/entry choice. |
| Converted route drifts too far | Refuse silent acceptance and show the original versus proposed line. |

## Delivery phases

### Phase 1 — deterministic import intelligence

- Add loop/open classification and source-segment identity.
- Add reachable entry-candidate analysis without changing the track.
- Add direction and entry choice UI.
- Persist original GPX identity alongside the local saved trace.

### Phase 2 — corridor conversion

- Add the bounded monotonic map-matching/window contract to both live and
  on-device routing implementations.
- Add fixtures for loops, self-crossings, ferries, disconnected segments,
  sparse tracks, and tracks outside available packs.
- Produce a comparison report before replacing the preview.

### Phase 3 — DIRT itinerary handoff

- Convert accepted windows to normal rider legs.
- Apply per-leg profile and Allow unknown settings.
- Run standard fuel planning after conversion.
- Export/save as a new DIRT route while retaining the original import.

## Acceptance evidence

- Open and closed GPX files produce the same classification every run.
- Clockwise/counter-clockwise never changes the source loop shape except for
  graph alignment.
- Self-crossings cannot jump to a later arm.
- Every stitched leg is graph-connected or explicitly marked unmatched.
- No converted section exceeds the agreed corridor without rider confirmation.
- Cancel/retry preserves the imported trace and completed work.
- VoiceOver, Dynamic Type, offline, large-file, and low-memory behavior are
  exercised on the Release candidate.
