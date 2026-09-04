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

For regional pack creation and promotion:
[docs/PACK-FACTORY.md](docs/PACK-FACTORY.md).

For Android routing/fuel/navigation parity:
[docs/ANDROID-PARITY.md](docs/ANDROID-PARITY.md).

For Start Navigation, cues, HUD, and in-ride waypoints:
[docs/00-NAVIGATION-SOURCE-OF-TRUTH.md](docs/00-NAVIGATION-SOURCE-OF-TRUTH.md).

Then read the narrow contract relevant to the task. Phase reports and handback
documents are historical evidence, not current instructions.
