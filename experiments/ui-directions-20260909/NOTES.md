# DIRT design exploration

HTML comparison requested by Richard. Three unapproved directions; no native implementation or routing deployment. Map backdrop is the user-supplied screenshot, cropped by CSS; data in the controls is illustrative.

Groups elevates rider roster above inviting and places local sharing on own row. Native implementation must preserve location permission/waiting states and make clear that sharing is account-wide if that is the current behavior, not silently imply a per-group scope.

Routing evidence: fuel-10adc497 (4.674 seconds) and fuel-ff9ae141 (1.472 seconds) used backend 4e0fc370 and adventure-preview-v1, selected dirt-30. Both have one waypoint hop and no pump hop. Second request followed ridePreferences rebuild. Log lacks preference values, contiguous dirt-run lengths and competing-route costs. Cannot prove lengths or whether a short section is necessary from this evidence. Proposed rule: do not reward optional paved-to-dirt-to-paved excursions shorter than 1 km; preserve essential connectors and required waypoint/fuel access. Apply to contiguous runs, not individual graph edges; compare usable paved alternatives before rejecting. Reproduce both original and snapped endpoint cases and add diagnostics before deployment.

## Approved direction and expanded preview
Richard selected Open Terrain for Groups and Loop. open-terrain.html extends it to From Here, Plan, Saved, Navigation, Layers, Packs, Profile and ride preferences. All states are illustrative. Direction and surface are matching custom disclosures rather than default browser select controls. Existing wordmark font size and map-chip height are retained. Native navigation behavior is frozen; its screen is a concept only.

Badge decision: DEV in development; PRO for active subscription in production, FREE otherwise. Only the native badge has been implemented at this stage. Signed generic-iPhone build and eight DEV isolation checks passed. No simulator, device installation or production publication.

## Rider review revision
HTML only. Invite is pinned between group metadata and the scrolling rider list; rider avatars removed; Start sharing orange and Stop sharing black. Map-facing sheets fit content from the bottom with a 60% preview-height ceiling; Profile uses full height. Fuel, ride preferences and the existing right map-control sequence sit above routing sheets. Numbered leg buttons separately represent map focus; compact leg disclosures keep details inside. Return action remains visible (disabled for an already closed loop), above distance/surface composition and a single Save/Export/Start row; Clear remains last. Layers now contains the incumbent Fuel/Campgrounds/Lodging/Liquor switches and downloaded maps. Pack actions are inline with region and status. Navigation follows source hierarchy: top logo/cue, speed left and controls right, waypoint/countdown, surface/trip expandable row, Report/End with confirmation. Sample data does not certify native navigation rendering; no application files changed in this revision.

Dropdown review: Loop order is Direction, Surface, Distance. All shared choice lists now open as floating overlays, including per-leg surfaces, without resizing the sheet or displacing controls. Lists close on outside click or Escape. HTML only.

Saved route review: read-only details with View on Map and prominent Continue Planning only. No return, clear, save, export, start or per-leg editing until continuing to Plan.

Groups rider details: clickable names open a compact drawer with sample location/update status, View on Map and Route to Rider. Back returns to the roster. Location data and map/route actions remain illustrative; native behavior unchanged.

Return-action decision: remove Create Return Route throughout the preview. Loop owns automatic round trips; Plan supports manually chosen outbound/return waypoints; From Here can start a new return journey on arrival. Supersedes earlier persistent-return decision. Native app unchanged.

Groups follow-up supersedes rider drawer: details expand directly beneath the selected rider. Same rider toggles closed; another rider replaces the expansion. Compact location/status rows and two small actions retain touch targets. HTML accordion interactions verified.

Rider grouping refinement: chevrons removed, whole name/status row toggles details, tighter 60px rows. Expanded rider header and details share a subtle background and boundary so ownership is clear. Sharing remains a separate button.

Map controls: use exported Apple symbols matching native MapControlStack (safari, person.crop.circle, dot.scope, route curve) and native fuel/settings symbols. Right stack remains on map-facing screens; View Route is beside recenter when a route exists. Fuel/settings appear only with routing tools. 50px controls and 10px gaps match native layout. No simulator used; native files unchanged.

Groups hierarchy restored: group library with created/joined roles, member/live counts and Create/Join; opening a group shows its roster. Rows contain sharing dot, name, Current Location and labelled coloured status badge. No update-age prose. Inline expansion retains actions; own sharing action is in own expansion. Demo data illustrates green Riding, yellow Flat tire and gray Offline; red issue styling available. Native unchanged.

Iconography pass: surface-choice symbols, navigation surface and fuel cues, pack state icons, rider status symbols. New 50px zoom +/− buttons use 10px internal gap and 20px gap before the existing stack. Navigation keeps overview between zoom and 3D. HTML buttons announce intended actions; native zoom implementation remains part of app implementation.

Motion/material preview: brief sheet entrance/exit, bounded disclosure expansion, inline rider continuity, dropdown fades/scales, switch and press feedback; reduced-motion bypasses spatial animations. Frosted translucent sheet with static backdrop blur and opaque fallback. Map itself stays static. Sheet cap reserves space for complete zoom/control stack. Native implementation unchanged.
