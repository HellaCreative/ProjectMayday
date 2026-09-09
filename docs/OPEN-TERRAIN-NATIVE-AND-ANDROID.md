# Open Terrain — iPhone and Android implementation contract

Approved September 9, 2026. Visual authority: `experiments/ui-directions-20260909/open-terrain.html` and its CSS, ending with commit `c8877ff`. The HTML is interactive sample data, not a backend implementation. Native functional truth remains existing product/routing/navigation contracts. Do not remove a control or state merely because the comp omits it.

## Shared visual vocabulary

| Role | Value / behavior |
|---|---|
| Brand accent | `#FF8000`. No brown/orange substitutions for text, switches, selected tabs, menus or CTA accents. |
| Primary text | `#16181C`; secondary `#616872` |
| Main navigation | Solid white, fixed to physical bottom including safe area, square top corners; soft upward shadow. |
| Selected item | Orange rounded rectangle, 12 pt/dp radius, white icon and title. Icon 23, title 12 medium; 6 gap, centered. |
| Closed Route with route present | Orange outline and orange icon/title; no orange fill. |
| Sheets | Frosted system material, top rounded corners 22, square bottom, beneath main navigation. Map remains visible through material. |
| Rows | Compact, light separators; avoid nested opaque cards. Interactive targets >=44 pt on iPhone, >=48 dp Android. |
| Typography | Platform system font; use monospaced digits for changing measurements, not all text. |
| Map controls | Existing 50 pt/dp square, 12 radius. Original symbols/order unchanged. |
| Zoom | White fill, black 1 stroke, black + / −, 50 square. Gap10 between; gap20 before next map control. |
| Status | Green riding, gray not sharing/offline; existing issue severity uses yellow/orange or red. Text and symbols accompany color. |

Route surface paint remains semantic and independent of UI accent. Never recolor graph access, gravel, loose surface, unknown or ferry classifications as part of this visual pass.

Logo size stays unchanged (16-point wordmark and existing map chip dimensions). DEV for development; production PRO only for an active subscription, FREE otherwise. Signing in alone does not grant PRO.

## Shell and motion

Layers, Profile, Groups and Route toggle closed on a second tap. Switching tabs closes current sheet first (210ms ease-in), then opens next (320ms ease-out). No opacity fade on either leg. Main navigation itself does not translate, resize, or fade; only its active orange background moves between items. Respect Reduce Motion/system animator settings. Cancel a pending transition when another selection arrives; last tap wins.

Sheets grow from bottom to intrinsic content height and stop at a map-preserving maximum. Long content scrolls within the sheet, while main nav remains accessible. Profile may occupy the full height, retaining navigation/close escape. Menus are overlays/popups, never inline insertions that push controls or increase sheet height. Android should use anchored popup/menu equivalents, not expanding layout blocks.

Fuel and Rider Settings appear above the sheet only while routing tools are open. Existing right map controls remain on map-facing screens. View Route appears when route geometry exists. In navigation, +/− precede the existing overview control, then 3D and remaining controls. Zoom changes the live map zoom without changing route geometry, current center or bearing; keep follow zoom when following. Clamp to valid map zoom range.

## Screen and state matrix

| Surface | Required behavior |
|---|---|
| From Here | Current position → destination; surface choice; existing recovery/error/fuel/access controls. Compact route legs and route totals after build. |
| Loop setup | Current location is origin. Direction (8 compass choices), Surface, Distance 50–500km in 25km steps. Create Loop; retain cancellation, location failure and routing error states. |
| Loop built | Hide setup; show common legs, fuel/ferry notices, totals, Save/Export/Start Ride, then Clear. Clear restores Loop setup. |
| Plan | Manual waypoints; number focuses leg on map; row options preserve profile, unknown acknowledgement and fuel replacement. No Create Return Route. |
| Saved preview | View on Map and prominent Continue Planning only. No Save, Export, Start, Clear or Return action. Continue Planning opens editable Plan preserving geometry. |
| Built editable route | Compact legs; distance/dirt/paved and surface composition, Save/Export/Start Ride in one row, Clear last. Required warnings remain visible. |
| Rider Settings | Wander slider, Avoid cities and towns and Avoid highways switches. Apply preserves originating routing mode and closes settings. |
| Layers | Standard/Rich, rider services switches, downloaded maps. Region title/status/size alongside Update (if stale) and Delete; show busy/error states and preserve real management behavior. No legend. |
| Profile | Account/name editing, subscription purchase/restore/manage, fuel settings, display/awake controls, legal, sign-out and deletion remain accessible. Full-height permitted. |
| Navigation | Keep current cue/speed/surface/waypoint/fuel/trip/report/end functions and positions. Material/iconography changes must not remove information. |

