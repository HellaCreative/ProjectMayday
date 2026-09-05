# DIRT iOS — Profiles, Auth & DIRT PRO

**Sign in with Apple is the only user-facing account path on iOS.** An account
is not required to reach the map, plan routes, or save a route locally. Sign-in
is offered in Profile and required when a rider opens Groups, where stable
identity is necessary for membership and live sharing. Groups details:
[03-GROUPS.md](./03-GROUPS.md).

> The email-OTP methods still live in `SupabaseService`
> (`sendEmailCode` / `verifyEmailCode`) as a backend fallback, but there is no
> email-OTP UI on iOS.

---

## Launch flow

`Dirt/App/AppGateView.swift` is the root view:

```
splash + service bootstrap
    → intro carousel (Skip available)
    → RootView / map
```

Supabase restores a session during bootstrap when one exists, but neither a
session nor a screen name gates the map. The intro carousel appears on each cold
launch; its returning-rider state changes the presentation, not map access.

Tester controls are compile-time restricted. `BuildChannel.showsTesterUnlock`
is true in Debug or when a deliberately configured pre-release target includes
the `DIRT_PRE_RELEASE_TESTER_UNLOCK` compilation condition. A normal public
Release build has no tester escape hatch; persisted tester preferences are
ignored and cleared outside those builds.

---

## Key files

| File | Role |
| --- | --- |
| `Dirt/App/AppGateView.swift` | Splash/bootstrap → intro → map; no auth gate |
| `Dirt/App/BuildChannel.swift` | Compile-time tester-control policy |
| `Dirt/Features/Auth/AppleSignInButton.swift` | `SignInWithAppleButton`, nonce helper, shared failure presentation |
| `Dirt/Persistence/SupabaseService.swift` | Bootstrap, Apple id-token sign-in, session, profile upsert, account-deletion RPC |
| `Dirt/Features/Groups/GroupsSheet.swift` | Contextual Sign in with Apple requirement for Groups |
| `Dirt/Features/Profile/ProfileSheet.swift` | Optional account sign-in, profile, deletion, DIRT PRO, legal links |
| `Dirt/Features/Subscription/SubscriptionService.swift` | StoreKit 2 products, offers, entitlement, purchase, and restore outcomes |
| `Dirt/Features/Subscription/TrialGateModel.swift` | Free-feature and two-free-Start policy |
| `Dirt/Features/Subscription/PaywallView.swift` | Dismissible StoreKit-backed DIRT PRO offer |
| `Dirt/Dirt.entitlements` | `com.apple.developer.applesignin` |
| `Dirt/Dirt.storekit` | Local StoreKit test configuration attached only to `DIRT Dev` |
| `Dirt/Networking/LegalLinks.swift` | Website, privacy, terms, and subscription-management URLs |
| `supabase/migrations/20260904113053_delete_own_account.sql` | Versioned fail-closed deletion contract; deployed in production 2026-09-04 |

---

## Bootstrap and session

On launch, `SupabaseService.bootstrap()`:

1. Builds `SupabaseClient` from `AppConfig.supabaseURL` and the public
   publishable/anonymous key.
2. Loads `client.auth.session` when present.
3. Subscribes to `authStateChanges` and mirrors the session into `userID`,
   `email`, and `displayName`.

Sessions use the Supabase Swift SDK's default secure storage. `isSignedIn` is
equivalent to `userID != nil`; IDs are normalized lowercase UUID strings.
Display name is read from `session.user.userMetadata["display_name"]`.

Never place a Supabase service-role key in the app.

---

## Sign in with Apple

| Step | API / behavior |
| --- | --- |
| 1 | `AppleNonce.random()`; SHA-256 nonce goes to Apple |
| 2 | Apple returns an identity token and, on first authorization, possibly a full name |
| 3 | Raw nonce and identity token go to `client.auth.signInWithIdToken(provider: .apple, ...)` |
| 4 | If Apple supplied a name and the account has none, DIRT seeds the display name |
| 5 | Profile can update auth metadata plus the matching `profiles` row |

Every active Sign in with Apple entry point surfaces a real failure and treats
an explicit Apple cancellation as silent. Groups and Profile must never swallow
an authentication error.

Backend prerequisite: enable the Apple provider in Supabase with client IDs
including `com.mayday.dirt`, and configure the corresponding Apple Services ID,
key, and redirect details. Validate this end to end in a distribution build.

The current native flow sends an Apple identity token to Supabase but does not
exchange Apple's short-lived authorization code for a server-held refresh
token. Until the server-side token exchange and `/auth/revoke` path are deployed,
successful deletion instructs the rider to revoke DIRT manually in Apple
Account settings. Apple credentials and the signing private key must never be
stored in the app.

---

## Account deletion

Profile exposes **Delete account** for signed-in riders. The app calls only the
versioned `delete_own_account()` RPC. That function accepts no user ID, derives
the target from `auth.uid()`, and is intended to remove the Auth user plus DIRT
account data atomically. If the RPC response fails or times out, the app states
that completion could not be confirmed. It does not claim rollback because a
response can be lost after a committed server transaction. Live group sharing
remains stopped until the rider's account state is re-established.

