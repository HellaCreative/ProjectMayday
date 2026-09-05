# DIRT launch operations runbook

**Status:** operational baseline. This runbook is read-only by default and does
not authorize a deployment, database change, pack publication, account action,
or App Store release action.

## Purpose and boundaries

Use this runbook before TestFlight promotion, during the launch watch, and when
production appears unhealthy. It covers the production Supabase project, DIRT
Vercel services, immutable R2 catalogs, and the Shortbread edge service.

The accepted routing and Rider Services releases remain governed by their
freeze documents. A health failure is evidence to contain and investigate; it
is not permission to rebuild a graph, replace a catalog, change production, or
unfreeze routing.

## Named roles required for a launch window

Record people and contact methods in the private launch record; do not commit
personal phone numbers, credentials, or private email addresses here.

| Role | Owns | Must be named before release |
| --- | --- | --- |
| Release owner | Go/no-go, TestFlight/App Store actions, phased-release pause | Yes |
| Incident commander | Severity, timeline, handoffs, closure | Yes |
| Backend operator | Supabase and Vercel evidence; approved rollback execution | Yes |
| Pack/data operator | R2 catalog/object evidence; pack-owner escalation | Yes |
| Support owner | Rider acknowledgement, safe intake, status updates | Yes |

One person may hold multiple roles, but each role must have a named primary and
backup for the launch watch. If the incident commander is unavailable, the
release owner assumes that role.

## Dependency map

| Rider capability | Production dependency | Safe degraded behaviour |
| --- | --- | --- |
| Sign-in, Groups, deletion | Supabase `iiiguqknqxoumlmppzfw` | Signed-out map/planning remains; sharing must never be represented as live after an uncertain stop/delete |
| Online route and fuel planning | `dirt-mayday.vercel.app` reading promoted R2 packs | Installed regional packs support the documented offline path; do not silently change route data |
| Fuel map and Rider Services layers | Production DIRT APIs plus verified R2 sidecars | Previously verified regional files may display offline; missing optional Rider Services must not block navigation |
| Road/fuel downloads | Public R2 pack catalog and immutable objects | Existing activated packs remain; reject incomplete or checksum-mismatched downloads |
| Basemap | DIRT Shortbread Worker and R2 archive | Client health gate uses public Shortbread fallback |
| Purchases | Apple StoreKit/App Store | Preserve the last verified non-revoked entitlement; never invent a price, trial, purchase, or refund state |

## Read-only preflight

The verifier permits only HTTP `GET` and `HEAD`. It cannot deploy or write
data. Run the fast check from the repository root:

```sh
node scripts/verify-launch-health.mjs --environment production
```

For a release gate, provide the production **publishable** key through the
environment and reject any warning. Never use a Supabase service-role key:

```sh
DIRT_SUPABASE_PUBLISHABLE_KEY='<production publishable key>' \
  node scripts/verify-launch-health.mjs --environment production --strict
```

Before external TestFlight and App Store release, also confirm every advertised
R2 object exists with the catalogued byte count:

```sh
DIRT_SUPABASE_PUBLISHABLE_KEY='<production publishable key>' \
  node scripts/verify-launch-health.mjs --environment production --deep --strict
```

Save the output with the app version/build, source commit, Vercel deployment
IDs, database migration versions, pack catalog SHA-256, Rider Services catalog
SHA-256, operator, and UTC timestamp. A passing fast check proves endpoint and
catalog-contract health. A passing deep check adds object existence and size;
it does not replace checksum validation performed by publication and clients.

The gate fails when route/fuel endpoints cannot identify a committed source
build. `local-uncommitted` is not an acceptable production deployment identity,
even when an endpoint returns HTTP 200.

## Supabase backup and restore gate

Repository evidence does not prove that the hosted production project has a
current usable backup. The backend operator must capture these facts from the
Supabase dashboard or approved administrative tooling before release:

- active plan and the backup features it actually provides;
- most recent successful backup timestamp and retention window;
- database size and quota headroom;
- Auth, database, Realtime, egress, and storage quota/usage state;
- owner of quota and service-health alerts; and
- the documented location of the encrypted database credential and backup
  artifact (never the credential or artifact itself in this repository).

A restore is considered tested only when a backup is restored into an isolated,
disposable project or database, never over production, and these checks pass:

1. all source-controlled migrations are represented in the restored migration
   history;
2. schema objects, functions, grants, and Row Level Security policies match the
   expected release;
3. row counts reconcile by table without exporting rider content into the
   launch record;
4. synthetic owner/member/nonmember authorization checks pass; and
5. the disposable target is destroyed through the separately authorized admin
   process after evidence is retained.

If the current plan provides no usable managed backup, create an encrypted
logical backup using an approved private operator environment and rehearse its
restore to an isolated target. Connection strings and dumps must not enter shell
history, source control, shared chat, or app diagnostics. Until this evidence
exists, backup/restore readiness remains an open release gate.

## Launch sequence and watch

These are conservative defaults. The release owner may change them only by
recording the alternative before the stage begins.

