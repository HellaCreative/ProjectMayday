# Apple account deletion audit — September 10, 2026

Source checked: https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple

## Confirmed current behavior

SupabaseService.signInWithApple exchanges an identity token plus nonce for a Supabase session. None of the three callers forwards the Apple authorization code. SupabaseService.deleteAccount calls the atomic delete_own_account RPC and clears the local session. ProfileSheet directs the rider to revoke Apple access in Settings after successful deletion. The account deletion matrix passed in DEV earlier today.

## Important distinction

Apple TN3194 explicitly describes a manual fallback when no Apple refresh/access token or authorization code is available: delete app account data, direct the user to manually revoke access, and respond to credential revocation. Therefore absence of a stored Apple token must not prevent deletion or be represented as proof that the whole deletion feature is absent. Supabase session tokens are not Apple provider tokens and cannot be submitted to Apple's revoke endpoint.

Current code implements the first two fallback steps. Repository search found no credentialRevokedNotification observer or getCredentialState check. That is a concrete remaining implementation gap. Do not mark the account protection item complete.

## Next implementation

Add a lifecycle-owned Apple credential-state monitor, tied to the authenticated Apple subject and current session generation. On confirmed revocation/notFound, stop location sharing and clear local authentication through the existing sign-out cleanup. Handle network/transient errors without treating them as revocation. Check at appropriate foreground/session restoration points as well as notification delivery. Avoid signing out a newly established account due to a stale asynchronous callback. Verify the source and meaning of the Apple subject from the actual Supabase identity payload before wiring it.

Automatic revocation is a separate enhancement: securely capture/exchange Apple authorization codes on a server using the approved Apple client/key configuration, retain provider tokens privately, revoke through Apple and complete DIRT deletion. Never embed a Sign in with Apple private key in the app, confuse provider tokens with Supabase tokens, or block existing-account deletion because no provider token was historically retained.

## Required verification

Current Apple user; non-Apple session; revoked credential; transient lookup error; logout/login race; foreground restoration; location sharing shutdown; deletion rollback; no sensitive token logging. Device/system tests are needed for Apple credential-state behavior; mocks alone do not qualify it.

No code, signing keys, auth settings, uploads or submissions changed in this audit.

## Working-tree implementation follow-up
Implemented system credential-state lookup and revocation notification handling via SupabaseService and RootView. Uses the Supabase SDK's provider-specific Apple identity id, not the DIRT user UUID. Revoked/notFound results only affect the exact checked access-token session. Transient failures leave the session untouched. Group cleanup disables persisted opt-in and stops local sharing before sign-out. Six assertions against the actual extracted policy source passed (authorized, transferred, revoked, notFound, replaced token, missing session). Added AppleCredentialPolicyTests to the test target. Production compile and physical verification tracked separately; no archive/upload/submission.

Final unsigned DIRT Production Release build passed: /tmp/dirt-apple-revocation-final-build.log. No Xcode test-target execution is claimed: six standalone assertions used the actual policy source. Real device revocation remains pending.
