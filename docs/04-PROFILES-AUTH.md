# DIRT iOS — Profiles & Auth

**Sign in with Apple is the only account path on iOS**, and it is a hard gate — the map never loads until there is an authenticated account with a screen name. A delayed 7-day trial paywall escalates on top of the map after signed-in usage. Spec: [WEB-SPEC-FOR-IOS.md](./WEB-SPEC-FOR-IOS.md) §4 Auth. Groups depend on this: [03-GROUPS.md](./03-GROUPS.md).

> The email-OTP methods still live in `SupabaseService` (`sendEmailCode` / `verifyEmailCode`) as a backend fallback, but there is **no OTP UI** on iOS. All user-facing sign-in is Apple-only.

---

## Onboarding gate

`Dirt/App/AppGateView.swift` is the root view and routes on every launch:

```
bootstrap (SplashView)
    └─ !signed in                → OnboardingView         (Sign in with Apple)
       signed in, no screen name → DisplayNameSetupView   (pick screen name)
       signed in, has name       → RootView               (the map)
```

`BuildChannel.showsTesterUnlock` (Debug always; Release/TestFlight while `allowPreReleaseTesterUnlock == true`) surfaces **Continue as tester** on `OnboardingView`, skip-paywall on the trial sheet, and Profile toggles. Flip `BuildChannel.allowPreReleaseTesterUnlock` to `false` before public App Store freeze — persisted unlocks clear on the next launch.

---

## Key files

| File | Role |
| --- | --- |
| `Dirt/App/AppGateView.swift` | Root router: bootstrap → Apple → screen name → map |
| `Dirt/Features/Onboarding/OnboardingView.swift` | Signed-out hero + Sign in with Apple |
| `Dirt/Features/Onboarding/DisplayNameSetupView.swift` | One-time screen name capture |
| `Dirt/Features/Auth/AppleSignInButton.swift` | `SignInWithAppleButton` + nonce helper |
| `Dirt/Persistence/SupabaseService.swift` | Bootstrap, Apple id-token sign-in, session, profile upsert |
| `Dirt/Features/Profile/ProfileSheet.swift` | Account, subscription, legal links |
| `Dirt/Features/Subscription/SubscriptionService.swift` | StoreKit 2 (7-day trial, $10/mo, $45/yr) |
| `Dirt/Features/Subscription/TrialGateModel.swift` | Usage clock + trial escalation |
| `Dirt/Features/Subscription/PaywallView.swift` | Soft/hard trial offer |
| `Dirt/Dirt.entitlements` | `com.apple.developer.applesignin` |
| `Dirt/Dirt.storekit` | Local StoreKit config (attached in the Dirt scheme) |
| `Dirt/Networking/LegalLinks.swift` | Website / privacy / terms URLs (placeholder domain) |

---

## Bootstrap

On launch, `SupabaseService.bootstrap()`:

1. `GET https://dirt-mayday.vercel.app/api/supabase-config`
2. Expects `{ url, publishableKey }`
3. Builds `SupabaseClient(supabaseURL:key:)`
4. Loads existing `client.auth.session` if present
5. Subscribes to `authStateChanges` and mirrors into `userID` / `email` / `displayName`

No anon/publishable key is baked into the binary beyond what production already exposes via that endpoint.

Default project URL (web repo / spec): `https://iiiguqknqxoumlmppzfw.supabase.co` — always prefer the config endpoint over hardcoding.

`bootstrapError` surfaces in the Profile sheet if config fetch fails.

---

## Session / Keychain

Sessions are persisted by the **Supabase Swift SDK’s default secure storage** (Keychain). There is no custom Keychain wrapper in app code.

`isSignedIn` ≡ `userID != nil`.

`userID` is `session.user.id.uuidString.lowercased()`.

Display name is read from `session.user.userMetadata["display_name"]` when present.

---

## Sign in with Apple flow

| Step | API | UI |
| --- | --- | --- |
| 1 | `AppleNonce.random()` → `request.nonce = sha256(nonce)`, `requestedScopes = [.fullName]` | `SignInWithAppleButton(.continue)` |
| 2 | Apple returns `identityToken` (+ `fullName` on first authorization only) | — |
| 3 | `client.auth.signInWithIdToken(.init(provider: .apple, idToken:, nonce: rawNonce))` | Spinner |
| 4 | If no display name yet and Apple returned a name, seed it via `updateDisplayName` | — |
| 5 | If still no screen name → `DisplayNameSetupView` | Screen name entry (2–24 chars) |

