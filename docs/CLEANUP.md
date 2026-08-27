# DIRT — Cleanup Tracker

Non-functional cleanups: remove temporary/testing scaffolding, tidy the interface, delete
dead code. Batch these when convenient; none are routing-behavior changes. Keep the city
tester (Rick uses it).

## Interface / UI
- [ ] Remove the **"NS · no pack" badge** (E3 test badge; not for production).
- [ ] Debug graph overlay serves **coarse only** for live users — either serve leaves from
      the live `debug_graph` endpoint or hide the leaf modes when no local pack. (audit P2-4)
- [ ] Debounce the `debug graph live failed … cancelled` refetch spam on map pan.
- [ ] General interface pass (Rick to enumerate: spacing, labels, control placement).
- [ ] **Move GRAPH onto the DIRT logo (NOT the Layers sheet).** Remove the standalone GRAPH
      map button from the routing screen. Tapping the **DIRT logo** toggles the graph on/off
      (same behavior the GRAPH button has now). When on, the legend interface **animates down
      and out from under the DIRT logo**, building downward then to the right, **left-justified**.
      Tapping DIRT again turns the graph off and closes the legend.
- [ ] **Compass ↔ re-center spacing.** The compass and re-center buttons (right side) are
      touching vertically. Give them the same vertical gap between them as the horizontal
      gap used between the icons elsewhere.
- [ ] **Remove the PACKS button from the routing map** → move that affordance into the
      Layers sheet. (Cleans up the routing interface.)

### Pack management model (NOTE: partly a FEATURE, tied to cross-province horizon — not pure cleanup)
New model (replaces manual pack downloads):
- Packs **auto-download when a route is created**, for every region the route crosses
  (NS→NB downloads both; NS→BC downloads all regions along the way).
- **No manual pack download** anymore (remove that old functionality).
- The user can **delete** downloaded packs (they're small), or keep them.
- Downloaded packs are **surfaced/managed in the Profile section** ("we let them know where
  that pack exists in profiles").
The auto-download + delete + profile-management is FUNCTIONAL work that belongs with the
cross-province/state stitching + pack-rebuild horizon — not the last cleanup pass. Only the
"remove PACKS button from routing map" piece is cleanup.

### Map style + route line (visual)
- [ ] **Roads too faint on both Normal and Rich styles** — darken / add contrast so roads
      are more visible on the basemap.
- [ ] **Route plotline covers road names.** Add transparency to the plotline and/or thin it
      so the underlying road labels stay readable. (approach TBD)
- [ ] **Color the route line by surface using the Legend colors** — the plotted route should
      use the same surface colors as the graph legend (paved/gravel/dirt/etc.) along its length.

### Layers sheet
- [ ] **Remove "Network lens" entirely** — all of its functionality AND its explanatory
      text. No longer needed; that capability now lives in the graph function on the DIRT
      logo (see GRAPH-on-DIRT item above).

### Saved / GPX import sheet — REQUIRES WORK (image to come)
- [ ] After importing a GPX via **Saved**, the detail interface shows the GPX with
      affordances: **Export GPX, Start (navigation), Continue Planning, Clear Route.**
- [ ] Below that, a drawer opens with **"All Saved Routes."** Problem: you've just imported a
      GPX *and* it's also showing the full Saved Routes list — too much cognitive load.
      **Remove "Saved Routes" from that action area** (right after a GPX import).
- [ ] The whole **Saved sheet needs a fuller pass** — Rick to provide an image + more detail.

### Fuel Plan Legs panel (device test 2026-08-24)
Per-row tightening (each leg row is too tall from duplicated labels + stacked BR text):
- [ ] **Remove the duplicated leg label.** Each leg shows its "Fx → Point/Fx" line TWICE
      (e.g. row 4 shows "F3 → Point 2" twice; row 3 shows "F2 → F3" twice). Keep one.
- [ ] **Inline "before reserve" to the right of the dirt%.** "126 km before reserve" →
      "126 km BR", placed to the RIGHT of "51% dirt" on the same line (not a stacked line
      below). Same for "8 km before reserve" → "8 km BR" right of "91% dirt".
- [ ] **Gas-station name inline, to the right of the leg.** On a fuel leg (e.g. row 3 "Esso"),
      the station name currently sits UNDERNEATH the leg label — move it to the RIGHT of the
      leg header (right of "F2 → F3"), next to the pump icon.

Panel structure (grouping + clear-route):
- [ ] **"Fuel plan legs" should be a GROUP container, not a bare heading row.** The heading
      should WRAP the leg list; the legs scroll WITHIN that group so it reads as one grouped
      unit.
- [ ] **Move the leg list into where "Clear route" currently sits** (the area with the trash
      icon), so the list is wrapped by the Fuel-Plan-Legs grouping.
- [ ] **Remove global "Clear route" while Fuel Plan Legs is OPEN.** In the open state the
      rider clears individual legs (per-leg clear). Global "Clear route" belongs only to the
      CLOSED/collapsed state of the Fuel Plan panel.

## Temporary testing scaffolding (comment out or remove)
- [ ] Any hardcoded test pins / debug dumps left in the routing or app code.
- [ ] **Budgets / caps used only for testing** (Rick to specify which — e.g. debug pop caps,
      temporary corridor/time budgets, forced fuel range). List each with its real value.
- [ ] `publish-packs-cdn.js` legacy aws-s3 path — either wire it to fail-loud or remove it so
      it can't be mistaken for the real (wrangler) publish path. (avoid future confusion)

## Code smells from the audit (safe, low-priority)
- [ ] `router.js:850` defaults missing access to `motorized_permissive` — should be
      `motorized_unknown` (display/stats only). (audit P2-6)
- [ ] `ferry.js` `parseOsmDuration` 10–180 boundary is ad hoc — require explicit HH:MM/unit.
      (audit P1-4)
- [ ] `METRO_CORE_WALL` hardcoded static metro boxes — move to pack-derived urban cores
      (flagged "temporary" in OnDeviceRouter.swift:131). (audit P2-5)

## Notes
- Not cleanup, tracked elsewhere: Dirt/Balanced leaf migration, fuel comfort window,
  route-distance regression tests — those are functional and belong in the main work plan.