| Stage | Minimum observation | Advance when | Stop when |
| --- | --- | --- | --- |
| Internal TestFlight | 24 hours | Preflight passes at start/end; required matrix has no P0/P1 | Any P0/P1 or unexplained dependency-health failure |
| External TestFlight | 48 hours | Same candidate; no P0/P1; support intake works | Any privacy boundary failure, data-loss signal, or repeated core-flow failure |
| App Store phased release | Use App Store Connect phased release | Preflight passes before each daily expansion | Any P0; two related P1 reports; or three consecutive failed five-minute health checks |
| Full release watch | First 24 hours after 100% | Named roles available; checks at start, +1h, +4h, +12h, +24h | Apply the incident thresholds below |

Do not advance based only on install/build success. Record Auth, Groups,
subscription, offline, route, fuel, layer, and account-deletion evidence from
the required TestFlight matrix.

## Severity and response targets

| Severity | Examples | Initial response | Release action |
| --- | --- | --- | --- |
| P0 critical | Cross-account data exposure; wrong backend environment; data loss; account deletion targets the wrong rider; widespread unsafe navigation | Acknowledge in 15 minutes; appoint incident commander; preserve evidence | Stop submission or pause phased release immediately; contain the affected service/feature through an explicitly approved action |
| P1 high | Sign-in broadly unavailable; Groups privacy/sharing state incorrect; route/fuel planning broadly unavailable; purchases broadly fail | Acknowledge in 30 minutes; run preflight twice five minutes apart; correlate request IDs | Hold expansion; roll back only when the previous artifact is known compatible |
| P2 medium | Reproducible regional route/data defect; one layer unavailable; individual deletion or billing failure without exposure | Acknowledge same business day; create a scoped defect and safe workaround | Continue only if the release owner records why rider safety/privacy is unaffected |
| P3 low | Cosmetic issue, copy problem, isolated non-blocking inconvenience | Triage into normal backlog | No automatic release action |

Any suspected privacy breach is P0 until disproven. A route that tells a rider
to enter an unsafe or prohibited road is at least P1 for that rider: advise them
to stop following the route and move to a safe place before gathering details.

## Incident procedure

1. **Protect the rider.** For safety or privacy reports, give the immediate
   containment instruction from the support runbook.
2. **Open one incident record.** Record UTC start, severity, incident commander,
   affected app build/environment/capability, and first reporter. Do not paste
   credentials, tokens, receipts, or unnecessary precise location.
3. **Preserve identity.** Capture `X-Dirt-Request-ID`, service build, deployment
   ID, catalog hashes, Supabase request ID/project ref, and timestamps. Never
   solve an identity mismatch by weakening the check.
4. **Reproduce read-only.** Run the fast verifier twice, five minutes apart. Use
   `--deep` only when the catalog/object path is implicated.
5. **Separate the failure domain.** Determine whether the failure is app-only,
   Vercel, Supabase, R2/catalog, Shortbread, Apple, or network-specific.
6. **Contain.** Pause release progression. Any external mutation or rider-data
   access needs the authorized operator and a written incident action.
7. **Recover.** Use the narrow rollback rule below. Never rebuild during an
   incident rollback.
8. **Verify.** Repeat preflight, then the exact failed user flow with synthetic
   data. Confirm the deployed build and data identities.
9. **Communicate.** Support updates P0 every 30 minutes, P1 hourly, and others
   when material facts change. State confirmed facts, current rider action, and
   next update time.
10. **Close.** Record end time, cause, affected window, recovery identity,
    validation, remaining risk, and follow-up owner.

## Rollback rules

- **iOS:** pause App Store phased release first. An App Store binary is not
  instantly downgraded on installed phones. Submit or release a previous/new
  compatible build only through normal signed App Store validation.
- **Vercel:** restore the exact previously accepted deployment alias only after
  confirming its service contract and its compatibility with the current R2
  catalogs and database schema. Do not rebuild it and call that a rollback.
- **Supabase:** do not reverse production migrations ad hoc. Prefer an audited
  forward repair. A database restore requires explicit destructive-operation
  authorization and a point-in-time/data-loss decision by the incident
  commander and release owner.
- **R2 packs/Rider Services:** immutable objects stay immutable. The pack/data
  operator follows the pack publication contract and uses an already verified
  catalog backup only after checking every referenced object. A health incident
  does not authorize graph reconstruction.
- **Shortbread:** the app already health-gates DIRT tiles and falls back to
  public Shortbread. A Worker release rollback restores the prior immutable
  `RELEASE_ID`/`ARCHIVE_KEY` pair and is then verified with
  `npm run verify` from `scripts/shortbread-edge`.

## Incident record template

```text
Incident ID:
UTC opened / detected:
Severity:
Incident commander / support owner:
App version (build), environment, device/iOS:
Affected capability and rider-safe instruction:
First known / last known occurrence:
Request IDs (DIRT/Supabase), service build, deployment ID:
Pack + Rider Services catalog SHA-256:
Facts observed:
Actions authorized and by whom:
Recovery identity:
Verification performed:
UTC closed:
Follow-ups, owners, due dates:
```

## Known open gates

- Named people/backups and private contact methods have not been recorded in
  this repository.
- A current production Supabase backup plus isolated restore-drill evidence is
  not present in the repository.
- Alert delivery and ownership have not been proven; the launch watch currently
  depends on assigned operators and scheduled checks.
- The public Release build does not expose the in-app session-log exporter;
  that control is currently inside development-only tester tools. Support can
  use the safe intake path, screenshots, timestamps, and request IDs, but a
  public-build diagnostic-export decision remains open.
