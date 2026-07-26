# DIRT iOS — Profiles & Auth

Email OTP account flow and display-name profile, matching the web POC. Spec: [WEB-SPEC-FOR-IOS.md](./WEB-SPEC-FOR-IOS.md) §4 Auth. Groups depend on this: [03-GROUPS.md](./03-GROUPS.md).

---

## Key files

| File | Role |
| --- | --- |
| `Dirt/Persistence/SupabaseService.swift` | Bootstrap, OTP, session, profile upsert |
| `Dirt/Features/Profile/ProfileSheet.swift` | UI states |
| `Dirt/Networking/AppConfig.swift` | `supabaseConfigURL` |
| `Dirt/App/RootView.swift` | `.task { await app.supabase.bootstrap() }` |

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

## Email OTP flow

Matches web:

| Step | API | UI |
| --- | --- | --- |
| 1 | `signInWithOTP(email, shouldCreateUser: true, data: display_name)` | Email + optional display name → “Email me a code” |
| 2 | — | “Check your email” + 6-digit field |
| 3 | `verifyOTP(email, token, type: .email)` | “Verify code” |
| 4 | Optional `updateDisplayName` if name field non-empty | After verify |
| Resend | Same send path | **60s** cooldown (`resendAvailableAt`) |
| Escape | — | “Use a different email” resets to step 1 |

Primary CTAs use brand orange (not nav green) — see [06-UI-DESIGN.md](./06-UI-DESIGN.md).

---

## Signed-in profile

| Action | Implementation |
| --- | --- |
| Show email | `supabase.email` |
| Edit display name | Text field → “Save display name” |
| Persist name | `auth.update(user: data display_name)` then upsert `profiles { id, display_name, updated_at }` |
| Name length | Trimmed, max **60** chars |
| Sign out | `auth.signOut()` |

Toast “Profile updated” via `planner.toast` on success.

---

## Auth states (UI)

```
bootstrapError?
    └─ message in sheet

!isSignedIn && !codeSent  → email entry
!isSignedIn && codeSent   → code entry
isSignedIn                → account + save name + sign out
```

Groups sheet mirrors the gate with a dedicated “Riding groups need an account” empty state (does not embed the OTP form — user switches to Profile tab).

---

## Built vs web parity gaps

| Item | iOS | Web |
| --- | --- | --- |
| Email OTP + resend cooldown | Yes | Yes |
| Session restore | Yes (SDK) | Yes |
| Display name → auth metadata + `profiles` | Yes | Yes |
| Sign out | Yes | Yes |
| Avatar / photo | No | No (neither) |
| Magic link deep link into app | Not wired — code entry only | Email link / code UX on web |
| Account deletion | No | No |
| Phone auth | No | No |

---

## Starting a new agent on this area

1. Read `SupabaseService.swift`, then `ProfileSheet.swift`.
2. Confirm OTP types and profile upsert shape against [WEB-SPEC-FOR-IOS.md](./WEB-SPEC-FOR-IOS.md) §4.
3. **Invariants:** fetch config from production endpoint; never ship a service-role key; Clean/groups still require real session; keep 60s resend cooldown; display_name max 60.
4. **Open questions:** universal links for email magic-link verify; whether Groups should deep-link into Profile sheet; account deletion requirements for App Store review.
