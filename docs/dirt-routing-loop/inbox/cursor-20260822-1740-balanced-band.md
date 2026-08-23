# Cursor execute — 2026-08-22 17:40 ADT — Balanced bench band 35–65

**Plan:** Rick-greenlit spec correction (CONTRACT already 35–65). Bench assert
only. Keep surface-live wiring. No table, corridor, or search changes.
**Did not** `git stash pop`. No Vercel. No pack / manifest edits.

## Change

`scripts/pack-fabric/bench/run-ns-bench.js`:

```
// was: dirtPct >= 45 && dirtPct <= 55  ("balanced 45–55")
dirtPct >= 35 && dirtPct <= 65  // "balanced 35–65"
```

`BALANCED_DIRT_LO/HI` in hop-search.js / HopSearchPolicy (destination pick)
**unchanged** — this turn is the scoreboard band, not the search objective.

## Verify

- `npm test`: **59 pass, 1 skip, 0 fail**
- `npm run bench:ns` local, promoted NS `ns-osm-20260821-02`
- **41 / 65** (was 38). No green→red. Dirt/Direct/Clean statuses unchanged.

## Conversions (same rides, new band)

| Case | Dirt% | Before | After |
| --- | ---: | --- | --- |
| `short-no-fuel/balanced` | 44 | red 45–55 | **green** |
| `musq-sherbrooke/balanced/fuel-off` | 40 | red 45–55 | **green** |
| `musq-sherbrooke/balanced/fuel-on` | 40 | red 45–55 | **green** |

`antigonish-sydney/balanced/fuel-on` remains **red `no_route`** (25 km cap),
not a 34% band miss. Left as-is.

## Codex

Independent `npm test` + `npm run bench:ns`. Confirm the assert is 35–65, no
cost/corridor/search drift, 41/65, those three conversions, no former green
flipped. If PASS: Next agent **Claude** (next one-knob against Direct dirt≥60
or fuel-on no_route). No Vercel. No stash pop.
