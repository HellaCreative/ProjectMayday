# DIRT — Route Search + Fuel Build Plan (focused)

Derived from `ROUTING-CODE-AUDIT.md` + Rick's algorithm decisions.
**One agent owns these files end-to-end. One phase → Rick physically tests →
keep/drop → next phase. No stacking.** Floor = restore point `7cd5a40`.

## Scope

**IN scope now:** single-province route search + fuel — *speed, accuracy, quality,
efficiency, and building an interesting route.* Nothing else.

**OUT of scope this pass (must keep working — do NOT modify):**
- Interaction layer: `RoutePlannerModel.swift` (touch resolution, waypoint
  select/drag/insert/renumber, mode switch), `ItineraryReducer.swift`,
  `RiderItinerary.swift`, `ItineraryAction.swift`.
- Fuel-stop **replacement** UI + forward cascade (already built and verified).
- Cross-region **seam** stitching (`CrossPackSeam.swift`, `build-cross-pack-seams.js`)
  — keep functioning; cross-province hardening is a later phase.
- Pack build/promotion tooling (`scripts/pack-fabric` packs) — separate lane.

**Hard rule:** the new fuel algorithm must preserve the existing **fuel-stop
identity model** (stable IDs, own leg) so replacement + cascade keep working.

---

## Phase 1 — Prefer the installed pack (speed floor)

- `RoutingSource.swift:463`: when installed packs cover the route, use the pack
  even when online. Live becomes the fallback.
- **Why:** removes the network round-trip + server timeout that starves every
  search today.
- **Accept (device):** with NS installed, the route builds on-device, fast, no
  timeouts; debug log shows the on-device source, not `live`.

---

## Phase 2 — Fuel chain: greedy furthest-reachable with look-ahead

Replace the current all-or-nothing candidate-scoring + empty-gap logic
(`RoutingSource.swift` on-device `fuelChain`, and the equivalent path) with the
algorithm Rick specified:

For each hop, starting from the current anchor with a full tank:
1. **One forward reachability search** (rider's profile) → every station reachable
   within usable range (`tank − reserve`).
2. **Pick the furthest-forward reachable station** — work *back* from the range
   limit to the nearest station that still makes forward progress. (Never require a
   station at exactly max range.)
3. **One-step look-ahead:** confirm the *next* window has a reachable station OR the
   destination is reachable. If not, back off to an earlier station that keeps the
   chain alive.
4. **Commit** it as a fuel stop (own identity, own leg), refuel, repeat from there.
5. **Final hop:** destination reachable within range — computed from a **single
   reverse search from the destination, reused** for all checks (port the
   optimization the JS engine already has; do not run one search per candidate).

Rules:
- **Never return an empty gap when a station is reachable in a window.** Only a
  window with genuinely no reachable station becomes a gap — for *that segment only*
  — and Clean is the per-segment fallback there, not a whole-route default.
- Legs are built in the **rider's profile** (Dirt stays Dirt).
- Forward-only; a fuel stop is a through-point, never an out-and-back.

**Accept (device):**
- 274 km Dirt / 190 km range → **one** fuel stop, two Dirt legs each within range.
- ~300 km / 100 km range → a sensible multi-stop chain, no false gap.
- No case where stations exist in range but zero stops are placed.

---

## Phase 3 — A\* directional search (stop the 360° fan)

- Add an admissible **straight-line-to-goal heuristic** to the core bounded search
  (`exploreNodeMeters` / `routeWithSnaps` on-device first) so it expands toward the
  destination instead of evenly in all directions. Keep the existing corridor
  (25 km Direct/Balanced, 60 km Dirt) as the lateral limit; A\* adds the forward aim.
- **Route output must not change** — this is speed only.
- **Accept:** materially fewer node expansions / faster builds, and routes identical
  to pre-A\* on the test fixtures (parity check).

---

## Phase 4 — Efficiency polish (only after 1–3 hold on device)

- Short-circuit the 7-width Dirt ladder (`OnDeviceRouter.swift:584–610`): start
  narrow, widen only on failure, accept the first good candidate.
- Progressive placement: commit + show each fuel stop as it's proven, rather than
  computing the whole chain before drawing anything.

---

## Anti-churn (applies to every phase)

- **Cross-engine parity tests:** run the same fixtures through the JS engine and the
  Swift engine; fail the build when they disagree. This is what stops "works online,
  breaks on device" from recurring. Add it alongside Phase 2 (the first shared-logic
  change).
- Each phase is one focused commit with device acceptance before the next.

---

## Deferred until route + fuel is tested and hardened

- Cross-province seam hardening (single-province solid first).
- Interaction polish (drag / insert / renumber / fuel-stop replace) — already built;
  re-verify on top of the hardened engine, don't rebuild.
- Auto-download-the-area pack on drop-pin (the "download your area" flow).
- Hardened/baked Clean spine (pre-computed connectivity + fuel skeleton).
