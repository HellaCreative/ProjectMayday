# Open Terrain — native implementation status

Routing behavior is maintained only in [ROUTING-SOURCE-OF-TRUTH.md](ROUTING-SOURCE-OF-TRUTH.md). This document describes presentation, not routing architecture or computation policy.

Source review: September 9, 2026, current local working tree. This is an implementation inventory, not a visual acceptance report or release qualification. No build, simulator, screenshot, installation or physical-device inspection was performed for this document.

## Authority and scope

The approved [Open Terrain HTML](../experiments/ui-directions-20260909/open-terrain.html) and its CSS remain visual authority, as recorded in [the native and Android contract](OPEN-TERRAIN-NATIVE-AND-ANDROID.md). Native product, routing, navigation, account and safety contracts remain functional authority. Sample riders and metrics from the HTML are not native data.

This record covers the native UI changes in `RootView`, `DirtTheme`, `DockSheetPanel`, `MapControlStack`, `RoutePlannerCard`, `GroupsSheet`, `LayersSheet`, `OfflinePacksSheet`, `ProfileSheet`, `NavigationHUD`, and the zoom command in `MapState`/`MapLibreMapView`. Concurrent routing, pack, project configuration and build-script changes in the working tree are outside this UI inventory.

## Present in source

| Surface | Implemented boundary |
| --- | --- |
| Shared theme | Brand orange and action resolve to `#FF8000`; pressed orange matches it. Shared sheets use `ultraThinMaterial`; row fill opacity is 0.18. Shared headers align their titles left. Existing route-surface colors remain separate semantic tokens. |
| Portrait navigation | Solid white background extends across the physical bottom safe area, with square outer corners and an upward shadow. Active items use an orange rounded rectangle of radius 12, white icon/title, 23-point icon, 12-point medium title and 6-point gap. A closed Route with existing geometry uses orange outline/icon/title. The selected background uses matched geometry. |
| Sheet switching | Dock selection cancels the prior pending task, closes the current sheet using 210ms ease-in, then opens the selected sheet using 320ms ease-out. Transitions contain movement without opacity. A repeated tab tap closes it. The tab-switch path skips animation and delay for Reduce Motion. |
| Sheet geometry | Portrait panels have 22-point top corners and square bottoms, extend behind navigation, and reserve 78 points for dock clearance. Groups and Layers use measured content with a 46% height ceiling and a 380-point map reserve. Route uses a related bounded content-height calculation. Profile is hosted in a full-height-capable dock panel. Scroll containers retain access to longer content. |
| Map controls | Added 50-point white zoom buttons with black symbols, 1-point black stroke and radius 12. Spacing is 10 points between zoom controls and 20 points before the next control. Zoom precedes navigation overview and the existing controls. Layers/Groups retain the broader map-control stack. Fuel and Rider Settings remain conditional on routing tools. |
| Zoom integration | Buttons dispatch `zoomBy` through `MapState.CameraCommand.zoom` to MapLibre `setZoomLevel`. Requested zoom is clamped to 2–20; following updates `followZoom`. The command does not edit route geometry or explicitly change center/bearing. MapLibre animation observes Reduce Motion. Runtime preservation of camera behavior still needs verification. |
| Loop and editable routes | Loop uses Direction, Surface, then Distance, retaining the 50–500km slider in 25km increments and native menu controls. Setup retains existing routing/cancellation branches; built output uses existing legs/notices/totals/actions. The Create Return Route affordance was removed from From Here and Plan. Save/Update, Export and Start ride labels are sentence case; route metrics lose their surrounding opaque card. |
| Saved preview | A loaded saved track exposes View on map and a prominent Continue planning action. Save/Export/Start/Clear are absent from this preview branch. Continue planning calls the existing model conversion; View on map focuses geometry and closes the route card. The unloaded Saved library retains its existing import/list functions. |
| Groups | Existing account gate, library, Create/Join and membership data remain. Roster has invite/code/copy above its own scroll area, compact rows without row chevrons, and one inline expanded rider at a time. Own actions call existing status and account-wide sharing methods. Peer actions view coordinates or pass original member metadata to `GroupMemberRouteTarget`. Delete/Leave, waiting-for-GPS and errors remain. Live locality uses reverse geocoding, with coordinates/unavailable fallback; no sample locality is inserted. |
| Layers and packs | Scroll content exposes Standard/Rich, existing rider-service switches and installed map rows with title, revision, size, conditional Update, Delete, busy indicators and errors. Actions call existing graph-pack management. The legend is absent from the rendered body. Installed rows in the separate offline-packs sheet also place management actions beside details. |
| Profile and navigation | Profile now occupies the dock shell instead of a full-screen cover; existing profile content remains. Navigation cue, speed, waypoint, trip and preparation surfaces use the shared material/ink vocabulary. Surface labels use a common symbol helper. These styling changes do not establish navigation functional acceptance. |

