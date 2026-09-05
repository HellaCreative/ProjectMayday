# SVWD03 style and sprite provenance — 2026-09-05

This is an engineering evidence record, not legal advice. It identifies the
source and local lineage of the shipped map artwork. It does not decide whether
the recorded upstream terms are compatible with DIRT's distribution model.

## Conclusion

The SVWD03 source is no longer unknown. The style and sprite family came from
Andy Townsend's `SomeoneElse-vector-web-display` project, via the SVWD03 style
then hosted by OpenStreetMap's vector service. The exact sprite bytes bundled
by iOS can be reproduced from a pinned upstream commit.

That finding does **not** close the release gate. The pinned upstream repository
has a GNU GPL version 3 root license, and its SVWD03 build/deploy scripts state
GNU GPL version 3 or later. The individual style and sprite files do not carry
their own embedded license notice. In addition, DIRT's web source explicitly
records an OSM Bright-derived recolour; that upstream project separately
licenses code under BSD 3-Clause and visual design under CC BY 4.0.

The release owner must obtain a written legal determination of the obligations
for the modified style and sprites, then implement the required notice,
attribution, source-distribution, or replacement action. Do not describe these
assets as DIRT-owned and do not infer a more permissive license from the
OpenStreetMap data attribution.

## Exact shipped/local files

SHA-256 values are over the files as stored, not normalized JSON.

| Location | File | Bytes | SHA-256 | Relationship |
| --- | --- | ---: | --- | --- |
| iOS | `Dirt/Map/shortbread-style.json` | 155,615 | `d2434e58a0ff0e8ceac7466929b990a95b55423f8fdaa12c783575cbbbfff8ac` | Current iOS style; local sprite placeholder |
| iOS | `Dirt/Map/shortbread/svwd03sprite.json` | 33,161 | `b621233115e12819ae02232a022b08a4b7350348be0f3b06a5368f02573942e2` | Exact upstream match |
| iOS | `Dirt/Map/shortbread/svwd03sprite@2x.json` | 33,161 | `b621233115e12819ae02232a022b08a4b7350348be0f3b06a5368f02573942e2` | Byte-identical to the non-`@2x` JSON |
| iOS | `Dirt/Map/shortbread/svwd03sprite.png` | 558,764 | `c11c946eb54d7c44676c03338c0f0c5132b784e9d86212637d6b758df6ab71f3` | Exact upstream match |
| iOS | `Dirt/Map/shortbread/svwd03sprite@2x.png` | 558,764 | `c11c946eb54d7c44676c03338c0f0c5132b784e9d86212637d6b758df6ab71f3` | Byte-identical to the non-`@2x` PNG |
| Android | `app/src/main/assets/map/shortbread-style.json` | 155,655 | `43b947564b49e2fe6b73138cb98378ccf819a710b90f011ae53ad9dc620fba85` | Same 382-layer array as current iOS; remote sprite URL instead of placeholder |
| Android | `app/src/main/assets/map/shortbread-rich-style.json` | 156,298 | `9feae1485fb271d1d89a6ccdd9a7e270c64d0bae585fff61d75322d3662f5f57` | Later Android-specific 382-layer variant; remote sprite URL |

`/Users/richardsmith/SandBox01/MAYDAYiOS/Dirt-pack-rebuild` is a Git worktree
whose common Git directory is the iOS repository. Its five style/sprite files
are byte-identical to the iOS files above; it is not an independent source.

The nearby retained web source at `/Volumes/SIDECAR/Codex/Mayday` contains the
same sprite quartet, plus:

- `app/data/shortbread-style.svwd03-backup.json`, SHA-256
  `6a43ec0c09bea200d90f5608e2b0de6c88f5becc4db90bf3334095f2226c4b7e`;
- the DIRT OSM Bright restyle at `app/data/shortbread-style.json`, SHA-256
  `feb2049476417986b166c12c1f4f361e0d89eb7ed4c1be637156417b83a6e10f`;
