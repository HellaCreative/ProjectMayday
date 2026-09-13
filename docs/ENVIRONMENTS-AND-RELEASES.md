# DIRT environments and release flow

Status: active; hosted development isolation established 2026-09-04 and
automated security evidence reconciled 2026-09-05.

## Decision

DIRT separates local testing, development, and production. This document governs
non-routing environment isolation, account data, secrets, and database/release
operations. Routing architecture, source selection, pack delivery, qualification,
and routing promotion are defined only in [the routing source of truth](ROUTING-SOURCE-OF-TRUTH.md).

The hosted names below are an inventory of existing integrations, not a rule
requiring the routing candidate to execute on a hosted service:

| Lane | App build | Supabase | Existing hosted integrations | Data |
| --- | --- | --- | --- | --- |
| Local / CI | Unit tests and simulator | Local Supabase | Fixtures and local server tests | Synthetic, resettable |
| Development / QA | `Dirt Dev` Debug or internal Release | Separate `dirt-mayday-dev` project | `pack-fabric.vercel.app`; routing/pack policy is in the sole routing authority | Synthetic test accounts only |
| Production | App Store `Dirt` Release | Current `dirt-mayday` project | Existing production Vercel and R2 services | Real riders |

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
production rider data was copied. It now carries three additional versioned
migrations under acceptance: rider-status expansion plus two authorization/RLS
hardening migrations. Production intentionally remains on the 12-version
baseline until those changes pass real client/device Auth and Groups testing.

Rollback-only synthetic development matrices now pass for three-user/two-group
RLS and private Realtime isolation, deleted-Group access loss, account-deletion
cascades, Auth-session removal, cross-account isolation, and forced-failure
atomicity, with zero retained rows. This is automated database evidence; it is
not a production promotion or a substitute for hosted multi-account app tests.

## Non-negotiable boundaries

- Debug and ordinary device-development builds never write to production.
- Production data is never copied to development; use deterministic seed data.
- Database changes are migrations. Do not edit production first in Studio.
- A migration runs locally, then on development, then on production only after
  automated and multi-account acceptance passes.
- Development and production have different project URLs, publishable keys,
  Auth redirect URLs, users, secrets, and API domains.
- Map and routing artifact identity, delivery, isolation, and publication are
  defined only in [the routing source of truth](ROUTING-SOURCE-OF-TRUTH.md).
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
- routing configuration as specified by [the routing source of truth](ROUTING-SOURCE-OF-TRUTH.md);
- rider-services `/api/poi` URL derived from that same environment base;
- Shortbread manifest URL;
- map-delivery configuration and routing-pack configuration as specified by their respective authorities; and
- public legal/support URLs where environment-specific testing is required.

Publishable Supabase keys may ship in clients; privileged secrets may not.

## Existing hosted-service inventory

| Environment | Project | Existing URL | Scope |
| --- | --- | --- | --- |
| Development / QA | `pack-fabric` | `https://pack-fabric.vercel.app` | Existing hosted implementation |
| Production | `dirt-mayday` | `https://dirt-mayday.vercel.app` | Existing hosted implementation |

The following dated Rider Services receipt is historical acceptance evidence,
not the current routing implementation or its qualification.

Rider Services source `9808936c1cdad627c1b55c2cb3ca23925345ee7d`
was deployed on 2026-09-05 as development deployment
`dpl_AGi1sxNXx73B8RMdjLYmDjST9KM5` and production deployment
`dpl_fqgrapEVk7knc2Ft67MhjvkUgj34`. Both stable URLs passed packed-data health,
Porters Lake campground/liquor, cache-source, and canonical fuel smoke checks.
Richard subsequently confirmed the DIRT Dev physical layer result, and the
accepted state is frozen in `docs/RIDER-SERVICES-FREEZE-2026-09-05.md`.

Promoted data identities for that acceptance are pack/fuel catalog
`9f11c79e6a103329d83184eb1d5b440ae70671529dfcdb0b17aa1533d8d46ff1`
and separate Rider Services catalog
`e17d1e485c986a0ebab994cd49e5637a44f6aa49fffdc19a6d6c1dbbc8117770`.
This dated receipt does not qualify the current route engine or select its road artifacts.

## Database and non-routing release flow

1. Preserve a reviewable source checkpoint and create a versioned migration for
   database changes.
2. Reset only the authorized disposable local database and replay its migration
   chain. Run unit, API-contract, RLS/private-Realtime, deletion/atomicity, and
   migration checks with synthetic users.
3. Apply the tested changes to the isolated development environment. Complete
   the relevant real-client Auth, Groups, subscription, and failure-path checks.
4. Record the accepted source and migration identities. Promote only the tested
   artifacts within the owner's current production authorization.
5. Build a mobile release when the change affects the client; verify its embedded
   environment identity before an authorized TestFlight/App Store submission.
   A server-only correction does not itself require another mobile build.
6. Record the applicable source, migration, deployment, mobile-build, and
   acceptance identities together. Promote tested artifacts without rebuilding
   them during promotion.

Routing acceptance and promotion are governed only by
[the routing source of truth](ROUTING-SOURCE-OF-TRUTH.md). This database workflow
does not require simultaneous native and hosted routing implementation or a
mobile archive for every routing-service correction. App Store submission and
public release remain separate owner-authorized actions.

## Immediate setup sequence

1. Recovered production's complete Supabase migration history into source.
2. Created the separate hosted development Supabase project.
3. Replayed and verified all migrations there without copying production data.
4. Added build-time iOS Supabase selection and the `DIRT Dev` identity.
5. Recorded Android's matching compile-time Supabase isolation contract.
6. Applied and rollback-tested the status/RLS/grant hardening candidates only in
   development; production promotion remains blocked on real client/device
   acceptance.
7. Created and smoke-tested the stable development Vercel deployment without
   changing the production service.
8. Consult [the routing source of truth](ROUTING-SOURCE-OF-TRUTH.md) for routing artifacts and
   release boundaries; this setup history does not set pack policy.
9. Seed disposable development test users/data after Auth providers are configured.
10. Added deterministic bundle/archive verification that rejects production
    Supabase identity in development and development identity/tester unlocks in
    production, plus read-only launch-health verification; wire these checks into
    hosted CI when that pipeline is created. Distribution signing and the
    documented MapLibre package blocker remain open.
