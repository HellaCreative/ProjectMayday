# DIRT routing release-candidate freeze — 2026-09-03

**Status:** frozen routing release candidate

**Routing implementation and deployed service source:**
`94b467a11375e3ea3233c127b07af2ef039d0658`

**iOS device build accepted on White:** `2 (13)`

**Service contract:** `dirt-routing.r0.v1`

**Branch:** `feature/routing-itinerary-rebuild`

This is the release boundary for the routing, fuel, itinerary, and navigation-
preparation behaviour accepted after the September 3 device pass. The annotated
Git tag `routing-rc1-2026-09-03` identifies the exact implementation commit.
Documentation and factory safeguards may be committed after that tag without
changing the frozen runtime behaviour.

## Open DEV candidate after this freeze — 2026-09-06

Richard explicitly reopened DEV routing after White-device Yarmouth and Cape
Breton failures. Build `2 (16)` corrects degraded-Dirt meander, smaller-town
cost, unsafe partial fuel selection, and redundant same-profile rebuilds. It
changes Swift/shared routing code only; no pack bytes are rebuilt or promoted.
The September 3 source and production service remain the frozen rollback until
the matching DEV service and build `2 (16)` pass physical White acceptance and
a new freeze record is created.

Build `2 (17)` supersedes that unaccepted candidate. The White-device Yarmouth
trace proved the new shortest-plus-60-km ceiling suppressed the established Dirt
objective, while a missing foundation-cell value was coerced to zero and let a
13.2 km Coast Gas return pass. Build `2 (17)` removes that ceiling and fixes the
missing-value test. It rebuilds no pack and remains DEV-only pending White
acceptance.

The next DEV-only service candidate rejects approach-only timeout pumps, permits
only a 250 ms scheduler allowance for a continuation that actually completed,
reports the effective Allow Unknown value on direct fuel responses, and keeps an
already-proved route intact when inserting an on-route fuel waypoint. A short
partition's standalone quality label cannot replace the whole ride with two
independent searches. It does not change route costs, pack bytes, or the
20-second search deadline.

## What is frozen

- Dirt, Balanced, and Clean route-selection laws and their shared Swift/JS cost
  semantics.
- Known-surface scoring, unknown-access eligibility, urban-core avoidance,
  forward-progress protection, ferry handling, and honest surface statistics.
- The 20-second fuel-window contract, fresh window at every rider or fuel
  anchor, first-sensible-pump policy after 75% of usable range, and the bounded
  alternative shortlist.
- Foundation-route fuel partitioning, incremental cross-region fuel planning,
  retained-pump recovery, and the distinction between a proved gap and an
  interrupted or unknown fuel proof.
- A route remains usable when fuel proof fails; the warning belongs to the exact
  affected rider leg and does not replace its geometry.
- A profile or Allow Unknown edit on a visible Point/F stage changes only that
  stage. The fuel-dependent suffix inside its owning rider leg may rebuild, but
  the edited policy does not leak to later stages or other rider legs.
- Start Navigation prepares only the first visible stage's basemap corridor and
  the rider's current province/state routing pack. Later tiles advance one stage
  at a time and later routing packs are acquired only when the rider enters the
  region.

Changing any item above reopens the routing release candidate and requires an
explicit diagnosis, fixed regression, new device build, matching live service,
and a new freeze record. Pack-data replication does not reopen the routing
candidate when it follows [PACK-FACTORY.md](PACK-FACTORY.md) without changing
the engine, schema, taxonomy, or costs.

## Accepted V3 reference bytes

These promoted bytes are the reference mould. Pack Factory must not rebuild or
replace them unless Richard explicitly opens a new pack revision.