- `docs/BASEMAP-OSM-BRIGHT.md`, which records the recolour source and scope.

No SVWD03 style/sprite copy or additional provenance record was found in the
other nearby `Project-HailMary`, `PHM-02`, or `MAYDAY-HTML` trees.

## Copy and modification history

All local commits below were authored and committed as
`HellaCreative <62033648+HellaCreative@users.noreply.github.com>` unless noted.

1. Immediately before web commit `e227c8bbf80e961ad4862bc25436b8b9523022ad`,
   both `app/index.html` and `sources-test.html` loaded
   `https://vector.openstreetmap.org/styles/svwd/svwd03style.json`.
   Commit `e227c8bb` (2026-07-14, `Serve Shortbread style assets locally`)
   added `app/data/shortbread-style.json` and the four
   `app/data/shortbread/svwd03sprite*` files, then changed both callers to the
   local style. This establishes the local import route.
2. Web commit `565ef94bc519f84c86e27c4fa50ebacecc3c7eac` (2026-07-14)
   added the glyph URL. Its 382-layer array is the pre-recolour SVWD03 baseline.
3. Web commit `d7b71fa942888b002a8056928d0049af41b5c2f5` (2026-07-26,
   `Restyle Shortbread basemap toward OSM Bright (visual only)`) preserved that
   baseline as `shortbread-style.svwd03-backup.json`, changed 344 of 382 layer
   objects, and added `docs/BASEMAP-OSM-BRIGHT.md`.
4. iOS commit `fc5b9945f2f987a2c579066029703a5a30a1002b` (2026-07-26)
   first added `Dirt/Map/shortbread-style.json`. Its layer array exactly equals
   the web pre-recolour baseline; the file points its sprite URL at DIRT's web
   path.
5. iOS commit `85b15d2188e18f5e5e091ffbb46aa39030194f46` (2026-07-27)
   changed 64 of the 382 layer objects. Thirty-seven resulting layer objects
   exactly equal their counterparts in the explicit web OSM Bright restyle.
   The history does not name this transfer, so the byte overlap is recorded
   without asserting more than the evidence supports.
6. Android commit `c72e97368e87818397b68405dd7230019046c127`
   (2026-07-31, co-authored by Cursor) introduced
   `shortbread-style.json` byte-for-byte equal to iOS commit `85b15d2`.
7. iOS rescue commit `2b3264275ba6cf039338a4bac3903e54300bfc91`
   (2026-08-19, co-authored by Cursor) changed only the style's sprite location
   to `DIRT_SPRITE_PLACEHOLDER` and first committed the four local sprite files.
8. Android commit `68a654c55a1a12d6b77d36fad20da35c1ed73549`
   (2026-08-27, co-authored by Cursor) added `shortbread-rich-style.json` and
   changed 258 layer objects relative to Android standard. Android does not
   bundle the sprite quartet; both styles refer to DIRT's web URL.

For content comparison, current iOS and Android standard have identical
canonicalized `layers` arrays (SHA-256
`d086a686880190ebed123c079463f0f87b575fa8ee00bb227392a31aaef8ffb2`).
Their complete files differ only in the sprite-location value.

## Primary upstream evidence

### SVWD03 style and sprites

