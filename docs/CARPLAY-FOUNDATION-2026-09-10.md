# CarPlay — setup and implementation record

Last updated: September 14, 2026.

## Current status

Apple approved the CarPlay entitlement for the developer account. CarPlay Navigation is enabled and saved for the production DIRT App ID, and a new App Store provisioning profile was generated and downloaded. This completes the developer-website setup performed in this session. It does not mean the CarPlay interface is implemented, tested, or released.

## Completed September 14

Richard supplied Apple Developer Relations’ approval email (Case-ID: 22137173) and authorized following its configuration steps in the open Apple Developer website.

| Item | Verified result |
| --- | --- |
| Developer team | Hella Creative Solutions — 34XM6B4G7A |
| Production bundle ID | com.mayday.dirt |
| App ID description | A dual-sport motorcycle navigational map tool |
| Apple identifier record | 9N6KGXKR39 |
| Capability | CarPlay Navigation App enabled |
| Save verification | Reopened the identifier after saving; CarPlay remained checked and Save was disabled, indicating no pending changes |
| New profile name | DIRT Production CarPlay App Store 2026-09-14 |
| Profile type | App Store distribution |
| Profile ID | 9CUXT6HMJ2 |
| Certificate selected | Existing Hella Creative Solutions Distribution certificate, displayed as expiring February 24, 2027 |
| Profile expiry | February 25, 2027, as displayed by Apple |
| Downloaded filename | DIRT_Production_CarPlay_App_Store_20260914.mobileprovision |
| Download verification | Safari Downloads showed the completed 13 KB file |

Apple warned that modifying capabilities invalidates provisioning profiles containing this App ID and requires regeneration for future use. The change was confirmed and the new profile above generated afterward. No certificate was created, revoked, or replaced.

The downloaded profile was opened from Safari, but installation into Xcode was not independently verified. Do not treat the download or open action as proof that an archive will sign successfully with CarPlay.

## Scope of this setup

- Only the production App ID (`com.mayday.dirt`) was configured. The development App ID (`com.mayday.dirt.dev`) was not changed.
- No app source, Xcode capability settings, entitlements file, scene configuration, or navigation adapter was changed in this setup session.
- No development provisioning profile was generated.
- No simulator or physical device was operated.
- No archive, upload, App Review submission, or public release was performed.
- No new agreement was accepted during this session; Richard had previously confirmed accepting the CarPlay request terms.

## Remaining work

1. Configure the development App ID and development signing when preparing CarPlay testing.
2. Verify the downloaded distribution profile is installed and that the selected certificate has its matching private key available to the build machine. Preserve existing signing identities.
3. Add the approved CarPlay entitlement and scene configuration to the intended app targets, then implement the map and maneuver adapter using the existing navigation session.
4. Validate signing and the completed CarPlay experience using the tests below. Reuse one existing simulator; additional devices or clones require Richard’s explicit authorization.
5. Include CarPlay in a future approved build and review submission only after implementation and qualification. Final App Review submission and public release remain deferred.

The groundwork and historical request notes below are retained for context. Any earlier “pending approval”, “unsubmitted”, or “no capability enabled” statements are superseded by the verified September 14 record above.

## Apple setup

CarPlay navigation requires Apple approval for the navigation entitlement, followed by App ID, provisioning and Xcode configuration. It is not an App Store Connect availability switch. Start with Apple's entitlement request and applicable addendum; do not add an unapproved entitlement to the launch archive.

Official resources:
- https://developer.apple.com/carplay/
- https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements
- https://developer.apple.com/contact/carplay/

## Prepared request content

App: DIRT by Mayday. Bundle: com.mayday.dirt. Apple app ID: 6794633890. Website: https://dirtmoto.app. Proposed category: Navigation.

