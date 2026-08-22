# Dirt routing loop (multi-agent)

Shared blackboard for **Claude** (plan/judge), **Cursor** (execute), **Codex** (debug/review).  
You do not chat with each other. You **read and write these files**.

## Files

| File | Owner writes | Everyone reads |
| --- | --- | --- |
| `VISION.md` | Human + Claude (rare) | Always |
| `CONTRACT.md` | Claude (with human approve) | Always — hard rules |
| `SCOREBOARD.md` | Cursor after every bench | Always |
| `HANDOFF.md` | Whoever finishes a turn | Next agent’s job ticket |
| `GATE.md` | Any agent or human | **ALL STOP** if open |
| `inbox/claude-*.md` | Claude | Cursor / Codex |
| `inbox/codex-*.md` | Codex | Cursor / Claude |
| `inbox/cursor-*.md` | Cursor | Claude / Codex |
| `SPOOL-UP-PROMPT.md` | Human pastes to all three | Bootstrap |

## Loop

1. Read `GATE.md` — if open, stop and wait for human.
2. Read `VISION.md` + `CONTRACT.md` + `SCOREBOARD.md` + `HANDOFF.md`.
3. Do only your role (see `SPOOL-UP-PROMPT.md`).
4. Write your `inbox/<agent>-YYYYMMDD-HHMM.md` note.
5. Update `HANDOFF.md` for the **next** agent.
6. Cursor updates `SCOREBOARD.md` after any code/bench change.

## Roles

- **Claude** — chief technologist: plan, prioritize red clusters, accept/reject approach. Rarely edits code.
- **Codex** — debug/review: read traces and SCOREBOARD, one hypothesis + proposed patch sketch. Prefer not to bulk-implement.
- **Cursor** — execute: apply allowed patches, run `npm run bench:ns`, fabric/live checks, update SCOREBOARD + HANDOFF.

## Human gates

Physical ride feel, promote to stable R2, changing CONTRACT targets, or opening `GATE.md`.