| Region | Release record | `graph.v3.bin` SHA-256 | `geometry.v1.bin` SHA-256 | `fuel.v1.json` SHA-256 |
| --- | --- | --- | --- | --- |
| Nova Scotia | `ns-v3-20260827-06` | `e91ffacfe6ecf1a60312697f94988d840b8ffde440ef89b0bd0627cc4e784b51` | `6405e718590453be918d059b56c31d41180a88efe1d7f786deb9268b9ae1a804` | `999e1cbd5901b2bb28f7c09d7578abe2e7c69ad3e68c25b0b776c0172305fdd2` |
| New Brunswick | `nb-v3-20260824-01` | `ef2b554099463fa04613d89a4aef0b8a610175cf878773d9627c94a1fc550db8` | `803b2c3a6ed1b27f2b88e209ba2b8eadd9d62de56b472e28575f25e0a11aa18a` | `da064856c77f36dd2a7c1c9af0a2fd04a8fe0bbccdaa0b74f6265a46449907f9` |
| Prince Edward Island | `pe-v3-20260825-01` | `109b9ffd87c1f5fb0df5623a1a6a3dfbce33bc740babf407ae40516a52aa9534` | `9d4c94e487f4be13a6e8f504d4a944ef9df43e0fdc0b2fa88c3a68ebe86ffb83` | `605488e89e9e81e047f8c442deba45b7b954519cd59a92ab298ee3a9c9bdc5ad` |
| Newfoundland and Labrador | `nl-v3-20260825-01` | `43d3036d6d89001577ac650e2fc832fb12c8989c2a12230ce6edf5a60fd4416a` | `89a2eab93346bff4d3a068c6eb382393e8b4b0a657ddca12356d920e9e6e3424` | `d039a2dfe1eac9e7617f801819ae7ac3b2a9a25bdade5bd4659f2d4b61c5862e` |
| Quebec | `qc-v3-20260825-01` | `5cdf9b679f8046d713cdd6d3c9af069c2617106f3383a7f0026ab344fc598e1f` | `3fd30b4209e83812b1a9300f649fbed82e4c54a219a0b163c6bf47cb9e0d0659` | `c36606a2587d0db9feee40a8c9ebc30725c6572535bbca6ec455355e27220685` |
| Ontario | `on-v3-20260902-01` | `d1fdb3ae5a9a347512ddc8a0666fc2d74b80343b5b8dd3a41dd52d1a6f73673b` | `55adf2e23562ff2209f8924cb24415c4acbafe3d831d29d972b559bb1fe4bd54` | `c512a9f30bc7b04559ea1c9a8201f193add3a64cba41513ac1e640bf15c27d6a` |

The checked-in release records are immutable candidate identity records; their
historical `status` field is not a current-publication oracle. The public R2
manifest and the region-scoped lockstep assertion determine what is promoted.
Never replace the remote 63-region catalog with the checked-in seed manifest.

## Acceptance evidence

- iOS unit suite passed on the accepted source.
- Shared JavaScript suite: 249 passed, 4 skipped.
- Nova Scotia benchmark: 24 of 48 strict greens with no green-to-red movement.
- All five fixed long-fuel regressions passed.
- Production service returned the exact implementation source identity and the
  promoted graph, geometry, and fuel hashes for NS, NB, QC, and ON.
- Physical White build 2 (13) completed short, single-region, cross-region,
  direct-in-range, automatic-fuel, local-edit, and honest remote-gap tests.
- The final field log showed a deliberate user cancellation, not a routing
  failure; later requests completed normally.

## Allowed work while frozen

- Create new regional packs through Pack Factory.
- Add immutable release records, acceptance fixtures, reports, and region IDs.
- Improve diagnostics, tests, documentation, and build/promotion safeguards
  without changing rider-visible routing behaviour.
- Port the frozen contract to Android using [ANDROID-PARITY.md](ANDROID-PARITY.md).

## Not allowed under this freeze

- Retune routing costs, search widths, time budgets, fuel thresholds, stop
  ranking, edit ownership, or warning semantics as part of a pack build.
- Add provincial supplements, longhaul graphs, free-space joins, synthetic road
  shortcuts, or a second live road fabric.
- Bulk-promote untested regions or alter an accepted reference region while
  producing another region.
- Claim parity from screenshots alone; service and pack identities remain part
  of the acceptance record.
