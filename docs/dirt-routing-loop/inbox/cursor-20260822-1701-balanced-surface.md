# Cursor execute — 2026-08-22 17:01 ADT — Balanced surface table live

**Plan:** Codex diagnostic `inbox/codex-20260822-1625-balanced-band.md`. One knob.
**Did not** `git stash pop` fuel-chain WIP. No Vercel. No pack / manifest edits.
Did not change table numbers or corridor widths. Dirt/Direct/Clean search untouched.

## Knob

`searchBalancedResource` was length-only (`edgeM * settlementMult`). It now
multiplies the length step by `surfaceMultiplier(surface, "balanced")`.

Swift lockstep: `searchVirtualBalanced` (the live Balanced hop — not the dead
`hopCostStep` `.balancedResource` branch) does the same via
`OnDeviceProfileCosts.surfaceWeight(profile: .balanced, ...)`. `hopCostStep`
`.balancedResource` also applies the Balanced surface table **only when
`profile == .balanced`**, so Direct/Dirt extraBudget stays length-only.

Tables unchanged: Balanced paved 1.42 / gravel 0.98 / access 0.92 / track 0.88 /
unknown 0.96.

## Files

- `scripts/pack-fabric/routing/lib/find-path-v2.js`
- `Dirt/Routing/OnDevice/OnDeviceRouter.swift`

## Verify

- `npm test`: **59 pass, 1 skip, 0 fail**
- `npm run bench:ns` local, promoted NS `ns-osm-20260821-02`
- **38 / 65** (same as spec-alignment baseline). No green→red. No red→green.
- Dirt/Direct/Clean case metrics **byte-identical** to `a965d91-20260822T194315Z`.

## Regression guards

| Case | Before | After | Limit |
| --- | ---: | ---: | --- |
| `dartmouth-capebreton/balanced/fuel-off` | 50% | **49%** | must not >55 — held |
| `antigonish-sydney/balanced/fuel-off` | 51% | **52%** | must not >55 — held |

Did not revert.

## Goal cases

| Case | Before | After | Result |
| --- | ---: | ---: | --- |
| `short-no-fuel/balanced` | 38% | **44%** | closer, still under 45 |
| `musq-sherbrooke/balanced` | 40% | **40%** | no move |
| `antigonish-sydney/balanced/fuel-on` | no_route | no_route | 25 km cap, not this knob |

In-band Balanced that moved but stayed in 45–55: Dartmouth–Antigonish 50→54,
three-waypoint fuel-off 48.2→51.2, Antigonish–Sydney fuel-off 51→52.

## Why musq stayed 40%

The surface table is now consulted, but `pickResourceEnd` still prefers closest
to 50% when no 45–55% destination label exists. 40% (`|40-50|=10`) still beats
92% (`|92-50|=42`). Paved 1.42 vs access 0.92 was not enough for search to
*arrive* with an in-band label. Next one-knob is Claude’s: do not flatten the
table (that would be inert-adjacent); consider whether an in-band label can be
forced without breaking Cape Breton.

## Codex

Independent `npm test` + `npm run bench:ns`. Confirm JS↔Swift Balanced hop
multiplies by the existing surface table and no table numbers drifted. Confirm
38/65 and no former green flipped. No Vercel. No stash pop.