DIRT provides motorcycle ride planning and navigation, with surface-aware routes, saved rides, fuel planning and turn-by-turn guidance. We propose a CarPlay interface for following a ride prepared on iPhone, showing upcoming maneuvers and trip estimates, and ending navigation. The current app is in distribution testing; the proposed CarPlay interface has not yet been implemented. Route planning and detailed account interactions would remain on the phone, with the vehicle interface focused on guidance.

Confirm the organization/contact fields from the signed-in developer account and answer the actual application form accurately before submission.

## Implementation boundaries

- Reuse the existing navigation session, route geometry, maneuvers, progress, voice and entitlement state. Do not create a second routing engine or independent active ride.
- Add the CarPlay scene and map template adapter after capability approval; keep launch signing unchanged until then.
- Keep initial controls to choose an already prepared/saved route, start guidance, view next maneuver/remaining journey, and end guidance. Use Apple's templates and driving interaction constraints.
- Reconnect to the same ride after cable/wireless disconnect. One end-navigation action stops both displays, without double voice playback or duplicate routing.
- Handle offline packs, lost location, service errors, denied subscription and cancellation explicitly using existing app behavior.
- Validate map attribution/licensing on the vehicle display as well as iPhone/iPad.

## Acceptance tests before advertising support

Simulator plus real CarPlay device: touch and rotary input; different display sizes; reconnect; background/locked phone; interruptions/audio; offline travel; route recalculation; subscriptions; location permissions; safe-area and text readability. Include a single-session consistency check across phone and vehicle display.

Android Auto is a separate platform capability and qualification effort; this plan does not claim Android Auto support.

## Signed-in form prepared — September 10
Opened https://developer.apple.com/contact/request/carplay/ under the existing developer account and selected Navigation (turn-by-turn directions). Filled the application and planned-feature descriptions. The form remains unsubmitted; it is not a server-saved draft. The reusable copy above remains in this document.

The actual form requests multiple JPG navigation screenshots (2 MB maximum each) and acceptance of the CarPlay Entitlement Addendum, revision June 8, 2026. No screenshots were uploaded and no agreement accepted. The optional App Store URL was left empty because the app is not publicly released. Final navigation screenshots and the owner's review/acceptance of the separate agreement are the remaining request steps. This does not block the iPhone/iPad launch or grant the entitlement.

## CarPlay request submitted — owner confirmation
Richard uploaded the navigation screenshots, accepted the CarPlay terms and received Apple’s submission acknowledgement. The request is now awaiting Apple review. Earlier unsubmitted/draft status is superseded. Entitlement approval and CarPlay implementation are not yet complete.


## Apple follow-up: maneuver variants evidence

Apple asks for additional screenshots illustrating how DIRT would populate
CPManeuver variants. Prepare a reply in the existing email thread; do not
represent current iPhone screens as implemented CarPlay screens.

Existing RouteManeuver supplies instruction, type, side, distance and position
along the route. NavigationSession supplies current and following maneuvers.
The planned adapter would provide localized instructionVariants ordered from
most to least preferred, a matching symbolImage, and CPTravelEstimates using
navigation progress. CPMapTemplate and CPNavigationSession would host the map
and upcoming maneuvers. None of that adapter is currently implemented.

Illustrative text variants (not real route observations):
- Right: “Turn right at the next junction”, “Turn right”, “Right”.
- Left: “Turn left at the next junction”, “Turn left”, “Left”.
- Continue: “Continue straight through the junction”, “Continue straight”, “Straight”.
Road names should appear only when supplied by the route data; do not invent
names on unnamed trails. Distance/time belong in structured travel estimates.
Use ordinary turn-by-turn examples as primary evidence, rather than only rally
severity cues. Show map, active route, maneuver arrow, instruction and distance.

Awaiting owner reattachment of the navigation screenshots already submitted,
plus any additional active-guidance examples. Review and label the final
attachments before finalizing/sending the reply. If concept illustrations are
needed, label them “Proposed CarPlay presentation — not implemented”.

Sources:
https://developer.apple.com/documentation/carplay/cpmaneuver
https://developer.apple.com/documentation/carplay/cpmaneuver/instructionvariants
