# Nova Scotia routing benchmark

Git `5d0368c` · 2026-08-21T12:06:09.861Z · seed `3511091208` · 66/75 cases green
Live source: `https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/ns-osm-20260820-01/ns`

| Result | Case | km | Dirt | Paved | Unknown | Stops | Max hop | Backtrack | Restricted | Candidates / chosen dirt | ms | Assertions |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | --- |
| 🟢 | `short-no-fuel/dirt/unknown-off/fuel-off` | 8.9 | 34% | 66% | 14% | 0 | 8.9 km | 0% | 0 m | 0 / — | 117 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `short-no-fuel/dirt/unknown-on/fuel-off` | 8.9 | 34% | 66% | 14% | 0 | 8.9 km | 0% | 0 m | 0 / — | 24 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `short-no-fuel/balanced/unknown-off/fuel-off` | 9.9 | 38% | 62% | 19% | 0 | 9.9 km | 0% | 0 m | 0 / — | 101 | ✗ balanced 45–55 (38%)<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `short-no-fuel/direct/unknown-off/fuel-off` | 8.1 | 19% | 81% | 11% | 0 | 8.1 km | 0% | 0 m | 0 / — | 42 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `short-no-fuel/clean/unknown-off/fuel-off` | 7.6 | 6% | 94% | 5% | 0 | 7.6 km | 0% | 0 m | 0 / — | 124 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-capebreton/dirt/unknown-off/fuel-off` | 484.6 | 84% | 16% | 7% | 0 | 484.6 km | 0% | 0 m | 0 / — | 668 | ✓ dirt ≥70<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-capebreton/dirt/unknown-off/fuel-on` | 513.3 | 80.4% | 19.6% | 5.1% | 2 | 237.2 km | 0.9% | 0 m | 12 / 87%,73% | 9074 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/dirt/unknown-on/fuel-off` | 441.3 | 87% | 13% | 6% | 0 | 441.3 km | 0% | 0 m | 0 / — | 640 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-capebreton/dirt/unknown-on/fuel-on` | 440.8 | 83.7% | 16.3% | 4.6% | 1 | 232.4 km | 3% | 0 m | 6 / 89% | 6047 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/balanced/unknown-off/fuel-off` | 333.0 | 50% | 50% | 1% | 0 | 333.0 km | 0% | 0 m | 0 / — | 716 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-capebreton/balanced/unknown-off/fuel-on` | 375.8 | 49.5% | 50.5% | 5.3% | 1 | 201.0 km | 0.1% | 0 m | 6 / 50% | 4830 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/direct/unknown-off/fuel-off` | 335.7 | 38% | 62% | 4% | 0 | 335.7 km | 0% | 0 m | 0 / — | 261 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-capebreton/direct/unknown-off/fuel-on` | 321.3 | 33.4% | 66.6% | 0.7% | 1 | 221.6 km | 0.1% | 0 m | 6 / 48% | 1385 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/clean/unknown-off/fuel-off` | 418.4 | 0% | 100% | 0% | 0 | 418.4 km | 0% | 0 m | 0 / — | 107 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-capebreton/clean/unknown-off/fuel-on` | 336.7 | 0% | 100% | 0% | 1 | 234.9 km | 0.1% | 0 m | 6 / 0% | 1415 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-antigonish/dirt/unknown-off/fuel-off` | 303.3 | 87% | 13% | 6% | 0 | 303.3 km | 0% | 0 m | 0 / — | 337 | ✓ dirt ≥70<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-antigonish/dirt/unknown-off/fuel-on` | 360.2 | 87.4% | 12.6% | 3.8% | 1 | 228.3 km | 1.3% | 0 m | 6 / 87% | 5774 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-antigonish/dirt/unknown-on/fuel-off` | 270.7 | 90% | 10% | 5% | 0 | 270.7 km | 0% | 0 m | 0 / — | 351 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-antigonish/dirt/unknown-on/fuel-on` | 297.2 | 87.2% | 12.8% | 3.6% | 1 | 208.4 km | 4.5% | 0 m | 6 / 89% | 5817 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-antigonish/balanced/unknown-off/fuel-off` | 229.1 | 50% | 50% | 1% | 0 | 229.1 km | 0% | 0 m | 0 / — | 353 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-antigonish/balanced/unknown-off/fuel-on` | 229.1 | 50% | 50% | 1% | 0 | 229.1 km | 0% | 0 m | 0 / — | 334 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-antigonish/direct/unknown-off/fuel-off` | 243.4 | 52% | 48% | 5% | 0 | 243.4 km | 0% | 0 m | 0 / — | 201 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-antigonish/direct/unknown-off/fuel-on` | 228.5 | 47.2% | 52.8% | 0.9% | 1 | 202.6 km | 0.1% | 0 m | 6 / 2% | 1295 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-antigonish/clean/unknown-off/fuel-off` | 310.8 | 0% | 100% | 0% | 0 | 310.8 km | 0% | 0 m | 0 / — | 70 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `dartmouth-antigonish/clean/unknown-off/fuel-on` | 414.3 | 0% | 100% | 0% | 1 | 233.6 km | 0% | 0 m | 6 / 0% | 1397 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `musq-sherbrooke/dirt/unknown-off/fuel-off` | 64.3 | 92% | 8% | 9% | 0 | 64.3 km | 0% | 0 m | 0 / — | 45 | ✓ dirt ≥70<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `musq-sherbrooke/dirt/unknown-off/fuel-on` | 64.3 | 92% | 8% | 9% | 0 | 64.3 km | 0% | 0 m | 0 / — | 40 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `musq-sherbrooke/dirt/unknown-on/fuel-off` | 64.3 | 92% | 8% | 9% | 0 | 64.3 km | 0% | 0 m | 0 / — | 41 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `musq-sherbrooke/dirt/unknown-on/fuel-on` | 64.3 | 92% | 8% | 9% | 0 | 64.3 km | 0% | 0 m | 0 / — | 41 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `musq-sherbrooke/balanced/unknown-off/fuel-off` | 73.6 | 58% | 42% | 0% | 0 | 73.6 km | 0% | 0 m | 0 / — | 113 | ✗ balanced 45–55 (58%)<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🔴 | `musq-sherbrooke/balanced/unknown-off/fuel-on` | 73.6 | 58% | 42% | 0% | 0 | 73.6 km | 0% | 0 m | 0 / — | 119 | ✗ balanced 45–55 (58%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `musq-sherbrooke/direct/unknown-off/fuel-off` | 55.2 | 40% | 60% | 0% | 0 | 55.2 km | 0% | 0 m | 0 / — | 21 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `musq-sherbrooke/direct/unknown-off/fuel-on` | 55.2 | 40% | 60% | 0% | 0 | 55.2 km | 0% | 0 m | 0 / — | 21 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `musq-sherbrooke/clean/unknown-off/fuel-off` | 56.9 | 0% | 100% | 0% | 0 | 56.9 km | 0% | 0 m | 0 / — | 3 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `musq-sherbrooke/clean/unknown-off/fuel-on` | 56.9 | 0% | 100% | 0% | 0 | 56.9 km | 0% | 0 m | 0 / — | 2 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/dirt/unknown-off/fuel-off` | 332.8 | 82% | 18% | 6% | 0 | 332.8 km | 0% | 0 m | 0 / — | 358 | ✓ dirt ≥70<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `antigonish-sydney/dirt/unknown-off/fuel-on` | 472.9 | 84.5% | 15.5% | 4.5% | 1 | 237.1 km | 0% | 0 m | 6 / 81% | 4472 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/dirt/unknown-on/fuel-off` | 348.0 | 85% | 15% | 7% | 0 | 348.0 km | 0% | 0 m | 0 / — | 584 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `antigonish-sydney/dirt/unknown-on/fuel-on` | 448.8 | 86.6% | 13.4% | 4.9% | 1 | 227.8 km | 0% | 0 m | 6 / 83% | 4713 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/balanced/unknown-off/fuel-off` | 243.3 | 47% | 53% | 0% | 0 | 243.3 km | 0% | 0 m | 0 / — | 637 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `antigonish-sydney/balanced/unknown-off/fuel-on` | 296.9 | 49.1% | 50.9% | 3.1% | 1 | 154.7 km | 0.1% | 0 m | 6 / 51% | 3464 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/direct/unknown-off/fuel-off` | 234.9 | 11% | 89% | 3% | 0 | 234.9 km | 0% | 0 m | 0 / — | 272 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `antigonish-sydney/direct/unknown-off/fuel-on` | 234.9 | 11% | 89% | 3% | 0 | 234.9 km | 0% | 0 m | 0 / — | 279 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/clean/unknown-off/fuel-off` | 338.6 | 0% | 100% | 0% | 0 | 338.6 km | 0% | 0 m | 0 / — | 113 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `antigonish-sydney/clean/unknown-off/fuel-on` | 338.7 | 0% | 100% | 0% | 1 | 235.9 km | 0% | 0 m | 6 / 0% | 1162 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `through-halifax/dirt/unknown-off/fuel-off` | — | — | — | — | — | — km | — | — | 0 / — | 2425 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤4000ms per hop |
| 🔴 | `through-halifax/dirt/unknown-off/fuel-on` | — | — | — | — | — | — km | — | — | 0 / — | 2392 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤6000ms per hop |
| 🟢 | `through-halifax/dirt/unknown-on/fuel-off` | 198.7 | 87% | 13% | 27% | 0 | 198.7 km | 0% | 0 m | 0 / — | 179 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `through-halifax/dirt/unknown-on/fuel-on` | 198.7 | 87% | 13% | 27% | 0 | 198.7 km | 0% | 0 m | 0 / — | 172 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `through-halifax/balanced/unknown-off/fuel-off` | — | — | — | — | — | — km | — | — | 0 / — | 2361 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤4000ms per hop |
| 🔴 | `through-halifax/balanced/unknown-off/fuel-on` | — | — | — | — | — | — km | — | — | 0 / — | 4554 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤6000ms per hop |
| 🔴 | `through-halifax/direct/unknown-off/fuel-off` | — | — | — | — | — | — km | — | — | 0 / — | 1219 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤4000ms per hop |
| 🔴 | `through-halifax/direct/unknown-off/fuel-on` | — | — | — | — | — | — km | — | — | 0 / — | 1157 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤6000ms per hop |
| 🟢 | `through-halifax/clean/unknown-off/fuel-off` | 309.8 | 0% | 100% | 0% | 0 | 309.8 km | 0% | 0 m | 0 / — | 250 | ✓ clean ≤15<br>✓ urban wall<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `through-halifax/clean/unknown-off/fuel-on` | 240.7 | 13.5% | 86.5% | 2.5% | 1 | 201.2 km | 9.3% | 0 m | 6 / 16% | 1806 | ✓ clean ≤15<br>✓ urban wall<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/dirt/unknown-off/fuel-off` | 576.9 | 82% | 18% | 7.1% | 0 | 283.2 km | 1.8% | 0 m | 0 / — | 552 | ✓ dirt ≥70<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `three-waypoint/dirt/unknown-off/fuel-on` | 779.9 | 82.9% | 17.1% | 4.8% | 3 | 236.3 km | 6.5% | 0 m | 18 / 86%,91%,66% | 10390 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/dirt/unknown-on/fuel-off` | 506.9 | 83.1% | 16.9% | 5.6% | 0 | 254.9 km | 0.8% | 0 m | 0 / — | 663 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `three-waypoint/dirt/unknown-on/fuel-on` | 520.3 | 80.3% | 19.7% | 5.2% | 2 | 174.6 km | 1.5% | 0 m | 8 / 86%,68% | 4295 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/balanced/unknown-off/fuel-off` | 415.3 | 49.3% | 50.7% | 1.5% | 0 | 182.5 km | 0.2% | 0 m | 0 / — | 832 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `three-waypoint/balanced/unknown-off/fuel-on` | 552.8 | 50.5% | 49.5% | 5.1% | 2 | 164.2 km | 0.2% | 0 m | 12 / 51%,50% | 12948 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/direct/unknown-off/fuel-off` | 388.8 | 45.6% | 54.4% | 1.9% | 0 | 181.4 km | 0.6% | 0 m | 0 / — | 273 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `three-waypoint/direct/unknown-off/fuel-on` | 384.5 | 38.3% | 61.7% | 1.4% | 1 | 136.6 km | 0.7% | 0 m | 6 / 31% | 3547 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/clean/unknown-off/fuel-off` | 597.1 | 0% | 100% | 0% | 0 | 351.1 km | 8.2% | 0 m | 0 / — | 125 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `three-waypoint/clean/unknown-off/fuel-on` | 455.7 | 4.8% | 95.2% | 0% | 2 | 113.9 km | 0.5% | 0 m | 12 / 0%,20% | 5722 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/dirt/unknown-off/fuel-off` | 576.9 | 82% | 18% | 7.1% | 0 | 283.2 km | 1.8% | 0 m | 0 / — | 553 | ✓ dirt ≥70<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `phase10-104745/dirt/unknown-off/fuel-on` | 779.9 | 82.9% | 17.1% | 4.8% | 3 | 236.3 km | 6.5% | 0 m | 18 / 86%,91%,66% | 10353 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/dirt/unknown-on/fuel-off` | 506.9 | 83.1% | 16.9% | 5.6% | 0 | 254.9 km | 0.8% | 0 m | 0 / — | 658 | ✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `phase10-104745/dirt/unknown-on/fuel-on` | 520.3 | 80.3% | 19.7% | 5.2% | 2 | 174.6 km | 1.5% | 0 m | 8 / 86%,68% | 4326 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/balanced/unknown-off/fuel-off` | 415.3 | 49.3% | 50.7% | 1.5% | 0 | 182.5 km | 0.2% | 0 m | 0 / — | 851 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `phase10-104745/balanced/unknown-off/fuel-on` | 552.8 | 50.5% | 49.5% | 5.1% | 2 | 164.2 km | 0.2% | 0 m | 12 / 51%,50% | 12861 | ✓ balanced 45–55<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/direct/unknown-off/fuel-off` | 388.8 | 45.6% | 54.4% | 1.9% | 0 | 181.4 km | 0.6% | 0 m | 0 / — | 275 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `phase10-104745/direct/unknown-off/fuel-on` | 384.5 | 38.3% | 61.7% | 1.4% | 1 | 136.6 km | 0.7% | 0 m | 6 / 31% | 3549 | ✓ direct ≤shortest+15km<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/clean/unknown-off/fuel-off` | 597.1 | 0% | 100% | 0% | 0 | 351.1 km | 8.2% | 0 m | 0 / — | 124 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤4000ms per hop |
| 🟢 | `phase10-104745/clean/unknown-off/fuel-on` | 455.7 | 4.8% | 95.2% | 0% | 2 | 113.9 km | 0.5% | 0 m | 12 / 0%,20% | 5781 | ✓ clean ≤15<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |

Red rows: `short-no-fuel/balanced/unknown-off/fuel-off`, `musq-sherbrooke/balanced/unknown-off/fuel-off`, `musq-sherbrooke/balanced/unknown-off/fuel-on`, `through-halifax/dirt/unknown-off/fuel-off`, `through-halifax/dirt/unknown-off/fuel-on`, `through-halifax/balanced/unknown-off/fuel-off`, `through-halifax/balanced/unknown-off/fuel-on`, `through-halifax/direct/unknown-off/fuel-off`, `through-halifax/direct/unknown-off/fuel-on`. These are measurements, not blocked tests.
