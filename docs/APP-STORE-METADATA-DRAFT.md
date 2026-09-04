# DIRT iOS — App Store metadata draft

**Status:** prepared draft. Richard must approve the claims, supported-device
scope, pricing, screenshots, and legal/commercial fields before entry in App
Store Connect.

## Product identity

| Field | Draft |
| --- | --- |
| Name | DIRT |
| Subtitle | Adventure Routes. More Dirt. |
| Primary category | Navigation |
| Bundle ID | `com.mayday.dirt` |
| SKU | `MAYDAY-DIRT-IOS-001` |
| Privacy policy | `https://dirtmoto.app/privacy/` |
| Support | `https://dirtmoto.app/support/` |
| Marketing site | `https://dirtmoto.app/` |

## Promotional text

Build the ride between the points. DIRT creates dual-sport routes around the
surface mix you want, plans fuel stops, and keeps your near-term ride available
offline.

## Description

DIRT is adventure navigation built for dual-sport riders who would rather find
gravel, forest road, and two-track than simply take the fastest highway.

Choose the character of each ride:

- Dirt searches for the strongest available dirt experience.
- Balanced aims for an engaging mix of dirt and pavement.
- Clean keeps the ride on pavement when that is what the day calls for.

Set a motorcycle's fuel range and DIRT can add route-connected fuel stops as
part of the journey. Inspect each riding section, adjust its profile, and decide
whether a specific section may use roads whose public motor access is unknown.

Save routes on the iPhone, export GPX files with DIRT Pro, and prepare the first
part of a ride for navigation. Map tiles are staged forward as the ride
progresses, while regional routing packs support recovery and rerouting when
cell service disappears.

Private Groups let signed-in riders share live location deliberately, view
their crew, route toward a rider, and send ride-status alerts. Location sharing
can be stopped at any time.

DIRT uses OpenStreetMap-based road information. Surface, access, fuel,
conditions, closures, and ferry service can change. Review the route, obey
signage and closures, carry appropriate supplies, and ride within your ability.

## Keywords draft

`motorcycle,dual sport,adventure,gravel,dirt,GPX,navigation,trail,offline,route`

## Subscription localization draft

### DIRT Pro Monthly

Unlimited DIRT navigation and GPX export, billed monthly.

### DIRT Pro Yearly

Unlimited DIRT navigation and GPX export, billed yearly.

Do not put a guaranteed free-trial claim in static localization. The app should
show introductory-offer language only when StoreKit reports that the customer
is eligible.

## App Review notes draft

DIRT is a native dual-sport motorcycle route-planning and navigation app. It
uses precise location to show the rider, create a route from the rider's
position, provide active navigation, support offline rerouting, and—only when
the rider deliberately enables it—share live position with a private Group.

Route planning itself does not require an installed routing pack while online.
When navigation begins, DIRT prepares only the first visible route stage and
the rider's current regional routing pack. Later map stages advance during the
ride; regional packs are not bulk-downloaded from a long itinerary.

Local route saving is free. GPX export and navigation after the included free
starts require DIRT Pro. The paywall supports purchase and Restore Purchases.

Sign in with Apple is used for Groups and account-backed functionality. Provide
the reviewer with two test accounts if private multi-rider Group behavior must
be evaluated. Account deletion is available from the account/profile area.

Background location is used only while active navigation or deliberate live
Group sharing requires it. The rider can end navigation or stop sharing from
the app.

No CarPlay, Apple Watch, or Live Activity functionality is claimed in this
version.

## Screenshot story

Use real Release-build screens with no tester controls or invented features.

1. Map-first route planning — "Build the ride, not just the arrival"
2. Dirt/Balanced/Clean choice — "Choose your kind of road"
3. Fuel-aware itinerary — "Fuel stops become part of the route"
4. Leg editing — "Tune each section of the ride"
5. Navigation HUD — "Clear guidance when the pavement ends"
6. Offline preparation — "Prepare the road ahead"
7. Groups, only after privacy and subscription behavior are final — "Keep the
   crew in sight"

## Fields Richard must supply or approve

- [ ] Final subtitle and description tone.
- [ ] Copyright owner/year.
- [ ] Age rating questionnaire.
- [ ] iPhone-only versus iPhone+iPad distribution.
- [ ] Screenshots and optional preview video.
- [ ] Final subscription price, territories, and introductory offer.
- [ ] Review contact name, phone, and email.
- [ ] Reviewer accounts/instructions.
- [ ] Manual, automatic, or phased release.
