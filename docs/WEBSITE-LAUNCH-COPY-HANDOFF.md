# DIRT website — prelaunch copy handoff

**Status:** exact, code-backed corrections required before public App Store
submission. The website lives in a separate repository at
`/Users/richardsmith/SandBox01/MAYDAY-HTML/Untitled`; this iOS release does not
deploy or silently mutate that external production surface.

These changes are factual alignment, not a visual redesign. Keep the email
support path as a fallback after adding the in-app path.

## `subscriptions/index.html`

Replace the current **What Pro unlocks** paragraph with:

> Route planning and saving routes on your device are free. DIRT PRO unlocks
> GPX export and unlimited Start Navigation. Two free navigation starts are
> included on the device before an active subscription is required.

Do not promise a free trial in static website copy unless App Store Connect is
configured for that offer. Apple determines introductory-offer eligibility,
and the app displays an offer only when StoreKit confirms it for that customer.

## `terms/index.html`

Replace the three opening **Subscriptions & freemium** bullets with:

- You may plan routes and save them on your device without a subscription.
- GPX export requires DIRT PRO.
- Two free Start Navigation uses are included on the device; DIRT PRO is
  required for additional navigation starts.

Keep the Apple billing, cancellation, refund, price, and restore language.

## `support/index.html`

Replace the current **Account deletion** paragraph with:

> In DIRT, open Profile, open the account section, and choose Delete account.
> The app asks for confirmation and reports whether server deletion succeeds.
> Deleting a DIRT account does not cancel an App Store subscription; manage or
> cancel that separately in iOS Settings → Apple ID → Subscriptions. If you
> cannot access the app, email info@dirtmoto.app with subject “Delete my DIRT
> account” from the address associated with the account.

Do not publish this replacement until the versioned `delete_own_account()`
migration in `supabase/migrations/` has been applied and verified against the
production schema.

## `privacy/index.html`

Expand **What we collect** so it explicitly covers the code-backed cloud data:

- Supabase user identifier, email supplied by Sign in with Apple, and display
  name;
- deliberate Group live-location sharing, rider status, and alerts;
- group name, membership, role, and invite code;
- route incidents submitted by the rider; and
- edge sequences and ride timing submitted only when track contribution is
  enabled.

Replace the deletion sentence only after the production migration is live:

> Delete your account from the account section in Profile. DIRT submits an
> authenticated server-side deletion request and reports failure rather than
> representing sign-out as deletion. Email info@dirtmoto.app if you cannot use
> the in-app flow. App Store subscriptions are managed separately by Apple.

Before publication, the owner must set the real retention/anonymization policy
for presence, alerts, incidents, contributions, and backups; do not invent a
retention period in copy.

## `data/index.html`

Add these plain-language bullets:

- Group features store account, membership, deliberate live-location, status,
  and alert data in Supabase so a private riding group can function.
- Incident reports and opt-in track contributions may be sent to DIRT to
  improve route safety and quality.
- Account deletion is available in the app after production deletion support
  is enabled; deleting the account does not cancel an Apple subscription.

## Publish gate

Before deploying the website, verify all five statements together:

1. Local Save is free in the exact public Release build.
2. GPX Export is subscription-gated.
3. Start Navigation grants exactly two free starts, then gates.
4. StoreKit—not hard-coded copy—controls offer eligibility and displayed price.
5. The production Supabase deletion RPC was applied and its fail-closed test
   matrix passed.
