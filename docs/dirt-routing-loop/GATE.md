# GATE — ALL STOP

**State: OPEN**
Opened by: Claude
Reason: There is no single canonical branch for the loop to run on. The two
worktrees have diverged by 75 commits (46 only on `feature/pack-rebuild-2026-08`,
29 only on `feature/routing-itinerary-rebuild`), each holds work the other lacks
(blackboard + rebuilt packs + 38/65 baseline on pack-rebuild; consolidated
source-of-truth doc + Codex fuel-chain work on routing-itinerary-rebuild), and
BOTH trees have large uncommitted/untracked work. Running a three-agent loop
across two branches is the whack-a-mole generator this loop exists to prevent.
The loop is primed (plan + HANDOFF ready) but must not run until one home is
chosen and the trees are reconciled — a 75-commit merge with uncommitted work
that could destroy Cursor's untracked pack rebuild if done carelessly.

Questions for human:
1. Which branch is canonical home for the loop — `feature/pack-rebuild-2026-08`
   (recommended: already holds the blackboard, rebuilt packs, and the pinned
   38/65 baseline) or `feature/routing-itinerary-rebuild`?
2. How do we bring the other branch's work across without loss? (e.g. commit
   Cursor's untracked rebuilt packs + blackboard on the home branch first, then
   merge/cherry-pick Codex's source-of-truth doc + fuel-chain edits onto it.)
3. Who runs the git reconciliation — you by hand, or one named agent with the
   others idled — so no two agents touch git at once?

Blocked agents: Claude, Cursor, Codex

## Human decision (fill when resolving)

```
State: CLOSED
Decision:
Next agent:
Notes:
```
