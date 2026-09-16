# DIRT — Cleanup Tracker

Historical interface cleanup candidates. Verify that an item still applies and
that the current task authorizes it before changing the approved interface.
Routing, fuel, pack acquisition, search limits, and functional fixes are defined
only in [the routing source of truth](ROUTING-SOURCE-OF-TRUTH.md).

## Interface / UI
- [ ] Remove the **"NS · no pack" badge** (E3 test badge; not for production).
- [ ] Debug graph overlay serves **coarse only** for live users — either serve leaves from
      the live `debug_graph` endpoint or hide the leaf modes when no local pack. (audit P2-4)
- [ ] Debounce the `debug graph live failed … cancelled` refetch spam on map pan.
- [ ] General interface pass (Rick to enumerate: spacing, labels, control placement).
- [x] **Move GRAPH onto the DIRT logo (NOT the Layers sheet).** Remove the standalone GRAPH
      map button from the routing screen. Tapping the **DIRT logo** toggles nearby surfaces.
      DEBUG builds still show the GRAPH HUD from under the logo. Release uses the lighter
      pack-network corridor overlay instead of `RoutingGraphDebugManager`.
- [ ] **Compass ↔ re-center spacing.** The compass and re-center buttons (right side) are
      touching vertically. Give them the same vertical gap between them as the horizontal
      gap used between the icons elsewhere.
- [ ] **Remove the PACKS button from the routing map** → move that affordance into the
      Layers sheet. (Cleans up the routing interface.)

### Map style + route line (visual)
- [ ] **Roads too faint on both Normal and Rich styles** — darken / add contrast so roads
      are more visible on the basemap.
- [ ] **Route plotline covers road names.** Add transparency to the plotline and/or thin it
      so the underlying road labels stay readable. (approach TBD)
- [ ] **Color the route line by surface using the Legend colors** — the plotted route should
      use the same surface colors as the graph legend (paved/gravel/dirt/etc.) along its length.

### Layers sheet
- [x] **Remove "Network lens" entirely** — prefs are cleared on launch and no longer read.
      Nearby surfaces live on the DIRT logo (corridor overlay / DEBUG graph).

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

## Temporary interface scaffolding

- [ ] Review temporary non-routing interface placeholders against the current
      approved design before removing them.

Routing test fixtures, diagnostic controls, runtime limits, and pack tools are not
interface cleanup. Their work and acceptance are defined only in [the routing source of truth](ROUTING-SOURCE-OF-TRUTH.md).
