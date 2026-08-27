# Nova Scotia routing benchmark

Git `7a7b23e` · 2026-08-26T23:53:17.481Z · seed `3511091208` · 22/44 cases green
Live source: `https://pub-eb539dc7777942b889388ebb4b701697.r2.dev/candidates/ns-osm-20260821-02/ns`

| Result | Case | km | Dirt | Paved | Unknown | Stops | Max hop | Backtrack | Restricted | Candidates / chosen dirt | ms | Assertions |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: | --- |
| 🟢 | `short-no-fuel/dirt/unknown-off/fuel-planned` | 8.9 | 100% | 0% | 100% | 0 | 8.9 km | 0% | 0 m | 0 / — | 129 | ✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `short-no-fuel/dirt/unknown-on/fuel-planned` | 8.9 | 100% | 0% | 100% | 0 | 8.9 km | 0% | 0 m | 0 / — | 21 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `short-no-fuel/balanced/unknown-off/fuel-planned` | 9.9 | 100% | 0% | 100% | 0 | 9.9 km | 0% | 0 m | 0 / — | 70 | ✗ balanced 45–55 (100%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `short-no-fuel/clean/unknown-off/fuel-planned` | 7.5 | 100% | 0% | 100% | 0 | 7.5 km | 0% | 0 m | 0 / — | 412 | ✗ clean ≤15 (100%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/dirt/unknown-off/fuel-planned` | 371.0 | 100% | 0% | 100% | 1 | 237.3 km | 0% | 0 m | 8 / 100% | 7202 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-capebreton/dirt/unknown-on/fuel-planned` | 416.3 | 100% | 0% | 100% | 1 | 237.3 km | 0% | 0 m | 12 / 100% | 7469 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `dartmouth-capebreton/balanced/unknown-off/fuel-planned` | 339.0 | 100% | 0% | 100% | 1 | 235.3 km | 0% | 0 m | 6 / 100% | 8361 | ✗ balanced 45–55 (100%)<br>✓ no unexplained backtrack<br>✗ ≤6000ms per hop (6324ms) |
| 🔴 | `dartmouth-capebreton/clean/unknown-off/fuel-planned` | 323.6 | 100% | 0% | 100% | 1 | 237.0 km | 0.1% | 0 m | 13 / 100% | 7537 | ✗ clean ≤15 (100%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-antigonish/dirt/unknown-off/fuel-planned` | 325.6 | 100% | 0% | 100% | 1 | 191.6 km | 0.1% | 0 m | 8 / 100% | 7404 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `dartmouth-antigonish/dirt/unknown-on/fuel-planned` | 274.2 | 100% | 0% | 100% | 1 | 186.4 km | 0.1% | 0 m | 8 / 100% | 7886 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `dartmouth-antigonish/balanced/unknown-off/fuel-planned` | 229.1 | 100% | 0% | 100% | 0 | 229.1 km | 0% | 0 m | 0 / — | 462 | ✗ balanced 45–55 (100%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `dartmouth-antigonish/clean/unknown-off/fuel-planned` | 205.9 | 100% | 0% | 100% | 0 | 205.9 km | 0% | 0 m | 0 / — | 200 | ✗ clean ≤15 (100%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `musq-sherbrooke/dirt/unknown-off/fuel-planned` | 64.3 | 100% | 0% | 100% | 0 | 64.3 km | 0% | 0 m | 0 / — | 28 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `musq-sherbrooke/dirt/unknown-on/fuel-planned` | 64.3 | 100% | 0% | 100% | 0 | 64.3 km | 0% | 0 m | 0 / — | 25 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `musq-sherbrooke/balanced/unknown-off/fuel-planned` | 73.6 | 100% | 0% | 100% | 0 | 73.6 km | 0% | 0 m | 0 / — | 145 | ✗ balanced 45–55 (100%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `musq-sherbrooke/clean/unknown-off/fuel-planned` | 56.9 | 100% | 0% | 100% | 0 | 56.9 km | 0% | 0 m | 0 / — | 110 | ✗ clean ≤15 (100%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/dirt/unknown-off/fuel-planned` | 263.0 | 100% | 0% | 100% | 1 | 237.2 km | 0% | 0 m | 10 / 100% | 6156 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `antigonish-sydney/dirt/unknown-on/fuel-planned` | 271.5 | 100% | 0% | 100% | 1 | 237.2 km | 0% | 0 m | 10 / 100% | 6374 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `antigonish-sydney/balanced/unknown-off/fuel-planned` | 253.6 | 100% | 0% | 100% | 1 | 227.1 km | 0% | 0 m | 4 / 100% | 7868 | ✗ balanced 45–55 (100%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `antigonish-sydney/clean/unknown-off/fuel-planned` | 231.7 | 100% | 0% | 100% | 0 | 231.7 km | 0% | 0 m | 0 / — | 131 | ✗ clean ≤15 (100%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `through-halifax/dirt/unknown-off/fuel-planned` | 85.7 | 100% | 0% | 100% | 0 | 85.7 km | 0% | 0 m | 0 / — | 1223 | ✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `through-halifax/dirt/unknown-on/fuel-planned` | 183.0 | 100% | 0% | 100% | 0 | 183.0 km | 0% | 0 m | 0 / — | 108 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `through-halifax/balanced/unknown-off/fuel-planned` | — | — | — | — | — | — km | — | — | 0 / — | 2439 | ✗ route complete (baseline leg 1: no_route)<br>✓ ≤6000ms per hop |
| 🔴 | `through-halifax/clean/unknown-off/fuel-planned` | 43.5 | 100% | 0% | 100% | 0 | 43.5 km | 0% | 0 m | 0 / — | 170 | ✗ clean ≤15 (100%)<br>✓ urban wall<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `white-fuel-20260823/dirt/unknown-off/fuel-planned` | 269.1 | 100% | 0% | 100% | 1 | 236.6 km | 0.1% | 0 m | 8 / 100% | 7222 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `white-fuel-20260823/dirt/unknown-on/fuel-planned` | 284.2 | 100% | 0% | 100% | 1 | 236.8 km | 0.1% | 0 m | 12 / 100% | 7283 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `white-fuel-20260823/balanced/unknown-off/fuel-planned` | 258.3 | 100% | 0% | 100% | 1 | 226.1 km | 0.1% | 0 m | 8 / 100% | 8360 | ✗ balanced 45–55 (100%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `white-fuel-20260823/clean/unknown-off/fuel-planned` | 263.8 | 100% | 0% | 100% | 1 | 237.3 km | 0.1% | 0 m | 11 / 100% | 7047 | ✗ clean ≤15 (100%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `device-loop-20260823/dirt/unknown-off/fuel-planned` | 383.4 | 100% | 0% | 100% | 1 | 237.3 km | 0% | 0 m | 8 / 100% | 7325 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `device-loop-20260823/dirt/unknown-on/fuel-planned` | 326.2 | 100% | 0% | 100% | 1 | 237.5 km | 0% | 0 m | 10 / 100% | 7021 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `device-loop-20260823/balanced/unknown-off/fuel-planned` | 325.9 | 100% | 0% | 100% | 1 | 223.1 km | 0% | 0 m | 6 / 100% | 9372 | ✗ balanced 45–55 (100%)<br>✓ no unexplained backtrack<br>✗ ≤6000ms per hop (7225ms) |
| 🔴 | `device-loop-20260823/clean/unknown-off/fuel-planned` | 324.5 | 100% | 0% | 100% | 1 | 173.8 km | 0% | 0 m | 13 / 100% | 6831 | ✗ clean ≤15 (100%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `fuel-overshoot-20260826/dirt/unknown-off/fuel-planned` | 220.1 | 100% | 0% | 100% | 0 | 220.1 km | 0% | 0 m | 0 / — | 105 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `fuel-overshoot-20260826/dirt/unknown-on/fuel-planned` | 185.5 | 100% | 0% | 100% | 0 | 185.5 km | 0% | 0 m | 0 / — | 126 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `fuel-overshoot-20260826/balanced/unknown-off/fuel-planned` | 175.0 | 100% | 0% | 100% | 0 | 175.0 km | 0% | 0 m | 0 / — | 378 | ✗ balanced 45–55 (100%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `fuel-overshoot-20260826/clean/unknown-off/fuel-planned` | 171.1 | 100% | 0% | 100% | 0 | 171.1 km | 0% | 0 m | 0 / — | 196 | ✗ clean ≤15 (100%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/dirt/unknown-off/fuel-planned` | 476.3 | 100% | 0% | 100% | 2 | 146.4 km | 0.9% | 0 m | 25 / 100%,100% | 21287 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `three-waypoint/dirt/unknown-on/fuel-planned` | 443.9 | 100% | 0% | 100% | 2 | 119.8 km | 1% | 0 m | 19 / 100%,100% | 21325 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `three-waypoint/balanced/unknown-off/fuel-planned` | 435.5 | 100% | 0% | 100% | 2 | 167.1 km | 0.4% | 0 m | 18 / 100%,100% | 22421 | ✗ balanced 45–55 (100%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `three-waypoint/clean/unknown-off/fuel-planned` | 423.4 | 100% | 0% | 100% | 1 | 140.4 km | 1.5% | 0 m | 12 / 100% | 17499 | ✗ clean ≤15 (100%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/dirt/unknown-off/fuel-planned` | 476.3 | 100% | 0% | 100% | 2 | 146.4 km | 0.9% | 0 m | 25 / 100%,100% | 21700 | ✓ dirt ≥70<br>✓ fuel hops ≤237500<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🟢 | `phase10-104745/dirt/unknown-on/fuel-planned` | 443.9 | 100% | 0% | 100% | 2 | 119.8 km | 1% | 0 m | 19 / 100%,100% | 21207 | ✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `phase10-104745/balanced/unknown-off/fuel-planned` | 435.5 | 100% | 0% | 100% | 2 | 167.1 km | 0.4% | 0 m | 18 / 100%,100% | 22692 | ✗ balanced 45–55 (100%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |
| 🔴 | `phase10-104745/clean/unknown-off/fuel-planned` | 423.4 | 100% | 0% | 100% | 1 | 140.4 km | 1.5% | 0 m | 12 / 100% | 17551 | ✗ clean ≤15 (100%)<br>✓ no unexplained backtrack<br>✓ ≤6000ms per hop |

Red rows: `short-no-fuel/balanced/unknown-off/fuel-planned`, `short-no-fuel/clean/unknown-off/fuel-planned`, `dartmouth-capebreton/balanced/unknown-off/fuel-planned`, `dartmouth-capebreton/clean/unknown-off/fuel-planned`, `dartmouth-antigonish/balanced/unknown-off/fuel-planned`, `dartmouth-antigonish/clean/unknown-off/fuel-planned`, `musq-sherbrooke/balanced/unknown-off/fuel-planned`, `musq-sherbrooke/clean/unknown-off/fuel-planned`, `antigonish-sydney/balanced/unknown-off/fuel-planned`, `antigonish-sydney/clean/unknown-off/fuel-planned`, `through-halifax/balanced/unknown-off/fuel-planned`, `through-halifax/clean/unknown-off/fuel-planned`, `white-fuel-20260823/balanced/unknown-off/fuel-planned`, `white-fuel-20260823/clean/unknown-off/fuel-planned`, `device-loop-20260823/balanced/unknown-off/fuel-planned`, `device-loop-20260823/clean/unknown-off/fuel-planned`, `fuel-overshoot-20260826/balanced/unknown-off/fuel-planned`, `fuel-overshoot-20260826/clean/unknown-off/fuel-planned`, `three-waypoint/balanced/unknown-off/fuel-planned`, `three-waypoint/clean/unknown-off/fuel-planned`, `phase10-104745/balanced/unknown-off/fuel-planned`, `phase10-104745/clean/unknown-off/fuel-planned`. These are measurements, not blocked tests.
