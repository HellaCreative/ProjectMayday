# Nova Scotia routing benchmark

Git `42c8d48` · 2026-08-23T02:02:22.413Z · seed `3511091208` · 33/40 cases green
Live source: `https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/ns-osm-20260821-02/ns`

| Result | Case | km | Dirt | Paved | Unknown | Stops | Max hop | Backtrack | Restricted | Candidates / chosen dirt | ms | Assertions |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | --- |
| 🟢 | `short-no-fuel/dirt/unknown-off/fuel-planned` | 8.9 | 34% | 66% | 14% | 0 | 8.9 km | 0% | 0 m | 0 / — | 141 | ✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `short-no-fuel/dirt/unknown-on/fuel-planned` | 8.9 | 34% | 66% | 14% | 0 | 8.9 km | 0% | 0 m | 0 / — | 29 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `short-no-fuel/balanced/unknown-off/fuel-planned` | 9.9 | 38% | 62% | 19% | 0 | 9.9 km | 0% | 0 m | 0 / — | 143 | ✗ balanced 45–55 (38%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `short-no-fuel/direct/unknown-off/fuel-planned` | 8.1 | 19% | 81% | 11% | 0 | 8.1 km | 0% | 0 m | 0 / — | 47 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `short-no-fuel/clean/unknown-off/fuel-planned` | 7.6 | 6% | 94% | 5% | 0 | 7.6 km | 0% | 0 m | 0 / — | 188 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/dirt/unknown-off/fuel-planned` | 484.6 | 84% | 16% | 7% | 0 | 484.6 km | 0% | 0 m | 12 / — | 24595 | ✓ dirt ≥70<br>✓ fuel gap labelled<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/dirt/unknown-on/fuel-planned` | 440.8 | 83.7% | 16.3% | 4.6% | 1 | 232.4 km | 3% | 0 m | 6 / 89% | 8310 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/balanced/unknown-off/fuel-planned` | 375.8 | 49.5% | 50.5% | 5.3% | 1 | 201.0 km | 0.1% | 0 m | 6 / 50% | 5562 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/direct/unknown-off/fuel-planned` | 321.3 | 33.4% | 66.6% | 0.7% | 1 | 221.6 km | 0.1% | 0 m | 6 / 48% | 2261 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/clean/unknown-off/fuel-planned` | 336.7 | 0% | 100% | 0% | 1 | 234.9 km | 0.1% | 0 m | 6 / 0% | 2221 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-antigonish/dirt/unknown-off/fuel-planned` | 409.4 | 87.3% | 12.7% | 3.5% | 1 | 236.3 km | 3.5% | 0 m | 6 / 86% | 8096 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `dartmouth-antigonish/dirt/unknown-on/fuel-planned` | 270.7 | 90% | 10% | 5% | 0 | 270.7 km | 0% | 0 m | 6 / — | 13902 | ✓ fuel gap labelled<br>✓ no unexplained backtrack<br>✗ ≤6000ms per hop (6286ms) |
| 🟢 | `dartmouth-antigonish/balanced/unknown-off/fuel-planned` | 229.1 | 50% | 50% | 1% | 0 | 229.1 km | 0% | 0 m | 0 / — | 690 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-antigonish/direct/unknown-off/fuel-planned` | 230.7 | 48.7% | 51.3% | 1% | 1 | 224.7 km | 0.1% | 0 m | 6 / 50% | 2261 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-antigonish/clean/unknown-off/fuel-planned` | 240.2 | 0% | 100% | 0% | 1 | 234.0 km | 0% | 0 m | 6 / 0% | 2059 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `musq-sherbrooke/dirt/unknown-off/fuel-planned` | 64.3 | 92% | 8% | 9% | 0 | 64.3 km | 0% | 0 m | 0 / — | 44 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `musq-sherbrooke/dirt/unknown-on/fuel-planned` | 64.3 | 92% | 8% | 9% | 0 | 64.3 km | 0% | 0 m | 0 / — | 43 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `musq-sherbrooke/balanced/unknown-off/fuel-planned` | 73.6 | 58% | 42% | 0% | 0 | 73.6 km | 0% | 0 m | 0 / — | 136 | ✗ balanced 45–55 (58%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `musq-sherbrooke/direct/unknown-off/fuel-planned` | 55.2 | 40% | 60% | 0% | 0 | 55.2 km | 0% | 0 m | 0 / — | 26 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `musq-sherbrooke/clean/unknown-off/fuel-planned` | 56.9 | 0% | 100% | 0% | 0 | 56.9 km | 0% | 0 m | 0 / — | 3 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `antigonish-sydney/dirt/unknown-off/fuel-planned` | 312.5 | 62.6% | 37.4% | 8% | 1 | 237.5 km | 2.6% | 0 m | 6 / 96% | 5887 | ✗ dirt ≥70 (62.6%)<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/dirt/unknown-on/fuel-planned` | 312.5 | 62.6% | 37.4% | 8% | 1 | 237.5 km | 2.6% | 0 m | 6 / 96% | 7002 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/balanced/unknown-off/fuel-planned` | 316.2 | 48% | 52% | 2.5% | 1 | 163.3 km | 0% | 0 m | 6 / 49% | 5416 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/direct/unknown-off/fuel-planned` | 234.9 | 11% | 89% | 3% | 0 | 234.9 km | 0% | 0 m | 0 / — | 289 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/clean/unknown-off/fuel-planned` | 240.9 | 0% | 100% | 0% | 1 | 235.4 km | 0% | 0 m | 6 / 0% | 1730 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `through-halifax/dirt/unknown-off/fuel-planned` | — | — | — | — | — | — km | — | — | 0 / — | 3175 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤6000ms per hop |
| 🟢 | `through-halifax/dirt/unknown-on/fuel-planned` | 198.7 | 87% | 13% | 27% | 0 | 198.7 km | 0% | 0 m | 0 / — | 219 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `through-halifax/balanced/unknown-off/fuel-planned` | — | — | — | — | — | — km | — | — | 0 / — | 2585 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤6000ms per hop |
| 🔴 | `through-halifax/direct/unknown-off/fuel-planned` | — | — | — | — | — | — km | — | — | 0 / — | 1746 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤6000ms per hop |
| 🟢 | `through-halifax/clean/unknown-off/fuel-planned` | 246.4 | 0.1% | 99.9% | 0% | 1 | 237.5 km | 0.1% | 0 m | 6 / 0% | 2987 | ✓ clean ≤15<br>✓ urban wall<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/dirt/unknown-off/fuel-planned` | 576.9 | 82% | 18% | 7.1% | 0 | 283.2 km | 1.8% | 0 m | 0 / — | 21795 | ✓ dirt ≥70<br>✓ fuel gap labelled<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/dirt/unknown-on/fuel-planned` | 506.9 | 83.1% | 16.9% | 5.6% | 0 | 254.9 km | 0.8% | 0 m | 0 / — | 37826 | ✓ fuel gap labelled<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/balanced/unknown-off/fuel-planned` | 460.0 | 49.2% | 50.8% | 3.8% | 1 | 161.7 km | 0.2% | 0 m | 6 / 50% | 15926 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/direct/unknown-off/fuel-planned` | 384.5 | 38.3% | 61.7% | 1.4% | 1 | 136.6 km | 0.7% | 0 m | 6 / 31% | 5924 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/clean/unknown-off/fuel-planned` | 498.4 | 4.3% | 95.7% | 0% | 2 | 173.2 km | 4.1% | 0 m | 9 / 30%,0% | 13152 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/dirt/unknown-off/fuel-planned` | 576.9 | 82% | 18% | 7.1% | 0 | 283.2 km | 1.8% | 0 m | 0 / — | 22044 | ✓ dirt ≥70<br>✓ fuel gap labelled<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/dirt/unknown-on/fuel-planned` | 575.7 | 83.8% | 16.2% | 6.4% | 1 | 223.9 km | 2.1% | 0 m | 6 / 89% | 20806 | ✓ fuel gap labelled<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/balanced/unknown-off/fuel-planned` | 460.0 | 49.2% | 50.8% | 3.8% | 1 | 161.7 km | 0.2% | 0 m | 6 / 50% | 15529 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/direct/unknown-off/fuel-planned` | 384.5 | 38.3% | 61.7% | 1.4% | 1 | 136.6 km | 0.7% | 0 m | 6 / 31% | 5799 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/clean/unknown-off/fuel-planned` | 498.4 | 4.3% | 95.7% | 0% | 2 | 173.2 km | 4.1% | 0 m | 9 / 30%,0% | 13188 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |

Red rows: `short-no-fuel/balanced/unknown-off/fuel-planned`, `dartmouth-antigonish/dirt/unknown-on/fuel-planned`, `musq-sherbrooke/balanced/unknown-off/fuel-planned`, `antigonish-sydney/dirt/unknown-off/fuel-planned`, `through-halifax/dirt/unknown-off/fuel-planned`, `through-halifax/balanced/unknown-off/fuel-planned`, `through-halifax/direct/unknown-off/fuel-planned`. These are measurements, not blocked tests.
