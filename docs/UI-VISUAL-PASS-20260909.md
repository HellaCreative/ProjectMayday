# iPhone visual consistency pass — September 9, 2026

## Authority
The rider-approved planner sheet tabs define the visual language: compact icon/title controls, native light glass, and orange selected content. The user explicitly requested deep orange instead of the earlier reddish brown.

## Changes
- Appearance-aware action orange #B85C00 / #FFB35C. Bright #FF7A00 remains the primary-action fill with dark text. Route surface paint remains unchanged.
- Shared sentence-case semibold buttons, quiet section labels and wrapping headers with separate back/close targets.
- Neutral installed-pack cards with Update/Delete below their details.
- Glass Profile subscription card and secondary Manage action; Group Join follows the same secondary style and Create/Join stack for accessibility sizes.
- Ride preference grouping and visible wander percentage; consistent action colors across Layers, route details and Profile. Orange onboarding actions use dark foregrounds.

## Verification
Impeccable mechanical detector returned no findings for the changed Swift sources; this does not establish native rendering quality. That visual pass preserved existing action closures and behavior. Current routing and fuel requirements are in [ROUTING-SOURCE-OF-TRUTH.md](ROUTING-SOURCE-OF-TRUTH.md). Signed generic-iPhone DIRT Dev build succeeded; all eight development configuration checks passed. Build log: `/tmp/dirt-ui-consistency-build.log`. No simulator launched, no device installation performed. White review is still needed for material compositing, long labels and large text.