The migration is source-controlled and was applied to production on 2026-09-04.
Its definition, grants, and foreign-key compatibility were checked against the
live schema. Destructive testing with a disposable account remains required.
The verification matrix is in
[`../supabase/README.md`](../supabase/README.md).

Deleting a DIRT account does not cancel an App Store subscription. The
confirmation says this explicitly so the rider can manage the subscription
through Apple separately.

---

## DIRT PRO access policy

There is no time-based or map-time trial ladder.

| Rider action | Free access |
| --- | --- |
| Reach map and plan routes | Yes |
| Save a route locally | Yes |
| Export GPX | No; presents a dismissible DIRT PRO paywall |
| Start navigation | First two successful ride starts are free; later Starts present the paywall |

The free-Start count is stored in Keychain and is consumed only when navigation
actually leaves preparation and begins the live ride. Subscribers do not
consume it. The current gate uses the dismissible `.soft` presentation; the
`.hard` paywall shell remains in the view type but is not used by the gate.

StoreKit product identifiers are:

- `com.mayday.dirt.pro.monthly`
- `com.mayday.dirt.pro.yearly`

Localized prices, billing periods, free-trial duration, and offer eligibility
come from StoreKit at runtime. Do not hard-code a price or promise a seven-day
trial in app copy or documentation. `Dirt.storekit` is only the local test
configuration; App Store Connect remains the production source of truth.

Use the **DIRT Dev** Xcode scheme for local subscription testing. It runs the
Debug app (`com.mayday.dirt.dev`) and attaches `Dirt.storekit`. Use **DIRT
Production** for release validation and archives; it runs the Release app
(`com.mayday.dirt`) without a local catalogue or tester controls. No ambiguous
generic scheme is retained.

Purchase, pending approval, cancellation, verification failure, and restore
failure are distinct outcomes. Restore must never say “No purchases found” when
the App Store sync itself failed.

A verified, recognized, non-revoked StoreKit transaction grants DIRT PRO in the
app immediately, before the transaction is finished. Launch, restore, and
transaction-update reconciliation still scan current entitlements so expiration,
refund, revocation, upgrade, and cross-device changes converge correctly. Turning
off renewal does not revoke an already-paid or trial entitlement; access remains
active until StoreKit reports its expiration or revocation. Diagnostics record
product IDs and outcome state, but never transaction IDs, receipts, or account
tokens.

---

## Profile screen

Profile owns the full display in both orientations. The map, dock, and map
controls remain behind the modal and are not interactive until the rider uses
the explicit **Close** control. The content column is capped on wide displays so
account and preference controls remain readable rather than stretching across
the screen.

| State / section | Contents |
| --- | --- |
| Signed out | Optional Sign in with Apple |
| Signed in | Apple email when available, editable screen name, Sign out, Delete account |
| DIRT PRO | Entitlement status, View DIRT PRO or Manage, Restore purchases |
| About | Website, privacy policy, and terms links |
| Pre-release tester tools | Visible only when `BuildChannel.showsTesterUnlock` is true |

Name persistence updates auth `display_name` metadata and upserts the `profiles`
row. The service trims input and caps it at 60 characters.

---

## Current release surface

| Item | iOS state |
| --- | --- |
| Signed-out map and route planning | Yes |
| Sign in with Apple in Profile and Groups | Yes |
| Email OTP UI | No; service methods retained |
| Session restore | Yes, Supabase SDK |
| Display name → auth metadata + `profiles` | Yes |
| Local route Save without DIRT PRO | Yes |
| GPX export gate | Yes |
| Two free navigation Starts, then DIRT PRO gate | Yes |
| StoreKit-derived price and introductory offer | Yes |
| Manage subscription and restore | Yes |
| Public Release tester unlock | No |
| Account-deletion UI and client contract | Yes |
| Account-deletion RPC applied and metadata-verified in production | Yes — destructive disposable-account test pending |

---

## Starting a new agent on this area

1. Read `AppGateView.swift`, `BuildChannel.swift`, `SupabaseService.swift`,
   `ProfileSheet.swift`, and the three files under `Features/Subscription/`.
2. Keep these invariants: map access is signed-out; Groups requires identity;
   local Save is free; GPX is gated; Start has two free completed entries into
   navigation; StoreKit owns price/offer copy; public Release has no tester
   unlock; the app never contains a service-role key.
3. Before release, validate Apple sign-in, purchase, pending Ask to Buy,
   cancellation, restore, expired/revoked entitlement, and account deletion on
   real distribution builds and test accounts.
4. External work still required: test Apple auth and account deletion with a
   disposable distribution account; create and review the two products and any
   introductory offers in App Store Connect; finish and version the live
   RLS/Realtime hardening; confirm production website, privacy, terms, and
   support URLs.
