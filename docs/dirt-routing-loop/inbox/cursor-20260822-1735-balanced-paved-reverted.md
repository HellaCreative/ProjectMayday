# Cursor execute — 2026-08-22 17:35 ADT — Balanced paved 1.70 REJECTED

**Plan:** one knob, Balanced `paved` 1.42 → 1.70. Swift lockstep.
**Did not** `git stash pop`. No Vercel. No pack / manifest edits.
**Did not** fix forward after the guard/green-drop.

## Knob (reverted)

| | Before | After (probe) | Now |
| --- | ---: | ---: | ---: |
| `PROFILE_SURFACE_WEIGHTS.balanced.paved` | 1.42 | 1.70 | **1.42** (HEAD) |

Other Balanced surfaces and Dirt/Direct/Clean untouched throughout.

## Probe bench (`a965d91-20260822T203335Z.json`)

**37 / 65.** Net green drop. One former green flipped red.

| Case | Before | Probe | Verdict |
| --- | ---: | ---: | --- |
| `dartmouth-antigonish/balanced/fuel-on` | **54% green** | **57% red** | **FLIP + overshoot** |
| `dartmouth-capebreton/balanced/fuel-off` | 49% | 51% | named guard held |
| `antigonish-sydney/balanced/fuel-off` | 52% | 47% | named guard held (moved down) |
| `musq-sherbrooke/balanced` | 40% | 40% | no lift |
| `short-no-fuel/balanced` | 44% | 44% | no lift |
| `antigonish-sydney/balanced/fuel-on` | no_route | no_route | 25 km cap |

A global paved hike taxes the long Dual-sport mix enough to push Dartmouth–Antigonish fuel-on over 55% without creating an in-band musq label.

## Revert

```
git checkout HEAD -- scripts/pack-fabric/routing/lib/profile-costs.js \
  Dirt/Routing/OnDevice/OnDeviceProfileCosts.swift
```

Post-revert bench `a965d91-20260822T203514Z.json`: **38 / 65**, zero status flips vs 17:21. Surface-live wiring in `find-path-v2.js` / `OnDeviceRouter.swift` **kept**.

## Claude

Do not retry a larger Balanced paved tax. musq 40% is still `pickResourceEnd` (40% closer to 50% than 92%) with no in-band destination label. Dartmouth–Antigonish fuel-on has ~1 point of headroom at 54%. Next knob must be local to under-band cases or to destination-label selection, not a global paved multiplier.

**Next agent: Claude.**
