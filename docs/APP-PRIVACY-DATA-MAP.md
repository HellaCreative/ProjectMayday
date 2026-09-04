# DIRT iOS — privacy and data map

**Status:** code-backed engineering inventory for the App Store privacy
questionnaire and public policy review. This is not legal advice and does not
replace Richard's final App Store Connect declarations.

This inventory is also the starting contract for Android's Google Play Data
safety review. The Android build must reconcile it against Android-specific
SDKs, permissions, storage, authentication, billing, and background services;
it must not copy these declarations without verifying its actual behaviour.

## Data leaving the device

| Data | When | Destination | Linked to account | Tracking | Purpose |
| --- | --- | --- | --- | --- | --- |
| Apple/Supabase user ID | Sign-in and authenticated features | Supabase | Yes | No | Account and app functionality |
| Email address | Authentication provider supplies it | Supabase Auth | Yes | No | Authentication/account functionality |
| Display name | Rider creates or updates a profile | Supabase Auth metadata + `profiles` | Yes | No | Profile and Groups functionality |
| Route and fuel coordinates | Online planning sends the exact current-location/pin endpoints and nearby fuel boxes | DIRT routing/fuel service on Vercel | No account ID is included in this request payload | No | Route and fuel planning |
| Visible geographic bounds | Rider enables fuel, campground, lodging, or liquor layers and moves the map | DIRT fuel service; Overpass API for non-fuel POIs | No account ID is included in this request payload | No | Map POI functionality |
| Requested map-tile coordinates | Map display and offline preparation request the visible or first-stage tile cells | DIRT Shortbread tile service, with public OpenStreetMap fallback | No account ID is included in the tile URL | No | Basemap functionality |
| Precise or approximate rider location | Rider deliberately enables Group sharing, sends an alert, or reports an incident; accuracy follows the rider's system permission | Supabase | Yes | No | Groups, safety, and route-quality functionality |
| Group name, membership, role, and invite code | Create/join/use a Group | Supabase | Yes | No | Groups functionality |
| Rider status and distress/route alert | Rider shares status or sends an alert | Supabase + private Realtime channel | Yes | No | Group safety/functionality |
| Reported route incident | Signed-in rider submits a route problem | Supabase `route_incidents` | Yes | No | Route safety and quality |
| Contributed road-edge IDs, route distance/regions, and ride timing | Signed-in rider opts into track contribution; raw GPS coordinates are not included | Supabase `track_contributions` | Yes | No | Route quality/product improvement |

DIRT has no code-backed advertising or cross-company tracking purpose. The app
privacy manifest therefore declares tracking as false and declares Name, Email
Address, User ID, Precise Location, Coarse Location, and Other User Content for
app functionality. Location is marked linked because some location flows are
account-backed, even though the routing, POI, and tile request payloads do not
include a DIRT account ID.

## Data kept locally

| Data | Storage | Notes |
| --- | --- | --- |
| Saved routes and geometry | SwiftData app container | Local unless a rider exports/shares a GPX |
| Imported GPX geometry | In-memory/current route and local save when requested | The import itself is not uploaded by the app |
| Fuel, layer, onboarding, cue, keep-awake, and contribution preferences | UserDefaults | App-only settings; required-reason `CA92.1` |
| Free-navigation counter | Keychain | Survives ordinary app relaunch and reinstall behavior depends on Keychain state |
| Supabase session | Supabase SDK/Keychain | Authentication credential |
| Map tiles and routing packs | App caches/application support | Downloaded for maps and offline routing |
| Last known latitude, longitude, timestamp, and accuracy | UserDefaults | Seeds the next launch before Core Location supplies a newer fix |
| Pending incident reports | UserDefaults queue | Uploaded only for a signed-in rider; retained locally on failure |
| Diagnostic log | App memory/share file | Exported only when the rider explicitly invokes sharing |

## Deletion contract

An in-app deletion request must be authenticated and handled server-side. It
must either complete or report failure; the client must never represent a local
sign-out as account deletion.

The server contract must remove or irreversibly anonymize, in a defined order:

1. live presence and Realtime participation;
2. unresolved and historical rider alerts;
3. group memberships;
4. owned groups, or transfer/delete them according to the documented rule;
5. route incidents and opt-in track contributions according to the published
   retention policy;
6. profile data; and
7. the Supabase Auth identity.

The account screen must separately explain that deleting a DIRT account does
not itself cancel an Apple subscription and provide Apple's subscription-
management destination.

## App Store Connect answers to reconcile

- Precise Location: collected, linked, not tracking, app functionality.
- Coarse Location: collected, linked, not tracking, app functionality when the
  rider grants Approximate Location.
- Name: collected, linked, not tracking, app functionality.
- Email Address: collected, linked, not tracking, app functionality.
- User ID: collected, linked, not tracking, app functionality.
- Other User Content: collected, linked, not tracking, app functionality.
- Purchases: StoreKit entitlement is evaluated on-device. Revisit this answer if
  transaction data is later copied to Supabase or another developer server.
- Diagnostics: the current log is user-exported rather than automatically
  transmitted. Revisit this answer before adding crash or analytics tooling.
- Tracking: No, based on the current code and vendor use.

## Owner/legal confirmations still required

- [ ] Retention period for presence, alerts, incidents, and contributed tracks.
- [ ] Whether incident/contribution records are deleted or anonymized after
      account deletion.
- [ ] Support contact and response path for privacy/deletion requests.
- [ ] Supabase regional processing and subprocessors reflected in policy text.
- [ ] Public privacy, data-use, GDPR, and subscription pages match this inventory.
- [ ] Final App Store Connect privacy answers match both this inventory and the
      Release archive's generated privacy report.

## Official Apple references

- [App Privacy details](https://developer.apple.com/app-store/app-privacy-details/)
- [Describing data use in privacy manifests](https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests)
- [Required-reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [File timestamp required reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- [Offering account deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/)
