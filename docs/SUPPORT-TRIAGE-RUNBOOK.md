# DIRT customer-support triage runbook

**Status:** safe intake and engineering handoff baseline. This document does
not authorize access to rider records, refunds, account deletion on a rider's
behalf, production changes, or pack edits.

## First response

1. If the rider may be in danger, tell them to stop riding, move to a safe
   place, and use local emergency services when appropriate. DIRT is not an
   emergency-response service.
2. If location sharing may be wrong, tell the rider to open the affected Group
   and stop sharing. If they cannot confirm that, close DIRT and disable its
   Location access in iOS Settings until support resolves the report.
3. Acknowledge the report and give the next-update time from the severity table
   in `LAUNCH-OPERATIONS-RUNBOOK.md`.
4. Gather only the minimum safe intake below and assign one case identifier.

## Minimum safe intake

Ask for:

- DIRT version and build from the installed app record;
- iPhone model and iOS version;
- date, local time, and timezone of the event;
- the action taken and the exact message shown;
- whether the phone was online, offline, or changing networks;
- a screenshot with unrelated personal information cropped out;
- for a route/data report, start/end or place/road names and exact coordinates
  only when the rider consents and precision is necessary; and
- any visible DIRT request ID.

Never ask for an Apple ID password, one-time verification code, Supabase token,
full App Store receipt, payment-card data, private key, invite code, or another
rider's precise live location. Never ask a rider to publish their home address.
Keep exact location out of a general support channel; attach it only to the
restricted engineering case when necessary.

DIRT does not automatically upload its session log. Development builds expose
**Profile → Tester → Share app session**, but that exporter is absent from the
public Release build. Do not tell an App Store rider to look for it. When a log
is available, the rider must initiate sharing; treat the file as potentially
sensitive even though the code deliberately omits account IDs and Group
coordinates.

## Triage matrix

| Report | Immediate rider instruction | Verify / collect | Escalate to | Do not do |
| --- | --- | --- | --- | --- |
| Purchase, trial, renewal, or Restore Purchases | Keep the App Store signed into the purchasing Apple account; retry Restore only after network recovers | Product ID, localized message, purchase/restore state, StoreKit availability, version/build | Subscription owner; Apple support for billing/refund execution | Promise a refund, invent pricing/trial eligibility, request a receipt or password |
| Account deletion | Stop Group sharing first; use Profile → Delete account while signed in. Explain that DIRT deletion does not cancel the Apple subscription | Exact confirmation/error, time/timezone, fresh-launch sign-in state; restricted account identifier only through approved admin procedure | Privacy/account owner immediately if completion is uncertain | Claim deletion failed/succeeded after a timeout; locally sign out and call it deletion; cancel Apple subscription for rider |
| Unsafe route | Stop following the route and move to a safe place | Mode, endpoints, ordered stops, road/segment, direction, access/signage/surface observed, online/offline, request ID, screenshots | Routing owner; P1/P0 incident commander when current rider safety or broad exposure is involved | Tell the rider to continue, silently alter frozen routing, rebuild packs from a support case |
| Private/prohibited access | Do not enter; choose a legal alternate road | Same route evidence plus gate/sign/private-road evidence and approximate timestamp | Routing/data owner | Treat absence of a map tag as permission to enter |
| Missing, closed, or incorrect fuel | Do not rely on the listed station; use a confirmed alternative before range becomes critical | Station name/location, open/closed/missing/duplicate, route-fuel stop versus map-layer pin, catalog/pack region, request ID | Fuel/data owner; routing owner if automatic fuel planning used it | Edit the frozen route graph; conflate a layer-only display defect with route-fuel proof |
| Missing campground, lodging, or liquor | Explain that these are Rider Services layers, separate from route activation | Category, viewport/place, online/offline, whether region data finished downloading, screenshot | Rider Services/data owner | Block navigation, rebuild a road pack, or query public OSM at runtime |
| Group privacy or stale sharing | Stop sharing; if uncertain close DIRT and disable Location permission temporarily | Group role, affected action, time/timezone, expected versus visible state; no invite code or peer coordinates in general support | Privacy owner and incident commander; treat suspected cross-group/cross-account visibility as P0 | Ask for another rider's live location; re-share merely to reproduce |
| Sign in with Apple | Retry after network recovery; explicit Apple cancellation is not an error | Error text, time, app build, Apple system status; whether this is first authorization | Auth owner | Ask for password, verification code, identity token, or authorization code |
| Map blank/tiles unavailable | Confirm network and retry; downloaded routing data and visual basemap are different systems | Location region, zoom, online/offline, screenshot, Shortbread health result | Map/edge owner | Diagnose a blank basemap as a routing-pack rebuild automatically |

## Billing decision tree

- Product or price does not load: record the displayed state and App Store
  storefront; check Apple service status and the exact App Store Connect product
  configuration. Do not substitute the local `Dirt.storekit` catalogue.
- Purchase cancelled: no entitlement should be promised; cancellation itself
  is not a technical failure.
- Purchase pending: explain that access changes only after StoreKit verifies the
  transaction.
- Restore says no entitlement: confirm the purchasing Apple account and current
  entitlement state. Distinguish this from a StoreKit/network error.
- Refund request: direct the rider to Apple's refund process. DIRT support may
  explain product behavior but must not claim it has issued an Apple refund.

## Account-deletion decision tree

- Confirmed success: remind the rider separately to manage/cancel an Apple
  subscription and, if desired, revoke DIRT in Sign in with Apple settings.
- Explicit server error: keep sharing stopped; escalate with timestamp and safe
  identifier. The rider may retry after support confirms service health.
- Timeout or lost response: state that completion is unknown. On fresh launch,
  use the observed signed-in state as evidence, not proof of database cleanup.
  Escalate for the approved server-side verification path.
- Suspected wrong-account deletion or retained cross-account data: declare P0,
  preserve evidence, and stop release progression.

## Engineering handoff

Every handoff contains:

```text
Support case ID and severity:
DIRT version (build), environment, device/iOS:
UTC and rider timezone:
Capability and expected/observed result:
Minimal reproduction:
Network state:
DIRT/Supabase request ID if available:
Region/catalog identity if relevant:
Attachments and rider consent for precise location:
Immediate rider-safety/privacy instruction already given:
```

Route the handoff by failure domain. Do not send a rider-data case to a public
issue tracker. Engineering returns the confirmed cause, rider-facing workaround,
affected versions/regions, recovery identity, and next-update time to support.

## Closure

A case closes only when the rider-facing outcome is recorded: resolved,
workaround accepted, duplicate of a tracked incident, unable to reproduce after
specified checks, or awaiting a named external provider. For privacy, deletion,
or safety issues, support must not use “resolved” until the accountable owner
confirms the relevant state.