- Project: [SomeoneElseOSM/SomeoneElse-vector-web-display](https://github.com/SomeoneElseOSM/SomeoneElse-vector-web-display)
- Exact sprite revision: [commit `41ccc55fa5c22802a6470e36db7c38dca9481d77`](https://github.com/SomeoneElseOSM/SomeoneElse-vector-web-display/commit/41ccc55fa5c22802a6470e36db7c38dca9481d77), authored by Andy Townsend on 2026-07-02.
- At that revision, all four upstream `resources/svwd03sprite*` SHA-256 values
  exactly match the iOS files. The preceding sprite-changing commit
  `f2fb442f38f54db522c4525c48770429ef7232d7` has different hashes, so
  `41ccc55f` is the introduction of the exact bundled sprite revision.
- The sprite family was initially added by Andy Townsend in
  [commit `dceffc810325780af292075fe858674483cafff1`](https://github.com/SomeoneElseOSM/SomeoneElse-vector-web-display/commit/dceffc810325780af292075fe858674483cafff1)
  on 2024-12-05 (`Initial pre-release of "svwd03"`).
- The pinned root [`LICENSE`](https://github.com/SomeoneElseOSM/SomeoneElse-vector-web-display/blob/41ccc55fa5c22802a6470e36db7c38dca9481d77/LICENSE)
  is the GNU GPL version 3 license text, SHA-256
  `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`.
- The pinned [`svwd03_call_icon_convert.sh`](https://github.com/SomeoneElseOSM/SomeoneElse-vector-web-display/blob/41ccc55fa5c22802a6470e36db7c38dca9481d77/resources/svwd03_call_icon_convert.sh)
  and [`deploy_svwd03.sh`](https://github.com/SomeoneElseOSM/SomeoneElse-vector-web-display/blob/41ccc55fa5c22802a6470e36db7c38dca9481d77/resources/deploy_svwd03.sh)
  state copyright 2023–2026 Andy Townsend and GNU GPL version 3 or later.
- The pinned [`README_svwd03.md`](https://github.com/SomeoneElseOSM/SomeoneElse-vector-web-display/blob/41ccc55fa5c22802a6470e36db7c38dca9481d77/resources/README_svwd03.md)
  says SVWD03's icons were created for SVWD01, and credits a cartography chain
  through the author's earlier style, OSM Carto circa 2014, and older Mapnik
  styles. The conversion script names the corresponding
  `openstreetmap-carto-AJT/symbols/` inputs. The compiled style and sprite files
  contain no per-file license statement.

These are the license/source records actually found. The engineering audit
does not replace them with an inferred asset-specific license.

### OSM Bright visual reference

The web record links `openmaptiles/osm-bright-gl-style`. The latest revision
available when the DIRT recolour commit was made was
[commit `65c699326edce05da9bbda2c53116314259f1503`](https://github.com/openmaptiles/osm-bright-gl-style/commit/65c699326edce05da9bbda2c53116314259f1503).
Its pinned [`LICENSE.md`](https://github.com/openmaptiles/osm-bright-gl-style/blob/65c699326edce05da9bbda2c53116314259f1503/LICENSE.md),
SHA-256 `aa25033b12c9cbf8c2d95a310c66ce08727c01139d23de6df5ae97505fb98f82`,
states BSD 3-Clause for code and CC BY 4.0 for the visual design, with the
attribution instructions in that file.

## Separate OpenStreetMap data attribution

The style's vector source is
`https://vector.openstreetmap.org/shortbread_v1/{z}/{x}/{y}.mvt` and declares
`© OpenStreetMap contributors` linked to
`https://www.openstreetmap.org/copyright`. The app also leaves MapLibre's
attribution control enabled.

That attribution concerns the OpenStreetMap-derived tile **data**. It does not
license the independently authored SVWD03 style rules, sprite artwork, or OSM
Bright-derived visual decisions. Conversely, resolving the style/artwork terms
does not remove the OpenStreetMap data-attribution requirement.

## Required owner action before submission

1. Give counsel/product owner this document, the exact shipped hashes, and the
   two pinned upstream license records.
2. Obtain a written determination covering the modified SVWD03 JSON, compiled
   sprite sheets/metadata, the documented OSM Bright design influence, and the
   fact that iOS embeds the sprite bytes while Android requests them remotely.
3. Apply the determination: include all required notices/credits and any source
   or offer mechanism, obtain separate permission, or replace the affected
   style/sprites with assets whose app-distribution terms are documented.
4. Record the decision and exact replacement/final hashes in this file, then
   update `ThirdPartyNotices.txt` and Android's notice asset if required.
5. Keep the existing OpenStreetMap attribution independently intact.

Until those steps are complete, the App Store/Play submission gate remains
open even though the upstream identity is now established.