All boolean choices use switches. Mutually exclusive choices remain menus/segments, not switches.

## Groups

Two levels: membership library (owned/joined groups, member count, sharing count, Create/Join) → group roster. Invite a rider/code/copy stays above the rider scroll list. No avatar feature is introduced.

Rider rows group sharing dot, name/You, Current location and colored status. Tap whole row to expand inline View on Map and Route to Rider. Tap again to collapse; opening another row closes the prior row. No row chevron suggesting another screen. Own row provides status selection and Start sharing (orange) / Stop sharing (black). Preserve account-wide sharing semantics, waiting-for-GPS indication, error display, owner Delete Group and member Leave Group.

Only live, valid coordinates enable peer actions. Offline must not be labelled current. Resolve actual locality from coordinates where available; never use sample Porters Lake text. Unavailable geocoding needs an honest coordinate/unavailable fallback. Routing uses existing GroupMemberRouteTarget with original timestamp, accuracy and live state; it must still apply existing safety checks. Do not create another route engine or bypass stale-location guards.

## Icon mapping for Android

Use the provided prototype map icon reference assets to match silhouette and stroke. SF symbol names specify semantics; choose Android vector equivalents with consistent stroke, or author matching vector paths. Do not substitute navigation/recenter icon meanings.

| Meaning | iOS symbol |
|---|---|
| Layers | square.3.layers.3d (verify incumbent DockTab symbol) |
| Profile / sharing | person.crop.circle |
| Groups | person.2 |
| Route / overview | point.topleft.down.to.point.bottomright.curvepath |
| Compass | safari |
| Recenter / follow | dot.scope |
| Fuel | fuelpump.fill |
| Rider settings | slider.horizontal.3 |
| Zoom | plus / minus |
| Gravel | circle.grid.3x3 |
| Loose / dirt | mountain.2 |
| Pavement | road.lanes |
| Unknown | questionmark.diamond |
| Ferry | ferry |

## Implementation and acceptance

Native entry points: `RootView`, `DirtTheme`, `DockSheetPanel`, `MapControlStack`, `RoutePlannerCard`, `GroupsSheet`, `LayersSheet`, `ProfileSheet`, `NavigationHUD`. Actual zoom is dispatched through MapState.CameraCommand and MapLibreMapView. Do not copy HTML mock data, toasts or simulated state.

Check normal and rapid tab switching, reopening existing routes, empty/long lists, stale/offline members, failed pack management, cancelled route builds, accessibility text sizes, VoiceOver/TalkBack labels, Reduce Motion, landscape and safe-area overlap. Verify +/− during follow and free pan, saved preview versus continued plan, and fuel replacement in all routing modes. Native build success is not physical-device visual acceptance. No simulators are authorized for this work; White iPhone review remains the visual acceptance point. Android implementation and device acceptance remain open, not claimed by this handoff.

### Approved contrast adjustment — September 9, build 25

Supersedes the original thin-frost treatment: dropdown fields are opaque white,
with a light-grey #D8DADD 1pt/dp border. Sheets use regular system material;
the HTML preview uses 92% white tint. The controls and sheet geometry do not
change. Apply these contrast values before assessing Android visual parity.
