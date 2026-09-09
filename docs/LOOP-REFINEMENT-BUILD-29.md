# Build 29 — focused loop refinement

Scope: loop candidate construction/selection, waypoint drag and explicit added-waypoint confirmation, and the requested Layers/tab refinements. No live service deployment or pack change.

## Evidence

User log: dirt-app-debug-2026-09-09T205926Z.txt, build 28, starting coordinate 44.76484,-63.34022. Original requested distance is not logged; replay probes used 300 km, Northwest, Dirt, 306 km usable fuel. Three pin-pan beginnings followed by cancelled state 4 establish the interrupted drag symptom. Removed drag-begin marker refresh and prevented competing recognizers from cancelling eligible selected-pin pans. Physical gesture acceptance remains pending.

Production LoopPlan code ran directly through five regression methods: compass/closure, six candidate arrangements, reverse-road detection, distance scaling, and folded-circuit rejection. Added an app-model regression for draft→No→drag→Yes with zero route requests before Yes. Device test target compilation verifies that test; it was not executed on a simulator or phone.

Read-only live DEV probes used serial two-point fuel requests and the app’s 30 km/256-edge recent-history policy. They are service/geometry probes, not an execution of the complete native ItineraryBuilder. Initial uncalibrated 300 km candidates produced overly long routes. A full-history experiment caused continuation failures and was removed. Stable calibration plus Clean return legs produced a complete approximately 280 km circuit with approximately 41 km shared roads and 0.46 area fill; this passes the new gates but is not overlap-free. Other folded candidates were rejected. Native distance calibration and fuel handling still require White acceptance.

Broader preliminary probes: NS north returned highly overlapping circuits; NB southwest failed a continuation; PEI and Newfoundland rejected custom ride settings as unavailable. These are unresolved coverage limitations, not passes. Do not freeze or claim Atlantic-wide loop qualification from this build.

## Device review

Create Northwest loop from the reported area; judge whether its remaining shared access is acceptable. Add a pin on a leg, choose No, drag, choose Yes; route building must start only after Yes. Check existing waypoint drag, Layers X/toggle, and active route tabs. Existing fuel replacement remains frozen.
