# DIRT design exploration

HTML comparison requested by Richard. Three unapproved directions; no native implementation or routing deployment. Map backdrop is the user-supplied screenshot, cropped by CSS; data in the controls is illustrative.

Groups elevates rider roster above inviting and places local sharing on own row. Native implementation must preserve location permission/waiting states and make clear that sharing is account-wide if that is the current behavior, not silently imply a per-group scope.

Routing evidence: fuel-10adc497 (4.674 seconds) and fuel-ff9ae141 (1.472 seconds) used backend 4e0fc370 and adventure-preview-v1, selected dirt-30. Both have one waypoint hop and no pump hop. Second request followed ridePreferences rebuild. Log lacks preference values, contiguous dirt-run lengths and competing-route costs. Cannot prove lengths or whether a short section is necessary from this evidence. Proposed rule: do not reward optional paved-to-dirt-to-paved excursions shorter than 1 km; preserve essential connectors and required waypoint/fuel access. Apply to contiguous runs, not individual graph edges; compare usable paved alternatives before rejecting. Reproduce both original and snapped endpoint cases and add diagnostics before deployment.

## Approved direction and expanded preview
Richard selected Open Terrain for Groups and Loop. open-terrain.html extends it to From Here, Plan, Saved, Navigation, Layers, Packs, Profile and ride preferences. All states are illustrative. Direction and surface are matching custom disclosures rather than default browser select controls. Existing wordmark font size and map-chip height are retained. Native navigation behavior is frozen; its screen is a concept only.

Badge decision: DEV in development; PRO for active subscription in production, FREE otherwise. Only the native badge has been implemented at this stage. Signed generic-iPhone build and eight DEV isolation checks passed. No simulator, device installation or production publication.
