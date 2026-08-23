# Codex diagnostic — 2026-08-22 16:25 ADT — Balanced dirt band

**Finding: corridor is NOT the cause. Balanced surface/road-class tables are unused. Length-only `balancedResource` search + pick-closest-to-50% prefers the 40% collector spine.**

Case: `musq-sherbrooke/balanced/unknown-off/fuel-off` (40% dirt, 55.1 km). Dirt on the same OD: 92% / 64.3 km.

Diagnostic only: no routing code change, stash, pack, or deploy.

## Trace

Dirt’s 92% ride is **inside** Balanced’s 40 km envelope:

| | Balanced | Dirt |
| --- | ---: | ---: |
| km | 55.1 | 64.3 |
| dirt% | 40 | 92 |
| search corridor | 40 km, not widened | 50 km, not widened |
| max cross-track | 3.9 km | 6.5 km |
| Dirt geom outside 40 km | — | **0 / 2488 points** |

Dirt candidates at 50/100/150/200 km envelopes are the **same** 64.3 km / 92% ride (981 pops). The extra dirt is not a far-lateral hunt.

Mix:

- Balanced ≈ Direct: collector 32.3 km + service 17.3 + track 4.6; **paved 33.3 / access 21.9**
- Dirt: service 40.2 + track 18.5 + collector 4.3; **access 53.2 / unknown 5.9 / paved 5.1**

So the corridor **has** the dirt. Balanced’s first-success 40 km search already contains it.

## Why Balanced still lands at 40%

`findPathV2` for Balanced uses `costMode: "balancedResource"` (`searchBalancedResource`). Edge score is **raw length** (`edgeM * settlementMult`). It does **not** read `PROFILE_SURFACE_WEIGHTS.balanced` or `BALANCED_ROAD_CLASS_WEIGHTS`. Swift matches (`OnDeviceRouter` `.balancedResource` → `return km`).

Destination labels are dirt-ratio buckets. `pickResourceEnd` prefers 45–55% if any exist, else **closest to 50%**. 40% beats 92% (`|40-50|=10` vs `|92-50|=42`). No 45–55% destination bucket was found (if one existed it would have won).

Same pattern: `short-no-fuel/balanced` 38% (max XT 2.2 km, corridor 40 km unused).

This is the Direct turn-2 class of bug: flattening a table that search does not consult.

## Which of the three named knobs?

| Knob | Verdict |
| --- | --- |
| Corridor width (`BALANCED_CORRIDOR_M` / widen loop) | **Wrong.** Dirt XT 6.5 km ≪ 40 km. Widening does not unlock musq dirt. |
| Road-class table | Inert in `balancedResource`. Not the split (collector vs service is a consequence of taking the paved spine). |
| Surface table | **The product knob** (paved 1.42 vs access 0.92 / track 0.88) — but **inert until search uses it**. |

## Single recommended execute (Cursor)

**Make the existing Balanced surface table live** in `searchBalancedResource` only: multiply the length step by `surfaceMultiplier(surface, "balanced")` (JS `find-path-v2.js` + Swift `OnDeviceRouter` hop, lockstep). Do **not** change table numbers this turn. Do **not** widen corridor. Do **not** touch Dirt/Direct.

CONTRACT today lists `find-path-v2.js` but **not** `OnDeviceRouter.swift`. If Cursor cannot edit the Swift search, **stop and hand to Claude** for a GATE/CONTRACT amendment — do not ship a JS-only Balanced scorer.

Do **not** flatten/nudge the Balanced surface table alone. That is a no-op.

## Regression risk (in-band cases)

Both already sit in a 40 km corridor with room:

| Case | dirt% | max XT | Risk if surface cost goes live |
| --- | ---: | ---: | --- |
| `dartmouth-capebreton/balanced` | **50** | 20 km | **High** — already 164.5 km paved / 163.5 km access. Cheaper dirt can push **>55%**. |
| `antigonish-sydney/balanced/fuel-off` | **47** | 35 km | Medium — room to 50–55, possible overshoot. |
| `short-no-fuel/balanced` | 38 | 2.2 km | Likely helpful (under-band). |

If either in-band case exceeds 55% → revert, do not fix forward.

**Next agent: Cursor.**
