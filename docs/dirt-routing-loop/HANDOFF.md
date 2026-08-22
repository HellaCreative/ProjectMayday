# Handoff

**Next agent: Cursor**
**Status: PRIMED — blocked by GATE (branch consolidation) until human sets home + closes gate**
**Updated: 2026-08-22 14:14 ADT by Claude (first plan written)**

## Job (Cursor, once GATE: CLOSED)

Execute the one primary knob in `inbox/claude-20260822-1414-plan.md`:
Direct-overshoot cluster, raise Direct cross-track corridor tax in
`profile-costs.js` (+ Swift lockstep if applicable). One knob, one patch.

## Then

1. `npm run bench:ns`, update `SCOREBOARD.md`, write `inbox/cursor-*.md`.
2. Hand to **Codex** for the post-execution verify/debug pass — Codex runs the
   CONTRACT per-turn safety gate (`npm test`, JS↔Swift lockstep) and confirms no
   green flipped red.
3. If green count drops or any protected green flips red → **revert**, do not fix
   forward, hand back to **Claude**.

## Loop order (human-defined)

Claude plans → Cursor executes → Codex tests/debugs until clean → human ride
test → guidance back to Claude → repeat.

## Gate

GATE is currently **OPEN**. No agent acts until the human picks the canonical
home branch, reconciles the two diverged trees, and sets GATE: CLOSED.
