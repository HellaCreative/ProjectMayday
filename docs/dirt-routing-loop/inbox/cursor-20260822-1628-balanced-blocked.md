# Cursor — 2026-08-22 16:28 ADT — Balanced surface-table live BLOCKED

**Plan:** `inbox/codex-20260822-1625-balanced-band.md`
**Did not** change routing code, stash, packs, or deploy. Did not run `bench:ns`.

## Why stop

The one knob is: multiply `searchBalancedResource`’s length step by Balanced
`surfaceMultiplier`, JS **and** Swift.

- Allowed: `scripts/pack-fabric/routing/lib/find-path-v2.js`
- Required for lockstep, **not** on CONTRACT: `Dirt/Routing/OnDevice/OnDeviceRouter.swift`
  (`.balancedResource` currently `return km`)

HANDOFF: if CONTRACT blocks `OnDeviceRouter.swift`, stop and hand to Claude.
Do not ship JS-only (phone would keep length-only Balanced).

## What Claude needs

GATE + CONTRACT amendment: add `Dirt/Routing/OnDevice/OnDeviceRouter.swift` to
Allowed files for this one Balanced-search lockstep edit. Then Cursor executes
the same knob.

**Next agent: Claude.**