## Discrepancies and review gaps

These findings describe source as reviewed; they are not additional design decisions.

- Earlier `DESIGN.md` frontmatter/prose still records the previous orange, material and dock baseline. Its native addendum identifies the approved HTML/contract as the authority for this replacement; the old token block is not a current Open Terrain native token export.
- Landscape retains the incumbent side dock and sideways drawers. The white fill is applied there, but the contract's physical-bottom navigation description does not describe that layout. Landscape equivalence requires explicit review.
- `DirtApp` explicitly forces light appearance, so appearance-adaptive idle ink resolves dark against the fixed-white dock; the earlier suspected dark-appearance contrast issue is not a current app defect. Some old theme/dock comments still describe the previous orange and foreground contrast.
- Dock tab switching uses the 210ms close/320ms open sequence. `dismissDockSheet` now also cancels pending transitions, clears the selected destination, and closes using 210ms ease-in with a Reduce Motion branch. Other direct state changes, panel-height animation and Groups inline expansion still need runtime review for consistent reduced-motion behavior.
- Groups uses the existing dark `chrome` token (`#16181C`) for Stop sharing, rather than literal black. Own-row inline controls replace peer map/route actions in that row. Offline rows show “Unavailable” under a persistent “Current location” heading; confirm that wording communicates absence clearly.
- Peer enablement depends on `member.isLive` and coordinate presence. `isLive` is derived through the existing presence policy, including coordinate validity; route requests retain their timestamp/accuracy/live metadata for existing safety checks. The direct View on map action needs runtime verification while a previously live row becomes stale/offline.
- The new Layers body renders installed-pack management directly. Older private legend/pack-section helpers remain in the file but are not rendered by that body; do not count them as visible affordances.
- Fixed heights, compact horizontal actions and the added zoom stack have not been visually checked for small displays, long names, large text, keyboard presentation, scrolling or safe-area collisions. Source structure alone cannot prove the requested sheet footprint or material appearance.

## Verification status and remaining acceptance

The implementation coordinator reports that the first complete final-code build passed and that code review resolved four findings: Profile in landscape, speed contrast, member-locality cache freshness, and sheet-height positioning. These are reported build/source-review outcomes, not checks run by this documentation pass. The coordinator is preparing DEV version 24 and rebuilding it; this record does not assert that version's build or installation has finished.

Physical White iPhone acceptance remains open: normal/rapid/repeated tab taps; every dismissal path; the app's light appearance; Reduce Motion; accessibility text and VoiceOver; portrait/landscape and safe areas; short/long Groups and Layers content; actual geocoding failure; sharing/GPS errors and stale peers; busy/failed pack management; Loop build/cancel/clear; saved preview → editable Plan geometry; fuel replacement and warnings; navigation controls and zoom during following/free pan.

No Android implementation, Android device acceptance, physical iPhone visual acceptance, installation or production publication is claimed. Android must reproduce the accepted rider outcomes under [the shared contract](OPEN-TERRAIN-NATIVE-AND-ANDROID.md) and [Android parity requirements](ANDROID-PARITY.md).

### Delivery evidence — 17:26 Halifax

Coordinator completed DIRT Dev version 2 (24), generic iOS device build with two compiler jobs. Build succeeded; `verify-ios-development.sh` passed all environment checks and embedded CFBundleVersion is 24. `devicectl` confirmed installation of `com.mayday.dirt.dev` on connected White iPhone 16. No simulator was started. This supersedes the pending-install status above; physical visual acceptance remains open.
