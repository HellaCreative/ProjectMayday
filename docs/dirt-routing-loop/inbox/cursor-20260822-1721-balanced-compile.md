# Cursor execute — 2026-08-22 17:21 ADT — Swift compile fix (keep surface-live)

**Plan:** Claude hub: last turn failed only on Swift compile. KEEP Balanced
surface-live. Fix `let surfMult` reassignment. Do not chase greens.
**Did not** `git stash pop` fuel-chain WIP. No Vercel. No pack / manifest edits.

## Fix

In `searchVirtualBalanced` ordinary-edge hop, `surfMult` is now assigned once:

```
let surfMult = profile == .balanced
    ? OnDeviceProfileCosts.surfaceWeight(profile: .balanced, ...)
    : 1.0
```

Surface multiplication itself unchanged. Virtual-edge hop already used `var`.
`hopCostStep` `.balancedResource` still gates to `profile == .balanced`.

## Files

- `Dirt/Routing/OnDevice/OnDeviceRouter.swift` only (this turn)

JS `find-path-v2.js` surface-live from 17:01 **kept**.

## Verify

- iOS `xcodebuild build-for-testing` (Dirt, iPhone 17 / iOS 26.5, `CODE_SIGNING_ALLOWED=NO`): **TEST BUILD SUCCEEDED**
- `npm test`: **59 pass, 1 skip, 0 fail**
- `npm run bench:ns` local, promoted NS `ns-osm-20260821-02`
- **38 / 65** — identical statuses and dirt% to 17:01 (`a965d91-20260822T200145Z`)

## Guards

| Case | Dirt% | Limit |
| --- | ---: | --- |
| `dartmouth-capebreton/balanced/fuel-off` | **49** | must not >55 — held |
| `antigonish-sydney/balanced/fuel-off` | **52** | must not >55 — held |

No green flips. Foundation only; 45–55% tuning is the next turn.

## Codex

Independent `npm test` + `npm run bench:ns`. Confirm Swift compiles (no `let`
then reassign). Confirm JS↔Swift Balanced hop still multiplies by the existing
surface table. Confirm 38/65 and guards. No Vercel. No stash pop. Do **not**
ask to revert the surface-live change.
