# Nova Scotia routing benchmark

Git `1da4442` · 2026-08-22T16:09:13.808Z · seed `3511091208` · 35/40 cases green
Live source: `https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/ns-osm-20260821-02/ns`

| Result | Case | km | Dirt | Paved | Unknown | Stops | Max hop | Backtrack | Restricted | Candidates / chosen dirt | ms | Assertions |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | --- |
| 🟢 | `short-no-fuel/dirt/unknown-off/fuel-planned` | 8.9 | 34% | 66% | 14% | 0 | 8.9 km | 0% | 0 m | 0 / — | 122 | ✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `short-no-fuel/dirt/unknown-on/fuel-planned` | 8.9 | 34% | 66% | 14% | 0 | 8.9 km | 0% | 0 m | 0 / — | 25 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `short-no-fuel/balanced/unknown-off/fuel-planned` | 9.9 | 38% | 62% | 19% | 0 | 9.9 km | 0% | 0 m | 0 / — | 134 | ✗ balanced 45–55 (38%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `short-no-fuel/direct/unknown-off/fuel-planned` | 8.1 | 19% | 81% | 11% | 0 | 8.1 km | 0% | 0 m | 0 / — | 47 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `short-no-fuel/clean/unknown-off/fuel-planned` | 7.6 | 6% | 94% | 5% | 0 | 7.6 km | 0% | 0 m | 0 / — | 124 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/dirt/unknown-off/fuel-planned` | 484.6 | 84% | 16% | 7% | 0 | 484.6 km | 0% | 0 m | 12 / — | 17193 | ✓ dirt ≥70<br>✓ fuel gap labelled<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/dirt/unknown-on/fuel-planned` | 440.8 | 83.7% | 16.3% | 4.6% | 1 | 232.4 km | 3% | 0 m | 6 / 89% | 7267 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/balanced/unknown-off/fuel-planned` | 375.8 | 49.5% | 50.5% | 5.3% | 1 | 201.0 km | 0.1% | 0 m | 6 / 50% | 5793 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/direct/unknown-off/fuel-planned` | 321.3 | 33.4% | 66.6% | 0.7% | 1 | 221.6 km | 0.1% | 0 m | 6 / 48% | 1908 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/clean/unknown-off/fuel-planned` | 336.7 | 0% | 100% | 0% | 1 | 234.9 km | 0.1% | 0 m | 6 / 0% | 1841 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-antigonish/dirt/unknown-off/fuel-planned` | 360.2 | 87.4% | 12.6% | 3.8% | 1 | 228.3 km | 1.3% | 0 m | 6 / 87% | 6586 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-antigonish/dirt/unknown-on/fuel-planned` | 297.2 | 87.2% | 12.8% | 3.6% | 1 | 208.4 km | 4.5% | 0 m | 6 / 89% | 6317 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-antigonish/balanced/unknown-off/fuel-planned` | 229.1 | 50% | 50% | 1% | 0 | 229.1 km | 0% | 0 m | 0 / — | 353 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-antigonish/direct/unknown-off/fuel-planned` | 228.5 | 47.2% | 52.8% | 0.9% | 1 | 202.6 km | 0.1% | 0 m | 6 / 2% | 1866 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-antigonish/clean/unknown-off/fuel-planned` | 414.3 | 0% | 100% | 0% | 1 | 233.6 km | 0% | 0 m | 6 / 0% | 1863 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `musq-sherbrooke/dirt/unknown-off/fuel-planned` | 64.3 | 92% | 8% | 9% | 0 | 64.3 km | 0% | 0 m | 0 / — | 45 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `musq-sherbrooke/dirt/unknown-on/fuel-planned` | 64.3 | 92% | 8% | 9% | 0 | 64.3 km | 0% | 0 m | 0 / — | 43 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `musq-sherbrooke/balanced/unknown-off/fuel-planned` | 73.6 | 58% | 42% | 0% | 0 | 73.6 km | 0% | 0 m | 0 / — | 116 | ✗ balanced 45–55 (58%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `musq-sherbrooke/direct/unknown-off/fuel-planned` | 55.2 | 40% | 60% | 0% | 0 | 55.2 km | 0% | 0 m | 0 / — | 23 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `musq-sherbrooke/clean/unknown-off/fuel-planned` | 56.9 | 0% | 100% | 0% | 0 | 56.9 km | 0% | 0 m | 0 / — | 3 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/dirt/unknown-off/fuel-planned` | 472.9 | 84.5% | 15.5% | 4.5% | 1 | 237.1 km | 0% | 0 m | 6 / 81% | 4245 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/dirt/unknown-on/fuel-planned` | 448.8 | 86.6% | 13.4% | 4.9% | 1 | 227.8 km | 0% | 0 m | 6 / 83% | 4448 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/balanced/unknown-off/fuel-planned` | 296.9 | 49.1% | 50.9% | 3.1% | 1 | 154.7 km | 0.1% | 0 m | 6 / 51% | 3376 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/direct/unknown-off/fuel-planned` | 234.9 | 11% | 89% | 3% | 0 | 234.9 km | 0% | 0 m | 0 / — | 194 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/clean/unknown-off/fuel-planned` | 338.7 | 0% | 100% | 0% | 1 | 235.9 km | 0% | 0 m | 6 / 0% | 1429 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `through-halifax/dirt/unknown-off/fuel-planned` | — | — | — | — | — | — km | — | — | 0 / — | 2524 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤6000ms per hop |
| 🟢 | `through-halifax/dirt/unknown-on/fuel-planned` | 198.7 | 87% | 13% | 27% | 0 | 198.7 km | 0% | 0 m | 0 / — | 178 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `through-halifax/balanced/unknown-off/fuel-planned` | — | — | — | — | — | — km | — | — | 0 / — | 2275 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤6000ms per hop |
| 🔴 | `through-halifax/direct/unknown-off/fuel-planned` | — | — | — | — | — | — km | — | — | 0 / — | 1164 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤6000ms per hop |
| 🟢 | `through-halifax/clean/unknown-off/fuel-planned` | 240.7 | 13.5% | 86.5% | 2.5% | 1 | 201.2 km | 9.3% | 0 m | 6 / 16% | 2276 | ✓ clean ≤15<br>✓ urban wall<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/dirt/unknown-off/fuel-planned` | 588.8 | 71.8% | 28.2% | 6.8% | 1 | 237.2 km | 8.3% | 0 m | 6 / 96% | 20752 | ✓ dirt ≥70<br>✓ fuel gap labelled<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/dirt/unknown-on/fuel-planned` | 506.9 | 83.1% | 16.9% | 5.6% | 0 | 254.9 km | 0.8% | 0 m | 0 / — | 22800 | ✓ fuel gap labelled<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/balanced/unknown-off/fuel-planned` | 552.8 | 50.5% | 49.5% | 5.1% | 2 | 164.2 km | 0.2% | 0 m | 12 / 51%,50% | 15121 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/direct/unknown-off/fuel-planned` | 384.5 | 38.3% | 61.7% | 1.4% | 1 | 136.6 km | 0.7% | 0 m | 6 / 31% | 5311 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/clean/unknown-off/fuel-planned` | 455.7 | 4.8% | 95.2% | 0% | 2 | 113.9 km | 0.5% | 0 m | 12 / 0%,20% | 7902 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/dirt/unknown-off/fuel-planned` | 588.8 | 71.8% | 28.2% | 6.8% | 1 | 237.2 km | 8.3% | 0 m | 6 / 96% | 21027 | ✓ dirt ≥70<br>✓ fuel gap labelled<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/dirt/unknown-on/fuel-planned` | 506.9 | 83.1% | 16.9% | 5.6% | 0 | 254.9 km | 0.8% | 0 m | 0 / — | 22543 | ✓ fuel gap labelled<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/balanced/unknown-off/fuel-planned` | 552.8 | 50.5% | 49.5% | 5.1% | 2 | 164.2 km | 0.2% | 0 m | 12 / 51%,50% | 15584 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/direct/unknown-off/fuel-planned` | 384.5 | 38.3% | 61.7% | 1.4% | 1 | 136.6 km | 0.7% | 0 m | 6 / 31% | 5451 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/clean/unknown-off/fuel-planned` | 455.7 | 4.8% | 95.2% | 0% | 2 | 113.9 km | 0.5% | 0 m | 12 / 0%,20% | 8108 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |

Red rows: `short-no-fuel/balanced/unknown-off/fuel-planned`, `musq-sherbrooke/balanced/unknown-off/fuel-planned`, `through-halifax/dirt/unknown-off/fuel-planned`, `through-halifax/balanced/unknown-off/fuel-planned`, `through-halifax/direct/unknown-off/fuel-planned`. These are measurements, not blocked tests.
