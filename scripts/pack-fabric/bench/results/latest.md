# Nova Scotia routing benchmark

Git `f0bf253` · 2026-08-23T03:43:05.249Z · seed `3511091208` · 38/45 cases green
Live source: `https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/ns-osm-20260821-02/ns`

| Result | Case | km | Dirt | Paved | Unknown | Stops | Max hop | Backtrack | Restricted | Candidates / chosen dirt | ms | Assertions |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | --- |
| 🟢 | `short-no-fuel/dirt/unknown-off/fuel-planned` | 8.9 | 34% | 66% | 14% | 0 | 8.9 km | 0% | 0 m | 0 / — | 138 | ✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `short-no-fuel/dirt/unknown-on/fuel-planned` | 8.9 | 34% | 66% | 14% | 0 | 8.9 km | 0% | 0 m | 0 / — | 26 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `short-no-fuel/balanced/unknown-off/fuel-planned` | 9.9 | 38% | 62% | 19% | 0 | 9.9 km | 0% | 0 m | 0 / — | 126 | ✗ balanced 45–55 (38%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `short-no-fuel/direct/unknown-off/fuel-planned` | 8.1 | 19% | 81% | 11% | 0 | 8.1 km | 0% | 0 m | 0 / — | 58 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `short-no-fuel/clean/unknown-off/fuel-planned` | 7.6 | 6% | 94% | 5% | 0 | 7.6 km | 0% | 0 m | 0 / — | 181 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/dirt/unknown-off/fuel-planned` | 579.2 | 71.1% | 28.9% | 5% | 2 | 237.4 km | 3.4% | 0 m | 4 / 61%,76% | 8898 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/dirt/unknown-on/fuel-planned` | 440.8 | 83.7% | 16.3% | 4.6% | 1 | 232.4 km | 3% | 0 m | 2 / 89% | 5708 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/balanced/unknown-off/fuel-planned` | 375.8 | 49.5% | 50.5% | 5.3% | 1 | 201.0 km | 0.1% | 0 m | 4 / 50% | 6513 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/direct/unknown-off/fuel-planned` | 321.3 | 33.4% | 66.6% | 0.7% | 1 | 221.6 km | 0.1% | 0 m | 6 / 48% | 2878 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/clean/unknown-off/fuel-planned` | 336.7 | 0% | 100% | 0% | 1 | 234.9 km | 0.1% | 0 m | 6 / 0% | 2746 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-antigonish/dirt/unknown-off/fuel-planned` | 409.4 | 87.3% | 12.7% | 3.5% | 1 | 236.3 km | 3.5% | 0 m | 2 / 86% | 6137 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-antigonish/dirt/unknown-on/fuel-planned` | 309.9 | 87% | 13% | 5.8% | 1 | 227.7 km | 2.5% | 0 m | 2 / 87% | 6193 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-antigonish/balanced/unknown-off/fuel-planned` | 229.1 | 50% | 50% | 1% | 0 | 229.1 km | 0% | 0 m | 0 / — | 506 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-antigonish/direct/unknown-off/fuel-planned` | 230.7 | 48.7% | 51.3% | 1% | 1 | 224.7 km | 0.1% | 0 m | 6 / 50% | 2554 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-antigonish/clean/unknown-off/fuel-planned` | 240.2 | 0% | 100% | 0% | 1 | 234.0 km | 0% | 0 m | 6 / 0% | 2861 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `musq-sherbrooke/dirt/unknown-off/fuel-planned` | 64.3 | 92% | 8% | 9% | 0 | 64.3 km | 0% | 0 m | 0 / — | 93 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `musq-sherbrooke/dirt/unknown-on/fuel-planned` | 64.3 | 92% | 8% | 9% | 0 | 64.3 km | 0% | 0 m | 0 / — | 69 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `musq-sherbrooke/balanced/unknown-off/fuel-planned` | 73.6 | 58% | 42% | 0% | 0 | 73.6 km | 0% | 0 m | 0 / — | 147 | ✗ balanced 45–55 (58%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `musq-sherbrooke/direct/unknown-off/fuel-planned` | 55.2 | 40% | 60% | 0% | 0 | 55.2 km | 0% | 0 m | 0 / — | 29 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `musq-sherbrooke/clean/unknown-off/fuel-planned` | 56.9 | 0% | 100% | 0% | 0 | 56.9 km | 0% | 0 m | 0 / — | 3 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `antigonish-sydney/dirt/unknown-off/fuel-planned` | 353.9 | 51.7% | 48.3% | 6.7% | 1 | 237.4 km | 0% | 0 m | 2 / 53% | 4447 | ✗ dirt ≥70 (51.7%)<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/dirt/unknown-on/fuel-planned` | 363.5 | 55.4% | 44.6% | 7.9% | 1 | 237.4 km | 0% | 0 m | 2 / 53% | 4873 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/balanced/unknown-off/fuel-planned` | 316.2 | 48% | 52% | 2.5% | 1 | 163.3 km | 0% | 0 m | 4 / 49% | 6603 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/direct/unknown-off/fuel-planned` | 234.9 | 11% | 89% | 3% | 0 | 234.9 km | 0% | 0 m | 0 / — | 275 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/clean/unknown-off/fuel-planned` | 240.9 | 0% | 100% | 0% | 1 | 235.4 km | 0% | 0 m | 6 / 0% | 1929 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `through-halifax/dirt/unknown-off/fuel-planned` | — | — | — | — | — | — km | — | — | 0 / — | 3015 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤6000ms per hop |
| 🟢 | `through-halifax/dirt/unknown-on/fuel-planned` | 198.7 | 87% | 13% | 27% | 0 | 198.7 km | 0% | 0 m | 0 / — | 212 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `through-halifax/balanced/unknown-off/fuel-planned` | — | — | — | — | — | — km | — | — | 0 / — | 2379 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤6000ms per hop |
| 🔴 | `through-halifax/direct/unknown-off/fuel-planned` | — | — | — | — | — | — km | — | — | 0 / — | 1714 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤6000ms per hop |
| 🟢 | `through-halifax/clean/unknown-off/fuel-planned` | 246.4 | 0.1% | 99.9% | 0% | 1 | 237.5 km | 0.1% | 0 m | 6 / 0% | 4174 | ✓ clean ≤15<br>✓ urban wall<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `white-fuel-20260823/dirt/unknown-off/fuel-planned` | 420.3 | 81.3% | 18.7% | 4.7% | 1 | 237.4 km | 0% | 0 m | 2 / 73% | 5448 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `white-fuel-20260823/dirt/unknown-on/fuel-planned` | 326.6 | 90.4% | 9.6% | 2.6% | 1 | 208.4 km | 4.1% | 0 m | 2 / 89% | 5617 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `white-fuel-20260823/balanced/unknown-off/fuel-planned` | 288.1 | 50% | 50% | 1.7% | 1 | 201.0 km | 0.1% | 0 m | 4 / 50% | 5530 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `white-fuel-20260823/direct/unknown-off/fuel-planned` | 260.7 | 49.8% | 50.2% | 4.6% | 1 | 221.6 km | 0.1% | 0 m | 6 / 48% | 2529 | ✗ direct ≤shortest+15km (260653m vs 245186m)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `white-fuel-20260823/clean/unknown-off/fuel-planned` | 281.2 | 0% | 100% | 0% | 1 | 234.9 km | 0.1% | 0 m | 6 / 0% | 3050 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/dirt/unknown-off/fuel-planned` | 780.5 | 82.3% | 17.7% | 6.4% | 3 | 228.3 km | 4.1% | 0 m | 6 / 87%,98%,65% | 22671 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/dirt/unknown-on/fuel-planned` | 567.3 | 83.2% | 16.8% | 4.9% | 1 | 218.7 km | 4.2% | 0 m | 2 / 92% | 21363 | ✓ fuel gap labelled<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/balanced/unknown-off/fuel-planned` | 426.7 | 49.8% | 50.2% | 2.5% | 2 | 148.0 km | 0.2% | 0 m | 8 / 52%,50% | 16159 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/direct/unknown-off/fuel-planned` | 384.5 | 38.3% | 61.7% | 1.4% | 1 | 136.6 km | 0.7% | 0 m | 6 / 31% | 6356 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/clean/unknown-off/fuel-planned` | 498.4 | 4.3% | 95.7% | 0% | 2 | 173.2 km | 4.1% | 0 m | 9 / 30%,0% | 15284 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/dirt/unknown-off/fuel-planned` | 780.5 | 82.3% | 17.7% | 6.4% | 3 | 228.3 km | 4.1% | 0 m | 6 / 87%,98%,65% | 22756 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/dirt/unknown-on/fuel-planned` | 567.3 | 83.2% | 16.8% | 4.9% | 1 | 218.7 km | 4.2% | 0 m | 2 / 92% | 20933 | ✓ fuel gap labelled<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/balanced/unknown-off/fuel-planned` | 426.7 | 49.8% | 50.2% | 2.5% | 2 | 148.0 km | 0.2% | 0 m | 8 / 52%,50% | 16219 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/direct/unknown-off/fuel-planned` | 384.5 | 38.3% | 61.7% | 1.4% | 1 | 136.6 km | 0.7% | 0 m | 6 / 31% | 6388 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/clean/unknown-off/fuel-planned` | 498.4 | 4.3% | 95.7% | 0% | 2 | 173.2 km | 4.1% | 0 m | 9 / 30%,0% | 15746 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |

Red rows: `short-no-fuel/balanced/unknown-off/fuel-planned`, `musq-sherbrooke/balanced/unknown-off/fuel-planned`, `antigonish-sydney/dirt/unknown-off/fuel-planned`, `through-halifax/dirt/unknown-off/fuel-planned`, `through-halifax/balanced/unknown-off/fuel-planned`, `through-halifax/direct/unknown-off/fuel-planned`, `white-fuel-20260823/direct/unknown-off/fuel-planned`. These are measurements, not blocked tests.
