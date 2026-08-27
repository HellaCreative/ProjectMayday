# Nova Scotia routing benchmark

Git `e135c0f` · 2026-08-27T18:30:32.037Z · seed `3511091208` · 28/48 cases green
Live source: `https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/ns-v3-20260827-06/ns`

| Result | Case | km | Dirt | Paved | Unknown | Stops | Max hop | Backtrack | Restricted | Candidates / chosen dirt | ms | Assertions |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | --- |
| 🟢 | `short-no-fuel/dirt/unknown-off/fuel-planned` | 7.4 | 17% | 83% | 6% | 0 | 7.4 km | 0% | 0 m | 0 / — | 140 | ✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `short-no-fuel/dirt/unknown-on/fuel-planned` | 7.4 | 17% | 83% | 6% | 0 | 7.4 km | 0% | 0 m | 0 / — | 35 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `short-no-fuel/balanced/unknown-off/fuel-planned` | 16.8 | 30% | 70% | 2% | 0 | 16.8 km | 0% | 0 m | 0 / — | 85 | ✗ balanced 45–55 (30%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `short-no-fuel/clean/unknown-off/fuel-planned` | 7.4 | 11% | 89% | 6% | 0 | 7.4 km | 0% | 0 m | 0 / — | 358 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `dartmouth-capebreton/dirt/unknown-off/fuel-planned` | 408.7 | 63.1% | 36.9% | 2.4% | 1 | 236.5 km | 0% | 0 m | 13 / 51% | 8917 | ✗ dirt ≥70 (63.1%)<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/dirt/unknown-on/fuel-planned` | 429.3 | 82.8% | 17.2% | 8.3% | 1 | 237.2 km | 0% | 0 m | 12 / 81% | 9358 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/balanced/unknown-off/fuel-planned` | 362.1 | 51.1% | 48.9% | 3.6% | 1 | 231.3 km | 0% | 0 m | 8 / 50% | 8229 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `dartmouth-capebreton/clean/unknown-off/fuel-planned` | 324.0 | 19.8% | 80.2% | 2.9% | 1 | 237.3 km | 0.1% | 0 m | 13 / 27% | 6892 | ✗ clean ≤15 (19.8%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `dartmouth-antigonish/dirt/unknown-off/fuel-planned` | 244.8 | 52.7% | 47.3% | 3.5% | 1 | 236.2 km | 0% | 0 m | 8 / 54% | 7341 | ✗ dirt ≥70 (52.7%)<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-antigonish/dirt/unknown-on/fuel-planned` | 245.9 | 84.6% | 15.4% | 9.3% | 1 | 237.4 km | 0% | 0 m | 6 / 87% | 8231 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `dartmouth-antigonish/balanced/unknown-off/fuel-planned` | 303.8 | 46.4% | 53.6% | 4% | 1 | 230.2 km | 0% | 0 m | 4 / 44% | 9164 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✗ ≤6000ms per hop (6452ms) |
| 🟢 | `dartmouth-antigonish/clean/unknown-off/fuel-planned` | 208.2 | 2% | 98% | 2% | 0 | 208.2 km | 0% | 0 m | 0 / — | 181 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `musq-sherbrooke/dirt/unknown-off/fuel-planned` | 68.8 | 44% | 56% | 0% | 0 | 68.8 km | 0% | 0 m | 0 / — | 39 | ✗ dirt ≥70 (44%)<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `musq-sherbrooke/dirt/unknown-on/fuel-planned` | 64.2 | 92% | 8% | 9% | 0 | 64.2 km | 0% | 0 m | 0 / — | 26 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `musq-sherbrooke/balanced/unknown-off/fuel-planned` | 68.7 | 43% | 57% | 0% | 0 | 68.7 km | 0% | 0 m | 0 / — | 65 | ✗ balanced 45–55 (43%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `musq-sherbrooke/clean/unknown-off/fuel-planned` | 56.9 | 0% | 100% | 0% | 0 | 56.9 km | 0% | 0 m | 0 / — | 112 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `antigonish-sydney/dirt/unknown-off/fuel-planned` | 252.1 | 52.7% | 47.3% | 8.5% | 1 | 237.3 km | 0% | 0 m | 16 / 51% | 6170 | ✗ dirt ≥70 (52.7%)<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/dirt/unknown-on/fuel-planned` | 265.4 | 53.6% | 46.4% | 3.8% | 1 | 237.3 km | 0% | 0 m | 16 / 50% | 7528 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/balanced/unknown-off/fuel-planned` | 264.4 | 46.6% | 53.4% | 5.3% | 1 | 235.4 km | 0% | 0 m | 8 / 47% | 7641 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/clean/unknown-off/fuel-planned` | 223.2 | 9% | 91% | 9% | 0 | 223.2 km | 0% | 0 m | 0 / — | 129 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `through-halifax/dirt/unknown-off/fuel-planned` | 45.1 | 2% | 98% | 2% | 0 | 45.1 km | 0% | 0 m | 0 / — | 735 | ✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `through-halifax/dirt/unknown-on/fuel-planned` | 100.2 | 69% | 31% | 13% | 0 | 100.2 km | 0% | 0 m | 0 / — | 1257 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `through-halifax/balanced/unknown-off/fuel-planned` | 49.7 | 12% | 88% | 4% | 0 | 49.7 km | 0% | 0 m | 0 / — | 1144 | ✗ balanced 45–55 (12%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `through-halifax/clean/unknown-off/fuel-planned` | 44.3 | 2% | 98% | 2% | 0 | 44.3 km | 0% | 0 m | 0 / — | 145 | ✓ clean ≤15<br>✓ urban wall<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `white-fuel-20260823/dirt/unknown-off/fuel-planned` | 293.6 | 56.1% | 43.9% | 0.6% | 1 | 203.8 km | 0.1% | 0 m | 10 / 55% | 6713 | ✗ dirt ≥70 (56.1%)<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `white-fuel-20260823/dirt/unknown-on/fuel-planned` | 300.8 | 87.9% | 12.1% | 4.9% | 1 | 210.1 km | 0% | 0 m | 11 / 90% | 7327 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `white-fuel-20260823/balanced/unknown-off/fuel-planned` | 286.9 | 46.6% | 53.4% | 0.3% | 1 | 203.2 km | 0.1% | 0 m | 6 / 46% | 8989 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✗ ≤6000ms per hop (7362ms) |
| 🔴 | `white-fuel-20260823/clean/unknown-off/fuel-planned` | 269.1 | 23.8% | 76.2% | 3.5% | 1 | 237.3 km | 0.1% | 0 m | 10 / 27% | 6125 | ✗ clean ≤15 (23.8%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `device-loop-20260823/dirt/unknown-off/fuel-planned` | 385.9 | 57.8% | 42.2% | 4.7% | 1 | 203.7 km | 0% | 0 m | 15 / 55% | 8678 | ✗ dirt ≥70 (57.8%)<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `device-loop-20260823/dirt/unknown-on/fuel-planned` | 416.7 | 85.5% | 14.5% | 3.5% | 1 | 210.1 km | 0% | 0 m | 12 / 90% | 7976 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `device-loop-20260823/balanced/unknown-off/fuel-planned` | 372.6 | 54.6% | 45.4% | 6.8% | 1 | 203.2 km | 0% | 0 m | 8 / 46% | 8523 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `device-loop-20260823/clean/unknown-off/fuel-planned` | 318.9 | 11% | 89% | 11% | 1 | 173.4 km | 0% | 0 m | 14 / 0% | 5511 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `fuel-overshoot-20260826/dirt/unknown-off/fuel-planned` | 232.1 | 45% | 55% | 0% | 0 | 232.1 km | 0% | 0 m | 0 / — | 565 | ✗ dirt ≥70 (45%)<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `fuel-overshoot-20260826/dirt/unknown-on/fuel-planned` | 179.7 | 88% | 12% | 8% | 0 | 179.7 km | 0% | 0 m | 0 / — | 521 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `fuel-overshoot-20260826/balanced/unknown-off/fuel-planned` | 209.2 | 34% | 66% | 0% | 0 | 209.2 km | 0% | 0 m | 0 / — | 315 | ✗ balanced 45–55 (34%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `fuel-overshoot-20260826/clean/unknown-off/fuel-planned` | 168.6 | 1% | 99% | 1% | 0 | 168.6 km | 0% | 0 m | 0 / — | 157 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `fuel-early-stop-20260827/dirt/unknown-off/fuel-planned` | 199.2 | 45% | 55% | 0% | 0 | 199.2 km | 0% | 0 m | 0 / — | 288 | ✗ dirt ≥70 (45%)<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `fuel-early-stop-20260827/dirt/unknown-on/fuel-planned` | 208.5 | 90% | 10% | 4% | 0 | 208.5 km | 0% | 0 m | 0 / — | 122 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `fuel-early-stop-20260827/balanced/unknown-off/fuel-planned` | 209.2 | 49% | 51% | 4% | 0 | 209.2 km | 0% | 0 m | 0 / — | 406 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `fuel-early-stop-20260827/clean/unknown-off/fuel-planned` | 198.6 | 1% | 99% | 1% | 0 | 198.6 km | 0% | 0 m | 0 / — | 170 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `three-waypoint/dirt/unknown-off/fuel-planned` | 534.0 | 52.6% | 47.4% | 6.4% | 2 | 139.0 km | 0.5% | 0 m | 26 / 30%,45% | 22263 | ✗ dirt ≥70 (52.6%)<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/dirt/unknown-on/fuel-planned` | 493.6 | 84.5% | 15.5% | 3% | 0 | 265.8 km | 0.8% | 0 m | 0 / — | 24466 | ✓ fuel gap labelled<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/balanced/unknown-off/fuel-planned` | 489.3 | 54.2% | 45.8% | 10.5% | 1 | 204.7 km | 0.2% | 0 m | 9 / 26% | 21556 | ✓ fuel gap labelled<br>✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `three-waypoint/clean/unknown-off/fuel-planned` | 411.0 | 16% | 84% | 11.4% | 3 | 173.6 km | 0.6% | 0 m | 15 / 0%,0%,34% | 14989 | ✗ clean ≤15 (16%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `phase10-104745/dirt/unknown-off/fuel-planned` | 534.0 | 52.6% | 47.4% | 6.4% | 2 | 139.0 km | 0.5% | 0 m | 26 / 30%,45% | 22214 | ✗ dirt ≥70 (52.6%)<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/dirt/unknown-on/fuel-planned` | 493.6 | 84.5% | 15.5% | 3% | 0 | 265.8 km | 0.8% | 0 m | 0 / — | 24181 | ✓ fuel gap labelled<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/balanced/unknown-off/fuel-planned` | 489.3 | 54.2% | 45.8% | 10.5% | 1 | 204.7 km | 0.2% | 0 m | 9 / 26% | 21697 | ✓ fuel gap labelled<br>✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `phase10-104745/clean/unknown-off/fuel-planned` | 411.0 | 16% | 84% | 11.4% | 3 | 173.6 km | 0.6% | 0 m | 15 / 0%,0%,34% | 16195 | ✗ clean ≤15 (16%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |

Red rows: `short-no-fuel/balanced/unknown-off/fuel-planned`, `dartmouth-capebreton/dirt/unknown-off/fuel-planned`, `dartmouth-capebreton/clean/unknown-off/fuel-planned`, `dartmouth-antigonish/dirt/unknown-off/fuel-planned`, `dartmouth-antigonish/balanced/unknown-off/fuel-planned`, `musq-sherbrooke/dirt/unknown-off/fuel-planned`, `musq-sherbrooke/balanced/unknown-off/fuel-planned`, `antigonish-sydney/dirt/unknown-off/fuel-planned`, `through-halifax/balanced/unknown-off/fuel-planned`, `white-fuel-20260823/dirt/unknown-off/fuel-planned`, `white-fuel-20260823/balanced/unknown-off/fuel-planned`, `white-fuel-20260823/clean/unknown-off/fuel-planned`, `device-loop-20260823/dirt/unknown-off/fuel-planned`, `fuel-overshoot-20260826/dirt/unknown-off/fuel-planned`, `fuel-overshoot-20260826/balanced/unknown-off/fuel-planned`, `fuel-early-stop-20260827/dirt/unknown-off/fuel-planned`, `three-waypoint/dirt/unknown-off/fuel-planned`, `three-waypoint/clean/unknown-off/fuel-planned`, `phase10-104745/dirt/unknown-off/fuel-planned`, `phase10-104745/clean/unknown-off/fuel-planned`. These are measurements, not blocked tests.
