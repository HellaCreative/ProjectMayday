# Cursor diagnostic — 2026-08-22 17:47 ADT — Direct surface table already live

**STOP.** Direct does **not** ignore `PROFILE_SURFACE_WEIGHTS.direct`. This is not
the Balanced `searchBalancedResource` length-only bug. No product change.
**Did not** `git stash pop`. No Vercel. No pack / manifest edits. No bench
(nothing to re-measure).

## STEP 1 — what search actually costs

### JS `find-path-v2.js`

Corridor loop sets Direct to **`costMode: "profile"`**, not `balancedResource`:

```
costMode:
  profile === "balanced" ? "balancedResource" :
  profile === "dirt" ? "pavement" : "profile"   // Direct lands here
```

The profile hop is:

```
step = (edgeM / 1000) * costView[surface] * roadClassMultiplier(road, profile)
```

`costView = costPerKmView(profile, …)` which is `surfaceMultiplier(code, profile)`
for surface codes 0..4 — i.e. **`PROFILE_SURFACE_WEIGHTS.direct`**. Direct also
applies `roadClassMultiplier` and `majorHighwayAvoidMult` on the same hop.

### Swift `OnDeviceRouter.swift`

Direct corridor search sets **`envelope.costMode = .profile`** (Balanced is
`.balancedResource`). `hopCostStep` `.profile` is:

```
km * OnDeviceProfileCosts.edgeCostPerKm(profile: …)
```

and `edgeCostPerKm` starts with `surfaceWeight(profile:)` — Direct table
`[1.15, 1.00, 0.95, 0.90, 1.00]` — then road-class and quality multipliers.

## Contrast with Balanced (already fixed)

| | Balanced (before 17:01) | Direct (today) |
| --- | --- | --- |
| costMode | `balancedResource` | `profile` |
| hop | raw length (`edgeM`) | surface × road-class |
| table | inert | **live** |

Wiring `surfaceMultiplier(surface, "direct")` onto Direct’s profile hop would
**double-count** the table. Not this turn.

## Nuance for Claude (not a wiring job)

`costPerKmView` indexes by surface code only and does **not** pass road class, so
the unknown→paved paint remap (`paintsAsPavedRoadClass`) is not in the JS search
view. Swift `surfaceWeight` does take `roadClassCode`. That is a possible
lockstep gap on **untagged** highways, not “table ignored.” Direct’s current reds
(19% / 40% / 50% / 52% / 57.9%) already see paved 1.15 vs track 0.90.

## STEP 2

No knob. Next agent: **Claude** — pick a Direct hypothesis that is not “make the
surface table live.”

SCOREBOARD remains **41 / 65**.
