# GATE

**State: CLOSED**
(agents may run)

When **OPEN**, every agent must stop coding, planning, and reviewing until the
human writes a decision below and sets State back to CLOSED.

## Open a gate when

- Physical ride / phone test required before more cost changes
- Changing CONTRACT thresholds or Allowed files
- Promote / R2 / pack rebuild needed, or ANY Vercel production deploy
- Green count dropped and someone wants to override the auto-revert rule
- Disagreement between agents that needs a human call

## Human decision — 2026-08-22

```
State: CLOSED
Decision: Richard said GO. Branch reconciliation accepted (home =
  feature/pack-rebuild-2026-08; Codex code discarded, intent captured). Run the
  loop against the current pinned baseline (promoted NS R2 pack, 38/65). New 8GB
  rebuild stays unpromoted until code is stable (Gate 3).
Next agent: Cursor
Notes: Execute inbox/claude-20260822-1414-plan.md — Direct-overshoot cluster,
  ONE knob (raise Direct cross-track corridor tax in profile-costs.js + Swift
  lockstep). Bench LOCALLY (npm run bench:ns) — NO Vercel production deploy
  (CONTRACT forbids it). Then hand to Codex for the verify/debug pass. If green
  count drops or a protected green flips red → revert, hand back to Claude.
```
