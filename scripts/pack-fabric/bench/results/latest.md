# Nova Scotia routing benchmark

Git `ee25e92` · 2026-08-21T07:45:59.196Z · seed `3511091208` · 40/65 cases green
Live source: `https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/ns-osm-20260820-01/ns`

| Result | Case | km | Dirt | Paved | Unknown | Stops | Max hop | Backtrack | Restricted | Candidates / chosen dirt | ms | Assertions |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | --- |
| 🟢 | `short-no-fuel/dirt/unknown-off/fuel-off` | 8.9 | 34% | 66% | 14% | 0 | 8.9 km | 0% | 0 m | 0 / — | 117 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `short-no-fuel/dirt/unknown-on/fuel-off` | 8.9 | 34% | 66% | 14% | 0 | 8.9 km | 0% | 0 m | 0 / — | 26 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `short-no-fuel/balanced/unknown-off/fuel-off` | 9.9 | 38% | 62% | 19% | 0 | 9.9 km | 0% | 0 m | 0 / — | 105 | ✗ balanced 45–55 (38%)<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `short-no-fuel/direct/unknown-off/fuel-off` | 8.1 | 19% | 81% | 11% | 0 | 8.1 km | 0% | 0 m | 0 / — | 16 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `short-no-fuel/clean/unknown-off/fuel-off` | 7.6 | 6% | 94% | 5% | 0 | 7.6 km | 0% | 0 m | 0 / — | 133 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-capebreton/dirt/unknown-off/fuel-off` | 484.6 | 84% | 16% | 7% | 0 | 484.6 km | 0% | 0 m | 0 / — | 720 | ✓ dirt ≥70<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `dartmouth-capebreton/dirt/unknown-off/fuel-on` | 469.2 | 62.8% | 37.2% | 8.5% | 1 | 237.2 km | 2.5% | 0 m | 6 / 77% | 6423 | ✗ dirt ≥70 (62.8%)<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✗ ≤4000ms per hop (4759ms) |
| 🟢 | `dartmouth-capebreton/dirt/unknown-on/fuel-off` | 441.3 | 87% | 13% | 6% | 0 | 441.3 km | 0% | 0 m | 0 / — | 712 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `dartmouth-capebreton/dirt/unknown-on/fuel-on` | 451.9 | 75.5% | 24.5% | 5.5% | 1 | 237.2 km | 0.8% | 0 m | 6 / 87% | 7222 | ✓ no unexplained backtrack<br>✗ ≤4000ms per hop (5381ms) |
| 🟢 | `dartmouth-capebreton/balanced/unknown-off/fuel-off` | 333.0 | 50% | 50% | 1% | 0 | 333.0 km | 0% | 0 m | 0 / — | 509 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-capebreton/balanced/unknown-off/fuel-on` | 375.6 | 50.5% | 49.5% | 1.1% | 1 | 201.3 km | 0.1% | 0 m | 6 / 51% | 4533 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `dartmouth-capebreton/direct/unknown-off/fuel-off` | 424.9 | 66% | 34% | 10% | 0 | 424.9 km | 0% | 0 m | 0 / — | 98 | ✗ direct ≤shortest+15km (424859m vs 320735m)<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `dartmouth-capebreton/direct/unknown-off/fuel-on` | 431.6 | 53.7% | 46.3% | 7.8% | 1 | 227.1 km | 0.1% | 0 m | 6 / 58% | 1918 | ✗ direct ≤shortest+15km (431644m vs 320735m)<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-capebreton/clean/unknown-off/fuel-off` | 418.4 | 0% | 100% | 0% | 0 | 418.4 km | 0% | 0 m | 0 / — | 115 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-capebreton/clean/unknown-off/fuel-on` | 336.7 | 0% | 100% | 0% | 1 | 234.9 km | 0.1% | 0 m | 6 / 0% | 1705 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-antigonish/dirt/unknown-off/fuel-off` | 303.3 | 87% | 13% | 6% | 0 | 303.3 km | 0% | 0 m | 0 / — | 331 | ✓ dirt ≥70<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `dartmouth-antigonish/dirt/unknown-off/fuel-on` | 237.1 | 54% | 46% | 3% | 0 | 237.1 km | 0% | 0 m | 0 / — | 1807 | ✗ dirt ≥70 (54%)<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-antigonish/dirt/unknown-on/fuel-off` | 270.7 | 90% | 10% | 5% | 0 | 270.7 km | 0% | 0 m | 0 / — | 362 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-antigonish/dirt/unknown-on/fuel-on` | 237.3 | 72% | 28% | 13% | 0 | 237.3 km | 0% | 0 m | 0 / — | 1896 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-antigonish/balanced/unknown-off/fuel-off` | 229.1 | 50% | 50% | 1% | 0 | 229.1 km | 0% | 0 m | 0 / — | 226 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-antigonish/balanced/unknown-off/fuel-on` | 229.1 | 50% | 50% | 1% | 0 | 229.1 km | 0% | 0 m | 0 / — | 203 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `dartmouth-antigonish/direct/unknown-off/fuel-off` | 310.3 | 69% | 31% | 3% | 0 | 310.3 km | 0% | 0 m | 0 / — | 77 | ✗ direct ≤shortest+15km (310292m vs 228531m)<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-antigonish/direct/unknown-off/fuel-on` | 237.5 | 52% | 48% | 5% | 0 | 237.5 km | 0% | 0 m | 0 / — | 1002 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-antigonish/clean/unknown-off/fuel-off` | 310.8 | 0% | 100% | 0% | 0 | 310.8 km | 0% | 0 m | 0 / — | 76 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-antigonish/clean/unknown-off/fuel-on` | 236.8 | 14% | 86% | 3% | 0 | 236.8 km | 0% | 0 m | 0 / — | 1027 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `musq-sherbrooke/dirt/unknown-off/fuel-off` | 64.3 | 92% | 8% | 9% | 0 | 64.3 km | 0% | 0 m | 0 / — | 48 | ✓ dirt ≥70<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `musq-sherbrooke/dirt/unknown-off/fuel-on` | 64.3 | 92% | 8% | 9% | 0 | 64.3 km | 0% | 0 m | 0 / — | 47 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `musq-sherbrooke/dirt/unknown-on/fuel-off` | 64.3 | 92% | 8% | 9% | 0 | 64.3 km | 0% | 0 m | 0 / — | 43 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `musq-sherbrooke/dirt/unknown-on/fuel-on` | 64.3 | 92% | 8% | 9% | 0 | 64.3 km | 0% | 0 m | 0 / — | 45 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `musq-sherbrooke/balanced/unknown-off/fuel-off` | 55.1 | 40% | 60% | 0% | 0 | 55.1 km | 0% | 0 m | 0 / — | 593 | ✗ balanced 45–55 (40%)<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `musq-sherbrooke/balanced/unknown-off/fuel-on` | 55.1 | 40% | 60% | 0% | 0 | 55.1 km | 0% | 0 m | 0 / — | 585 | ✗ balanced 45–55 (40%)<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `musq-sherbrooke/direct/unknown-off/fuel-off` | 55.2 | 40% | 60% | 0% | 0 | 55.2 km | 0% | 0 m | 0 / — | 9 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `musq-sherbrooke/direct/unknown-off/fuel-on` | 55.2 | 40% | 60% | 0% | 0 | 55.2 km | 0% | 0 m | 0 / — | 10 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `musq-sherbrooke/clean/unknown-off/fuel-off` | 56.9 | 0% | 100% | 0% | 0 | 56.9 km | 0% | 0 m | 0 / — | 3 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `musq-sherbrooke/clean/unknown-off/fuel-on` | 56.9 | 0% | 100% | 0% | 0 | 56.9 km | 0% | 0 m | 0 / — | 3 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `antigonish-sydney/dirt/unknown-off/fuel-off` | 332.8 | 82% | 18% | 6% | 0 | 332.8 km | 0% | 0 m | 0 / — | 395 | ✓ dirt ≥70<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `antigonish-sydney/dirt/unknown-off/fuel-on` | 237.3 | 25% | 75% | 4% | 0 | 237.3 km | 0% | 0 m | 0 / — | 1732 | ✗ dirt ≥70 (25%)<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `antigonish-sydney/dirt/unknown-on/fuel-off` | 348.0 | 85% | 15% | 7% | 0 | 348.0 km | 0% | 0 m | 0 / — | 416 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `antigonish-sydney/dirt/unknown-on/fuel-on` | 237.4 | 23% | 77% | 3% | 0 | 237.4 km | 0% | 0 m | 0 / — | 1837 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `antigonish-sydney/balanced/unknown-off/fuel-off` | 243.3 | 47% | 53% | 0% | 0 | 243.3 km | 0% | 0 m | 0 / — | 492 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `antigonish-sydney/balanced/unknown-off/fuel-on` | 234.8 | 34% | 66% | 1% | 0 | 234.8 km | 0% | 0 m | 0 / — | 1784 | ✗ balanced 45–55 (34%)<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `antigonish-sydney/direct/unknown-off/fuel-off` | 277.8 | 49% | 51% | 7% | 0 | 277.8 km | 0% | 0 m | 0 / — | 101 | ✗ direct ≤shortest+15km (277832m vs 219886m)<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `antigonish-sydney/direct/unknown-off/fuel-on` | 237.3 | 16% | 84% | 5% | 0 | 237.3 km | 0% | 0 m | 0 / — | 1387 | ✗ direct ≤shortest+15km (237293m vs 219886m)<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `antigonish-sydney/clean/unknown-off/fuel-off` | 338.6 | 0% | 100% | 0% | 0 | 338.6 km | 0% | 0 m | 0 / — | 135 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `antigonish-sydney/clean/unknown-off/fuel-on` | 237.4 | 0% | 100% | 0% | 0 | 237.4 km | 0% | 0 m | 0 / — | 1035 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `through-halifax/dirt/unknown-off/fuel-off` | — | — | — | — | — | — km | — | — | 0 / — | 3262 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤4000ms per hop |
| 🔴 | `through-halifax/dirt/unknown-off/fuel-on` | — | — | — | — | — | — km | — | — | 0 / — | 3173 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤4000ms per hop |
| 🟢 | `through-halifax/dirt/unknown-on/fuel-off` | 198.7 | 87% | 13% | 27% | 0 | 198.7 km | 0% | 0 m | 0 / — | 184 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `through-halifax/dirt/unknown-on/fuel-on` | 198.7 | 87% | 13% | 27% | 0 | 198.7 km | 0% | 0 m | 0 / — | 181 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `through-halifax/balanced/unknown-off/fuel-off` | — | — | — | — | — | — km | — | — | 0 / — | 18182 | ✗ route complete (baseline leg 1: no_route)<br>✗ ≤4000ms per hop (18182ms) |
| 🔴 | `through-halifax/balanced/unknown-off/fuel-on` | — | — | — | — | — | — km | — | — | 0 / — | 17835 | ✗ route complete (baseline leg 1: no_route)<br>✗ ≤4000ms per hop (17835ms) |
| 🔴 | `through-halifax/direct/unknown-off/fuel-off` | — | — | — | — | — | — km | — | — | 0 / — | 72 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤4000ms per hop |
| 🔴 | `through-halifax/direct/unknown-off/fuel-on` | — | — | — | — | — | — km | — | — | 0 / — | 55 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤4000ms per hop |
| 🟢 | `through-halifax/clean/unknown-off/fuel-off` | 309.8 | 0% | 100% | 0% | 0 | 309.8 km | 0% | 0 m | 0 / — | 282 | ✓ clean ≤15<br>✓ urban wall<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `through-halifax/clean/unknown-off/fuel-on` | 165.1 | 20% | 80% | 4% | 0 | 165.1 km | 0% | 0 m | 0 / — | 1268 | ✗ clean ≤15 (20%)<br>✓ urban wall<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `three-waypoint/dirt/unknown-off/fuel-off` | 576.9 | 82% | 18% | 7.1% | 0 | 283.2 km | 1.8% | 0 m | 0 / — | 547 | ✓ dirt ≥70<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `three-waypoint/dirt/unknown-off/fuel-on` | — | — | — | — | — | — km | — | — | 0 / — | 9714 | ✗ route complete (fuel leg 3: no_route_connected_fuel_chain)<br>✗ ≤4000ms per hop (9714ms) |
| 🟢 | `three-waypoint/dirt/unknown-on/fuel-off` | 506.9 | 83.1% | 16.9% | 5.6% | 0 | 254.9 km | 0.8% | 0 m | 0 / — | 706 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `three-waypoint/dirt/unknown-on/fuel-on` | — | — | — | — | — | — km | — | — | 0 / — | 11390 | ✗ route complete (fuel leg 3: no_route_connected_fuel_chain)<br>✗ ≤4000ms per hop (11390ms) |
| 🟢 | `three-waypoint/balanced/unknown-off/fuel-off` | 415.3 | 49.3% | 50.7% | 1.5% | 0 | 182.5 km | 0.2% | 0 m | 0 / — | 1409 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `three-waypoint/balanced/unknown-off/fuel-on` | 602.3 | 50.7% | 49.3% | 4.7% | 2 | 201.3 km | 0.3% | 0 m | 12 / 51%,50% | 7915 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `three-waypoint/direct/unknown-off/fuel-off` | 477.0 | 57.9% | 42.1% | 7.4% | 0 | 217.7 km | 0.6% | 0 m | 0 / — | 109 | ✗ direct ≤shortest+15km (477016m vs 374975m)<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `three-waypoint/direct/unknown-off/fuel-on` | 623.5 | 49% | 51% | 9.9% | 2 | 227.1 km | 2.2% | 0 m | 12 / 58%,52% | 3225 | ✗ direct ≤shortest+15km (623481m vs 374975m)<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `three-waypoint/clean/unknown-off/fuel-off` | 597.1 | 0% | 100% | 0% | 0 | 351.1 km | 8.2% | 0 m | 0 / — | 129 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `three-waypoint/clean/unknown-off/fuel-on` | — | — | — | — | — | — km | — | — | 0 / — | 2366 | ✗ route complete (fuel leg 2: no_route_connected_fuel_chain)<br>✓ ≤4000ms per hop |

