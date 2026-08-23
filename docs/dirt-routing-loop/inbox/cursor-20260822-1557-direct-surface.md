# Cursor execute — 2026-08-22 15:57 ADT — Direct surface flatten

**Plan:** Claude hub turn 4. Turn 3 keep: avoidMult Direct=1, highway class 1.0, `k` 0.018.
**Did not** `git stash pop` fuel-chain WIP. No Vercel. No pack / manifest edits.

## Knob (one)

Direct surface table toward neutral (tie-break, paved wins ties):

| Surface | Before | After |
| --- | ---: | ---: |
| paved | 1.15 | **0.98** |
| gravel | 1.00 | **1.00** |
| access | 0.95 | **1.00** |
| track | 0.90 | **1.00** |
| unknown | 1.00 | **1.00** |

Balanced / Dirt / Clean untouched.

**Files:** `scripts/pack-fabric/routing/lib/profile-costs.js`, `Dirt/Routing/OnDevice/OnDeviceProfileCosts.swift`

## Bench

`npm run bench:ns` local, promoted NS `ns-osm-20260821-02`.

**41 / 65 measured · 39 durable.** Did not revert. No protected / durable green flipped.

Protected Direct greens held:

| Case | Turn 3 | This run |
| --- | ---: | ---: |
| `short-no-fuel/direct/unknown-off/fuel-off` | 7.4 green | **7.4 green** (dirt 11%→6%) |
| `dartmouth-antigonish/direct/unknown-off/fuel-on` | 233.0 green | **233.0 green** |
| `antigonish-sydney/direct/unknown-off/fuel-on` | 234.8 green | **228.9 green** |
| `musq-sherbrooke/direct/unknown-off/fuel-off` | 55.1 green | **55.1 green** |
| `musq-sherbrooke/direct/unknown-off/fuel-on` | 55.1 green | **55.1 green** |

## Remaining Direct-overshoot — 0 converted; two shortened

| Case | Turn 3 km | This run km | Line | Result |
| --- | ---: | ---: | ---: | --- |
| `antigonish-sydney/direct/.../fuel-off` | 253.7 | **247.9** | 234.9 | still red (−5.8 km) |
| `dartmouth-antigonish/direct/.../fuel-off` | 297.3 | **297.2** | 243.5 | still red (no move) |
| `dartmouth-capebreton/direct/.../fuel-off` | 374.0 | **353.4** | 335.7 | still red (−20.6 km) |
| `dartmouth-capebreton/direct/.../fuel-on` | 384.0 | **384.0** | 335.7 | still red |

Measured +1 is hop-time on `dartmouth-capebreton/balanced/fuel-on` (ignore).

## Next

**Codex** — `npm test` + JS↔Swift lockstep (Direct surface 0.98/1/1/1/1, avoidMult=1, class 1.0, `k` 0.018). Confirm protected greens including `antigonish-sydney/direct/fuel-on`. Do not implement the next knob.
