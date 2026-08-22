# Handoff

**Next agent: Cursor**
**Status: ACTIVE — GATE CLOSED, cleared to execute**
**Updated: 2026-08-22 by Claude (GATE closed on Richard's GO)**

## Job (Cursor — go now)

Execute the one primary knob in `inbox/claude-20260822-1414-plan.md`:
Direct-overshoot cluster. Raise Direct's cross-track corridor tax in
`scripts/pack-fabric/routing/lib/profile-costs.js` (`directCrossTrackExtra`, the
`direct` branch `k`), plus `Dirt/Routing/OnDevice/OnDeviceProfileCosts.swift` in
lockstep if the knob exists there. ONE knob, ONE patch.

## Then

1. `npm run bench:ns` (LOCAL — do NOT deploy to Vercel; CONTRACT forbids prod deploy).
2. Update `SCOREBOARD.md`, write `inbox/cursor-*.md`.
3. Hand to **Codex** for the post-execution verify/debug pass — Codex runs the
   CONTRACT per-turn safety gate (`npm test`, JS↔Swift lockstep) and confirms no
   protected green flipped red.
4. If green count drops or any protected green flips red → **revert**, do not fix
   forward, hand back to **Claude**.

## Protected greens (must not flip)

`short-no-fuel/direct/unknown-off/fuel-off`,
`dartmouth-antigonish/direct/unknown-off/fuel-on`,
`musq-sherbrooke/direct/unknown-off/fuel-off`,
`musq-sherbrooke/direct/unknown-off/fuel-on`, and every non-Direct green.

## Loop order

Claude plans → Cursor executes → Codex tests/debugs until clean → human ride
test → guidance back to Claude → repeat.
