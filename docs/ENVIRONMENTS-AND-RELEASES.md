# DIRT environments and release flow

Status: active; hosted development isolation established 2026-09-04.

## Decision

DIRT uses three operational lanes and two hosted backends:

| Lane | App build | Supabase | Routing / tiles / packs | Data |
| --- | --- | --- | --- | --- |
| Local / CI | Unit tests and simulator | Local Supabase | Fixtures and local server tests | Synthetic, resettable |
| Development / QA | `Dirt Dev` Debug or internal Release | Separate `dirt-mayday-dev` project | Stable development Vercel URL and development R2 manifest | Synthetic test accounts only |
| Production | App Store `Dirt` Release | Current `dirt-mayday` project | Production Vercel URL and promoted immutable R2 manifest | Real riders |

Supabase Branching is not the launch path. The current organization is on the
Free plan, while persistent branches require Pro. A separate development
project is simpler, long-lived, independently authenticated, and currently
quoted by Supabase at $0/month.

## Hosted Supabase projects

| Environment | Project | Project reference | Region | Data policy |
| --- | --- | --- | --- | --- |
| Development / QA | `dirt-mayday-dev` | `xoufaiypnrgukzmdwicz` | Canada Central | Synthetic and disposable only |
| Production | `dirt-mayday` | `iiiguqknqxoumlmppzfw` | Canada Central | Real riders |

The development project is healthy and was initialized from production's full
12-version baseline with zero Auth users and zero application rows; no
production rider data was copied. It now carries two additional, versioned RLS
hardening migrations under acceptance. Production intentionally remains on the
12-version baseline until those changes pass device Auth and Groups testing.

## Non-negotiable boundaries

- Debug and ordinary device-development builds never write to production.
- Production data is never copied to development; use deterministic seed data.
- Database changes are migrations. Do not edit production first in Studio.
- A migration runs locally, then on development, then on production only after
  automated and multi-account acceptance passes.
- Development and production have different project URLs, publishable keys,
  Auth redirect URLs, users, secrets, API domains, and pack manifests.
- Service-role keys, database passwords, Apple private keys, and deployment
  tokens never enter either mobile app or source control.
- iOS and Android select the same named environment and backend contract.

## Build identities

| Build | Bundle / application ID | Visible name | Backend |
| --- | --- | --- | --- |
| iOS development | `com.mayday.dirt.dev` | `DIRT Dev` | Development / QA |
| Android development | `com.mayday.dirt.dev` | `DIRT Dev` | Development / QA |
| iOS production | `com.mayday.dirt` | `DIRT` | Production |
| Android production | `com.mayday.dirt` | `DIRT` | Production |

The iOS development target requires its own Sign in with Apple configuration.
Android development requires matching Google OAuth configuration. Production
credentials are not reused as a shortcut.

## Configuration contract

Endpoints must come from build configuration, not mutable user defaults or a
runtime switch. A public Release build fails its release check unless all
production identifiers match an allowlist. A development build displays a
persistent, unmistakable `DEV` marker and cannot be archived as the App Store
product.

Required values:

- environment name and build identity;
- Supabase URL and publishable key;
- routing API base URL and routing contract;
- Shortbread manifest URL;
- pack CDN base URL and manifest URL; and
- public legal/support URLs where environment-specific testing is required.

Publishable Supabase keys may ship in clients; privileged secrets may not.

## Promotion flow

1. Create a feature branch and migration.
2. Reset and replay the complete migration chain locally.
3. Run unit, API-contract, RLS, and migration tests with synthetic users.
4. Merge to the development branch and deploy to development Supabase/Vercel/R2.
5. Install `DIRT Dev` on devices; run route, Auth, Groups, subscription sandbox,
   offline, and failure-path acceptance.
6. Freeze the candidate commit and immutable pack release IDs.
7. Promote the exact migration and server commit to production.
8. Build the App Store Release from that same commit and verify its embedded
   environment identity before TestFlight/App Store submission.
9. Record commit, database migration versions, Vercel deployment, R2 manifest,
   app build number, and acceptance evidence together.

Never rebuild an artifact during promotion. Promote the tested bytes.

## Immediate setup sequence

1. Recovered production's complete Supabase migration history into source.
2. Created the separate hosted development Supabase project.
3. Replayed and verified all migrations there without copying production data.
4. Added build-time iOS Supabase selection and the `DIRT Dev` identity.
5. Recorded Android's matching compile-time Supabase isolation contract.
6. Applied and database-tested the first RLS/grant hardening candidate only in development.
7. Create a stable development Vercel deployment and development R2 manifest.
8. Seed disposable development test users/data after Auth providers are configured.
9. Added deterministic bundle-verification scripts that reject production
   Supabase identity in development and development identity/tester unlocks in
   production; wire these scripts into hosted CI when that pipeline is created.
