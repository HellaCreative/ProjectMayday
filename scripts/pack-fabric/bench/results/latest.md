# Nova Scotia routing benchmark

Git `a965d91` · 2026-08-22T20:43:19.986Z · seed `3511091208` · 41/65 cases green
Live source: `https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/ns`

| Result | Case | km | Dirt | Paved | Unknown | Stops | Max hop | Backtrack | Restricted | Candidates / chosen dirt | ms | Assertions |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | --- |
| 🟢 | `short-no-fuel/dirt/unknown-off/fuel-off` | 8.9 | 34% | 66% | 14% | 0 | 8.9 km | 0% | 0 m | 0 / — | 2690 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `short-no-fuel/dirt/unknown-on/fuel-off` | 8.9 | 34% | 66% | 14% | 0 | 8.9 km | 0% | 0 m | 0 / — | 16 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `short-no-fuel/balanced/unknown-off/fuel-off` | 10.8 | 44% | 56% | 18% | 0 | 10.8 km | 0% | 0 m | 0 / — | 95 | ✓ balanced 35–65<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `short-no-fuel/direct/unknown-off/fuel-off` | 8.1 | 19% | 81% | 11% | 0 | 8.1 km | 0% | 0 m | 0 / — | 9 | ✗ direct dirt ≥60 (19%)<br>✓ direct corridor ≤25km<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `short-no-fuel/clean/unknown-off/fuel-off` | 7.6 | 6% | 94% | 5% | 0 | 7.6 km | 0% | 0 m | 0 / — | 142 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-capebreton/dirt/unknown-off/fuel-off` | 484.6 | 84% | 16% | 7% | 0 | 484.6 km | 0% | 0 m | 0 / — | 197 | ✓ dirt ≥70<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `dartmouth-capebreton/dirt/unknown-off/fuel-on` | 469.2 | 62.8% | 37.2% | 8.5% | 1 | 237.2 km | 2.5% | 0 m | 6 / 77% | 2391 | ✗ dirt ≥70 (62.8%)<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-capebreton/dirt/unknown-on/fuel-off` | 441.3 | 87% | 13% | 6% | 0 | 441.3 km | 0% | 0 m | 0 / — | 183 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-capebreton/dirt/unknown-on/fuel-on` | 451.9 | 75.5% | 24.5% | 5.5% | 1 | 237.2 km | 0.8% | 0 m | 6 / 87% | 2624 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-capebreton/balanced/unknown-off/fuel-off` | 327.5 | 49% | 51% | 2% | 0 | 327.5 km | 0% | 0 m | 0 / — | 318 | ✓ balanced 35–65<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `dartmouth-capebreton/balanced/unknown-off/fuel-on` | — | — | — | — | — | — km | — | — | 0 / — | 3787 | ✗ route complete (fuel leg 1 hop 2: no_route)<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-capebreton/direct/unknown-off/fuel-off` | 424.9 | 66% | 34% | 10% | 0 | 424.9 km | 0% | 0 m | 0 / — | 91 | ✓ direct dirt ≥60<br>✓ direct corridor ≤25km<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `dartmouth-capebreton/direct/unknown-off/fuel-on` | — | — | — | — | — | — km | — | — | 0 / — | 1845 | ✗ route complete (fuel leg 1 hop 2: no_route)<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-capebreton/clean/unknown-off/fuel-off` | 418.4 | 0% | 100% | 0% | 0 | 418.4 km | 0% | 0 m | 0 / — | 147 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-capebreton/clean/unknown-off/fuel-on` | 336.7 | 0% | 100% | 0% | 1 | 234.9 km | 0.1% | 0 m | 6 / 0% | 1707 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-antigonish/dirt/unknown-off/fuel-off` | 303.3 | 87% | 13% | 6% | 0 | 303.3 km | 0% | 0 m | 0 / — | 111 | ✓ dirt ≥70<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `dartmouth-antigonish/dirt/unknown-off/fuel-on` | 237.1 | 54% | 46% | 3% | 0 | 237.1 km | 0% | 0 m | 0 / — | 1112 | ✗ dirt ≥70 (54%)<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-antigonish/dirt/unknown-on/fuel-off` | 270.7 | 90% | 10% | 5% | 0 | 270.7 km | 0% | 0 m | 0 / — | 108 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-antigonish/dirt/unknown-on/fuel-on` | 237.3 | 72% | 28% | 13% | 0 | 237.3 km | 0% | 0 m | 0 / — | 1210 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-antigonish/balanced/unknown-off/fuel-off` | 234.7 | 54% | 46% | 3% | 0 | 234.7 km | 0% | 0 m | 0 / — | 373 | ✓ balanced 35–65<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-antigonish/balanced/unknown-off/fuel-on` | 234.7 | 54% | 46% | 3% | 0 | 234.7 km | 0% | 0 m | 0 / — | 352 | ✓ balanced 35–65<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-antigonish/direct/unknown-off/fuel-off` | 310.3 | 69% | 31% | 3% | 0 | 310.3 km | 0% | 0 m | 0 / — | 65 | ✓ direct dirt ≥60<br>✓ direct corridor ≤25km<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `dartmouth-antigonish/direct/unknown-off/fuel-on` | 237.5 | 52% | 48% | 5% | 0 | 237.5 km | 0% | 0 m | 0 / — | 972 | ✗ direct dirt ≥60 (52%)<br>✓ direct corridor ≤25km<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-antigonish/clean/unknown-off/fuel-off` | 310.8 | 0% | 100% | 0% | 0 | 310.8 km | 0% | 0 m | 0 / — | 82 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-antigonish/clean/unknown-off/fuel-on` | 236.8 | 14% | 86% | 3% | 0 | 236.8 km | 0% | 0 m | 0 / — | 1167 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `musq-sherbrooke/dirt/unknown-off/fuel-off` | 64.3 | 92% | 8% | 9% | 0 | 64.3 km | 0% | 0 m | 0 / — | 18 | ✓ dirt ≥70<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `musq-sherbrooke/dirt/unknown-off/fuel-on` | 64.3 | 92% | 8% | 9% | 0 | 64.3 km | 0% | 0 m | 0 / — | 18 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `musq-sherbrooke/dirt/unknown-on/fuel-off` | 64.3 | 92% | 8% | 9% | 0 | 64.3 km | 0% | 0 m | 0 / — | 18 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `musq-sherbrooke/dirt/unknown-on/fuel-on` | 64.3 | 92% | 8% | 9% | 0 | 64.3 km | 0% | 0 m | 0 / — | 18 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `musq-sherbrooke/balanced/unknown-off/fuel-off` | 55.1 | 40% | 60% | 0% | 0 | 55.1 km | 0% | 0 m | 0 / — | 567 | ✓ balanced 35–65<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `musq-sherbrooke/balanced/unknown-off/fuel-on` | 55.1 | 40% | 60% | 0% | 0 | 55.1 km | 0% | 0 m | 0 / — | 461 | ✓ balanced 35–65<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `musq-sherbrooke/direct/unknown-off/fuel-off` | 55.2 | 40% | 60% | 0% | 0 | 55.2 km | 0% | 0 m | 0 / — | 9 | ✗ direct dirt ≥60 (40%)<br>✓ direct corridor ≤25km<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `musq-sherbrooke/direct/unknown-off/fuel-on` | 55.2 | 40% | 60% | 0% | 0 | 55.2 km | 0% | 0 m | 0 / — | 10 | ✗ direct dirt ≥60 (40%)<br>✓ direct corridor ≤25km<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `musq-sherbrooke/clean/unknown-off/fuel-off` | 56.9 | 0% | 100% | 0% | 0 | 56.9 km | 0% | 0 m | 0 / — | 3 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `musq-sherbrooke/clean/unknown-off/fuel-on` | 56.9 | 0% | 100% | 0% | 0 | 56.9 km | 0% | 0 m | 0 / — | 3 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `antigonish-sydney/dirt/unknown-off/fuel-off` | 332.8 | 82% | 18% | 6% | 0 | 332.8 km | 0% | 0 m | 0 / — | 103 | ✓ dirt ≥70<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `antigonish-sydney/dirt/unknown-off/fuel-on` | 237.3 | 25% | 75% | 4% | 0 | 237.3 km | 0% | 0 m | 0 / — | 1042 | ✗ dirt ≥70 (25%)<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `antigonish-sydney/dirt/unknown-on/fuel-off` | 348.0 | 85% | 15% | 7% | 0 | 348.0 km | 0% | 0 m | 0 / — | 123 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `antigonish-sydney/dirt/unknown-on/fuel-on` | 237.4 | 23% | 77% | 3% | 0 | 237.4 km | 0% | 0 m | 0 / — | 1328 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `antigonish-sydney/balanced/unknown-off/fuel-off` | 298.0 | 52% | 48% | 1% | 0 | 298.0 km | 0% | 0 m | 0 / — | 515 | ✓ balanced 35–65<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `antigonish-sydney/balanced/unknown-off/fuel-on` | — | — | — | — | — | — km | — | — | 0 / — | 1529 | ✗ route complete (fuel leg 1 hop 1: no_route)<br>✓ ≤4000ms per hop |
| 🔴 | `antigonish-sydney/direct/unknown-off/fuel-off` | 317.7 | 50% | 50% | 4% | 0 | 317.7 km | 0% | 0 m | 0 / — | 75 | ✗ direct dirt ≥60 (50%)<br>✓ direct corridor ≤25km<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `antigonish-sydney/direct/unknown-off/fuel-on` | — | — | — | — | — | — km | — | — | 0 / — | 1049 | ✗ route complete (fuel leg 1 hop 1: no_route)<br>✓ ≤4000ms per hop |
| 🟢 | `antigonish-sydney/clean/unknown-off/fuel-off` | 338.6 | 0% | 100% | 0% | 0 | 338.6 km | 0% | 0 m | 0 / — | 138 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `antigonish-sydney/clean/unknown-off/fuel-on` | 237.4 | 0% | 100% | 0% | 0 | 237.4 km | 0% | 0 m | 0 / — | 966 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `through-halifax/dirt/unknown-off/fuel-off` | — | — | — | — | — | — km | — | — | 0 / — | 494 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤4000ms per hop |
| 🔴 | `through-halifax/dirt/unknown-off/fuel-on` | — | — | — | — | — | — km | — | — | 0 / — | 496 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤4000ms per hop |
| 🟢 | `through-halifax/dirt/unknown-on/fuel-off` | 198.7 | 87% | 13% | 27% | 0 | 198.7 km | 0% | 0 m | 0 / — | 56 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `through-halifax/dirt/unknown-on/fuel-on` | 198.7 | 87% | 13% | 27% | 0 | 198.7 km | 0% | 0 m | 0 / — | 56 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `through-halifax/balanced/unknown-off/fuel-off` | — | — | — | — | — | — km | — | — | 0 / — | 596 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤4000ms per hop |
| 🔴 | `through-halifax/balanced/unknown-off/fuel-on` | — | — | — | — | — | — km | — | — | 0 / — | 582 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤4000ms per hop |
| 🔴 | `through-halifax/direct/unknown-off/fuel-off` | — | — | — | — | — | — km | — | — | 0 / — | 11 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤4000ms per hop |
| 🔴 | `through-halifax/direct/unknown-off/fuel-on` | — | — | — | — | — | — km | — | — | 0 / — | 12 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤4000ms per hop |
| 🟢 | `through-halifax/clean/unknown-off/fuel-off` | 309.8 | 0% | 100% | 0% | 0 | 309.8 km | 0% | 0 m | 0 / — | 345 | ✓ clean ≤15<br>✓ urban wall<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `through-halifax/clean/unknown-off/fuel-on` | 165.1 | 20% | 80% | 4% | 0 | 165.1 km | 0% | 0 m | 0 / — | 1388 | ✗ clean ≤15 (20%)<br>✓ urban wall<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `three-waypoint/dirt/unknown-off/fuel-off` | 576.9 | 82% | 18% | 7.1% | 0 | 283.2 km | 1.8% | 0 m | 0 / — | 172 | ✓ dirt ≥70<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `three-waypoint/dirt/unknown-off/fuel-on` | — | — | — | — | — | — km | — | — | 0 / — | 4416 | ✗ route complete (fuel leg 3: no_route_connected_fuel_chain)<br>✗ ≤4000ms per hop (4416ms) |
| 🟢 | `three-waypoint/dirt/unknown-on/fuel-off` | 506.9 | 83.1% | 16.9% | 5.6% | 0 | 254.9 km | 0.8% | 0 m | 0 / — | 209 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `three-waypoint/dirt/unknown-on/fuel-on` | — | — | — | — | — | — km | — | — | 0 / — | 5109 | ✗ route complete (fuel leg 3: no_route_connected_fuel_chain)<br>✗ ≤4000ms per hop (5109ms) |
| 🟢 | `three-waypoint/balanced/unknown-off/fuel-off` | 409.7 | 51.2% | 48.8% | 1.8% | 0 | 183.6 km | 0.2% | 0 m | 0 / — | 686 | ✓ balanced 35–65<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `three-waypoint/balanced/unknown-off/fuel-on` | 593.5 | 49.2% | 50.8% | 2.4% | 2 | 206.8 km | 3.7% | 0 m | 12 / 50%,50% | 6444 | ✓ balanced 35–65<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `three-waypoint/direct/unknown-off/fuel-off` | 477.0 | 57.9% | 42.1% | 7.4% | 0 | 217.7 km | 0.6% | 0 m | 0 / — | 98 | ✗ direct dirt ≥60 (57.9%)<br>✓ direct corridor ≤25km<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `three-waypoint/direct/unknown-off/fuel-on` | 623.5 | 49% | 51% | 9.9% | 2 | 227.1 km | 2.2% | 0 m | 12 / 58%,52% | 3048 | ✗ direct dirt ≥60 (49%)<br>✓ direct corridor ≤25km<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `three-waypoint/clean/unknown-off/fuel-off` | 597.1 | 0% | 100% | 0% | 0 | 351.1 km | 8.2% | 0 m | 0 / — | 150 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `three-waypoint/clean/unknown-off/fuel-on` | — | — | — | — | — | — km | — | — | 0 / — | 2522 | ✗ route complete (fuel leg 2: no_route_connected_fuel_chain)<br>✓ ≤4000ms per hop |

Red rows: `short-no-fuel/direct/unknown-off/fuel-off`, `dartmouth-capebreton/dirt/unknown-off/fuel-on`, `dartmouth-capebreton/balanced/unknown-off/fuel-on`, `dartmouth-capebreton/direct/unknown-off/fuel-on`, `dartmouth-antigonish/dirt/unknown-off/fuel-on`, `dartmouth-antigonish/direct/unknown-off/fuel-on`, `musq-sherbrooke/direct/unknown-off/fuel-off`, `musq-sherbrooke/direct/unknown-off/fuel-on`, `antigonish-sydney/dirt/unknown-off/fuel-on`, `antigonish-sydney/balanced/unknown-off/fuel-on`, `antigonish-sydney/direct/unknown-off/fuel-off`, `antigonish-sydney/direct/unknown-off/fuel-on`, `through-halifax/dirt/unknown-off/fuel-off`, `through-halifax/dirt/unknown-off/fuel-on`, `through-halifax/balanced/unknown-off/fuel-off`, `through-halifax/balanced/unknown-off/fuel-on`, `through-halifax/direct/unknown-off/fuel-off`, `through-halifax/direct/unknown-off/fuel-on`, `through-halifax/clean/unknown-off/fuel-on`, `three-waypoint/dirt/unknown-off/fuel-on`, `three-waypoint/dirt/unknown-on/fuel-on`, `three-waypoint/direct/unknown-off/fuel-off`, `three-waypoint/direct/unknown-off/fuel-on`, `three-waypoint/clean/unknown-off/fuel-on`. These are measurements, not blocked tests.