**Nonce:** the raw nonce goes to Supabase; its SHA-256 goes to Apple. Supabase verifies the raw value against the JWT.

**Backend prerequisite (dashboard, not code):** enable Authentication → Providers → **Apple** in Supabase with **Client IDs** including the iOS bundle id `com.mayday.dirt`. You also need a Services ID / key from Apple Developer (Sign in with Apple). Until that works end-to-end, use **Continue as tester** (`BuildChannel.allowPreReleaseTesterUnlock`). On failure, the onboarding screen now shows the underlying API error instead of a generic retry string.

Primary CTAs use brand orange (not nav green) — see [06-UI-DESIGN.md](./06-UI-DESIGN.md).

---

## Subscription & delayed trial

**DIRT PRO** — 7-day free trial, then **$10/month** or **$45/year** (`com.mayday.dirt.pro.monthly` / `.pro.yearly`). StoreKit 2 via `SubscriptionService`; App Store Connect products required for production, `Dirt.storekit` for local testing.

The trial paywall is **not** shown at sign-in. `TrialGateModel` counts cumulative **map-foreground seconds** (persisted on-device, `dirt_trial_*_v1`) and escalates:

| # | Trigger | Dismissible |
| --- | --- | --- |
| 1 | 90s of map use | Yes (X / "Maybe later") |
| 2 | next launch, **or** +5 min cumulative | Yes |
| 3 | 3rd exposure (≈+5 min after #2) **or** 15 min cumulative — whichever first | **No — must start trial** |

- Time accrues during navigation, but the gate **never interrupts an active ride** (`tick(canPresent: !navActive)`); it waits for idle.
- A live subscription clears everything (`markSubscribed()` / `isSubscribed`).
- On-device persistence means a reinstall resets the clock (accepted trade-off).
- DEBUG: Profile → "Reset trial usage clock" (`resetForTesting()`).

---

## Profile sheet (signed in)

| Section | Contents |
| --- | --- |
| Account | Apple ID email · edit screen name → "Save screen name" · Sign out |
| DIRT PRO | Status (Active / Not subscribed) · Manage subscription (`.manageSubscriptionsSheet`) **or** Start 7-day free trial (opens `PaywallView`) · Restore purchases |
| About | dirtmoto.app · Privacy policy · Terms of use (all `Link`) |
| Debug (`#if DEBUG`) | Reset trial usage clock |

Name persist: `auth.update(user: data display_name)` then upsert `profiles { id, display_name, updated_at }`. Trimmed, max **60** chars (setup step enforces 2–24). Toast "Profile updated" via `planner.toast`.

---

## Built vs web parity gaps

| Item | iOS | Web |
| --- | --- | --- |
| Sign in with Apple (gate before map) | Yes | No (web is email OTP) |
| Email OTP UI | Removed (service methods retained) | Yes |
| Session restore | Yes (SDK) | Yes |
| Display name → auth metadata + `profiles` | Yes | Yes |
| Sign out | Yes | Yes |
| 7-day trial + StoreKit subscription | Yes | No |
| Manage subscription / legal links | Yes | Partial |
| Account deletion | No | No |

---

## Starting a new agent on this area

1. Read `AppGateView.swift`, `SupabaseService.swift`, then `ProfileSheet.swift` and the `Features/Subscription/` trio.
2. Confirm profile upsert shape against [WEB-SPEC-FOR-IOS.md](./WEB-SPEC-FOR-IOS.md) §4.
3. **Invariants:** fetch config from production endpoint; never ship a service-role key; the map stays gated behind Apple auth + screen name; the trial gate never interrupts active navigation; usage clock is on-device only; product IDs are `com.mayday.dirt.pro.{monthly,yearly}`.
4. **External setup still required (not code):** enable Apple provider in Supabase; create the two subscription products in App Store Connect with a 7-day free-trial intro offer; register the real `dirtmoto.app` domain + reachable privacy/terms URLs before App Store review.
5. **Open questions:** account deletion for App Store review; whether to show trial vs paid distinctly in Profile status.
