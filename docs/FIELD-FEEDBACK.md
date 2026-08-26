# DIRT — Field / Tester Feedback (unconfirmed — for investigation)

Raw tester feedback, 2026-08-24. **Not yet confirmed** — tester was riding a moving object
during active development, so treat glitchy reports with a grain of salt until reproduced.
Navigation/turn-by-turn items are evidence against
[00-NAVIGATION-SOURCE-OF-TRUTH.md](00-NAVIGATION-SOURCE-OF-TRUTH.md).
UI-only items live in `CLEANUP.md`.

## Routing / planning
- [ ] **Waypoints don't lock when planning — the destination keeps moving.** Sounds like a
      glitch (dragging/re-snapping the destination). INVESTIGATE / try to reproduce on a
      stationary device. Possibly noise from testing mid-development.
- [ ] **Edit route midway — VERIFY the existing functionality works.** Rick believes this is
      already handled: press-and-hold on the route creates a new waypoint, then tap that
      waypoint to drag it anywhere. Confirm it's present and working; the tester may not have
      discovered it.
- [ ] **Re-routing after "impassable" routes BACKWARD (IMPORTANT — field-tested).** Current
      flow: rider hits an impassable/uncomfortable spot on the planned route → gives a reason
      → offered backtrack or re-route. Bug: re-routing a few times sends the route **behind**
      the rider, not toward the next waypoint.
      **Fix approach (use the existing route-builder obstacle rules):** treat the rider's
      current impassable location like any other obstacle (river/lake) — keep heading toward
      the **gravity of the next waypoint**, and go around the obstacle by the **lesser of the
      two distances**, never backward.

## Features (ideas)
- [ ] **Save waypoints / saved starting locations.** Let the rider save a set of frequently
      used start points. (Nice-to-have; scope later.)

## Responsive / layout
- [ ] **Landscape routing mode — the menu doesn't fit.** Responsive issue when the phone is
      turned sideways. Consider running the `impeccable` skill to analyze the landscape layout.