Red rows: `short-no-fuel/balanced/unknown-off/fuel-off`, `dartmouth-capebreton/dirt/unknown-off/fuel-on`, `dartmouth-capebreton/dirt/unknown-on/fuel-on`, `dartmouth-capebreton/direct/unknown-off/fuel-off`, `dartmouth-capebreton/direct/unknown-off/fuel-on`, `dartmouth-antigonish/dirt/unknown-off/fuel-on`, `dartmouth-antigonish/direct/unknown-off/fuel-off`, `musq-sherbrooke/balanced/unknown-off/fuel-off`, `musq-sherbrooke/balanced/unknown-off/fuel-on`, `antigonish-sydney/dirt/unknown-off/fuel-on`, `antigonish-sydney/balanced/unknown-off/fuel-on`, `antigonish-sydney/direct/unknown-off/fuel-off`, `antigonish-sydney/direct/unknown-off/fuel-on`, `through-halifax/dirt/unknown-off/fuel-off`, `through-halifax/dirt/unknown-off/fuel-on`, `through-halifax/balanced/unknown-off/fuel-off`, `through-halifax/balanced/unknown-off/fuel-on`, `through-halifax/direct/unknown-off/fuel-off`, `through-halifax/direct/unknown-off/fuel-on`, `through-halifax/clean/unknown-off/fuel-on`, `three-waypoint/dirt/unknown-off/fuel-on`, `three-waypoint/dirt/unknown-on/fuel-on`, `three-waypoint/direct/unknown-off/fuel-off`, `three-waypoint/direct/unknown-off/fuel-on`, `three-waypoint/clean/unknown-off/fuel-on`. These are measurements, not blocked tests.
