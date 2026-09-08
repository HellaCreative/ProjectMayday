# Dirt — start here

**Develop only in this folder:** `/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt`

Open `Dirt.xcodeproj`. Branch: `feature/routing-itinerary-rebuild`.

Packs, adapters, live `/api/route`, and ship scripts live here under `scripts/pack-fabric/`. There is no second product repo.

## Bytes

| What | Where |
| --- | --- |
| Road packs (every CA province/territory + every US state) | Cloudflare R2 |
| Catalog | `https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/manifest.json` |
| Live `POST /api/route` | `https://dirt-mayday.vercel.app/api/route` — fetches those same R2 files |
| Phone PACKS sheet | Downloads the same files |

Vercel is API code only (`scripts/pack-fabric/api`). Packs never go on Hobby.

**Pack changes must land on R2 the same turn they are stamped.** `--candidate`
then `--promote`; add the id to both
`scripts/pack-fabric/routing/schema/v3-regions.json` and
`scripts/pack-fabric/routing/data/v3-regions.json`, then `--live` and
`--assert --region <id>` so `/api/route` requests that same object. Xcode ships
the app, not the road file. A pack that exists only on the laptop was **not**
tested.

## Do not

- Point `/api/route` at `longhaul.v1.json.gz`.
- Auto-download packs to “make live match.”
- Leave a pack rebuild unpublished.

Read first: [docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md](docs/00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md).

Frozen routing boundary:
[docs/ROUTING-FREEZE-2026-09-03.md](docs/ROUTING-FREEZE-2026-09-03.md).

Accepted Rider Services boundary:
[docs/RIDER-SERVICES-FREEZE-2026-09-05.md](docs/RIDER-SERVICES-FREEZE-2026-09-05.md).

For regional pack creation and promotion:
[docs/PACK-FACTORY.md](docs/PACK-FACTORY.md).

For full Android product parity—including routing, fuel, navigation,
subscriptions, accounts, Groups, privacy, GPX, and release gates:
[docs/ANDROID-PARITY.md](docs/ANDROID-PARITY.md).

Any iOS change that affects rider-visible behaviour, stored state, backend
contracts, entitlements, privacy, diagnostics, or acceptance tests must update
the Android parity contract in the same commit, or explicitly record why the
change has no Android counterpart. Platform-native implementation may differ;
the outcome and safety contract may not drift.

For Start Navigation, cues, HUD, and in-ride waypoints:
[docs/00-NAVIGATION-SOURCE-OF-TRUTH.md](docs/00-NAVIGATION-SOURCE-OF-TRUTH.md).

For public Release gates and App Store submission:
[docs/APP-STORE-LAUNCH-CHECKLIST.md](docs/APP-STORE-LAUNCH-CHECKLIST.md).

For development/production isolation and promotion rules:
[docs/ENVIRONMENTS-AND-RELEASES.md](docs/ENVIRONMENTS-AND-RELEASES.md).

For required public-site factual alignment before submission:
[docs/WEBSITE-LAUNCH-COPY-HANDOFF.md](docs/WEBSITE-LAUNCH-COPY-HANDOFF.md).

For the post-launch GPX-to-DIRT conversion milestone:
[docs/GPX-IMPORT-TO-DIRT-PLAN.md](docs/GPX-IMPORT-TO-DIRT-PLAN.md).

Then read the narrow contract relevant to the task. Phase reports and handback
documents are historical evidence, not current instructions.

## Routing recovery — September 7, 2026

The failed routing evolution commits `e92584d` and `106f5a5` were reverted
locally. Product intent remains in `docs/ROUTING-EVOLUTION-SPEC-2026-09-07.md`,
with recovery clarifications taking precedence. The prior implementation is
not qualified for launch. Sealed DEV V4 `fabric-v4-20260907-01` and catalogs
remain read-only; no V3 substitution, pack rebuild, or production publication.
Routing search, costs, variety seeds, forward progress, retrace handling, and
fuel-replacement ranking are one JavaScript/Swift contract. Implement behavioral
changes together and verify both runtimes; automated passes do not replace
White-device acceptance. Android must reproduce the accepted rider outcome,
but no Android implementation or qualification is claimed here.

## Owner authorization — September 8, 2026

Richard explicitly authorized all necessary routing and pack revisions, fixes,
and evolutions to complete the product. The prior read-only connection boundary
is reopened: create versioned DEV corrections while preserving the original
sealed release. Stable DIRT DEV publication is authorized after verification;
do not ask again. Actual production and GitHub backup remain gated as above.
Provide regular progress updates and distinguish automated verification from
physical-device acceptance. Do not claim perfection or launch qualification
while required checks remain open.

## Owner direction — live-only Atlantic repair cycle, September 8, 2026

Richard explicitly requires live JavaScript routing first. Publish verified fixes
to stable DIRT DEV, give him an actionable live test, and track each fix and his
results. Do not work on the Swift reader, install builds, or transfer/download
packs onto his phone during this cycle. After the live behavior is accepted,
apply the accepted fixes to Swift and verify parity. Do not treat future parity
work as a prerequisite for this live canary. Production and GitHub push remain
out of scope.
