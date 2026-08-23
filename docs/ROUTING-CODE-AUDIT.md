# DIRT Routing — Code Audit & Path to Finish

Reviewer: Claude (planning only, no code changes)
Scope: `00-PRODUCT-AND-ROUTING-SOURCE-OF-TRUTH.md` + the routing/fuel engines
(`OnDeviceRouter.swift`, `router.js`, `find-path-v2.js`, `fuel-chain.js`,
`ItineraryBuilder.swift`, `RoutingSource.swift`, supporting files).
Branch audited: `feature/routing-itinerary-rebuild`.

---

## A. Verdict (read this first)

The product is **not a rewrite away from working.** The design is sound and the
Source-of-Truth doc is genuinely good. But three specific things explain the
"fix-one-break-another, always slow" experience:

1. **There are TWO routing engines** (JavaScript on the server, Swift on the
   device) that must produce identical results and are kept in sync **by hand.**
   This is the structural cause of the churn.
2. **Neither engine uses a goal-directed search (A\*).** Both are plain Dijkstra,
   which is why routes are slow.
3. **The on-device engine is a slower, drifted copy of the server engine** — it
   re-does work the server engine already optimized away.

Everything below is targeted and fixable in dependency order. None of it requires
throwing anything out.

---

## B. Source-of-Truth doc — assessment

**Good, and worth keeping as the authority.** It states product law clearly
(the four modes, fuel-is-always-on, forward fuel chains, the itinerary/leg model,
the fuel-gap safety contract). A new agent can orient from it. Keep it.

Three tensions in it that the code is currently caught on:

1. **"Online → always use the live service" (doc §4).** This was written before you
   knew the live server lags. It directly forces the slow path and ignores an
   installed pack. This rule should change to *"prefer the installed pack when it
   covers the route; live is the fallback."*
2. **The Clean-for-fuel rule is ambiguous** about *when* it applies. Today the code
   reads it as ">1000 km / >3 pumps / cross-region only," which leaves a normal
   single-region Dirt route with no fuel skeleton — so it gaps. The doc should say
   plainly: *fuel stops are placed in the rider's profile; Clean is a targeted
   fallback only when a segment can't fit a station in range.*
3. **The Direct assertion** (shortest-distance) contradicts the mode definition
   (crow-flies + dirt-biased). Already flagged; fix the test, not the router.

These are doc edits, not code — but they're why the code behaves the way it does.

---

## C. The #1 structural problem — two hand-synced engines

- **Server engine (JS):** `router.js` (3,212 lines), `find-path-v2.js` (1,563),
  `fuel-chain.js` (1,615). Runs on Vercel.
- **Device engine (Swift):** `OnDeviceRouter.swift` (3,329 lines) + support. Runs
  on the phone.

They implement the *same* routing and fuel algorithms and are required to match
("lockstep"). **This is the root of the instability:**
- Every routing change must be written twice and kept byte-identical.
- They have **already diverged** (see §F: the JS fuel planner is optimized; the
  Swift one isn't). Divergence = "works online, fails on device" and vice-versa.
- A fix in one engine silently leaves the other wrong — exactly the whack-a-mole.

**Recommendation (not now, but name it):** move toward **one engine of record.**
Either (a) compile the JS engine to run on-device (WASM) so there's a single
source of truth, or (b) generate the Swift from the JS, or (c) if two engines must
stay, add **cross-engine parity tests** that run the same fixtures through both and
fail when they disagree. Option (c) is cheap and would have caught every drift.

---

## D. Code quality

- **Two 3,000+ line files** (`OnDeviceRouter.swift`, `router.js`). Too large to
  change safely; a person can't hold them in their head, so edits break neighbors.
- **Duplicated search loops:** `OnDeviceRouter.swift` has **5+ separate `MinHeap`
  Dijkstra implementations** (route, shortestGraphMeters, balanced, etc.). One
  shared, well-tested traversal would remove a class of divergence bugs.
- **Heavy special-casing** (city walls, settlement walls, snap diversification,
  bridge fallbacks, 7 corridor widths). Reasonable for real-world OSM messiness,
  but under-modularized — each special case is a place a change breaks another.

None of this is "bad code" — it's *unconsolidated* code that grew under pressure.
That's fixable with extraction, not rewrite.

---

## E. Correctness / breakage risks (ranked)

| # | Risk | Where | Effect |
| --- | --- | --- | --- |
| 1 | Source selection forces live when online | `RoutingSource.swift:463` | Installed pack ignored → server timeout → no route/fuel |
| 2 | Fuel chain is all-or-nothing | `RoutingSource.swift:~319` | Any partial failure → **empty gap, 0 stops placed** |
| 3 | Engine divergence (JS optimized, Swift not) | §F | Different results online vs offline; on-device slow |
| 4 | Clean-foundation scoped too narrowly | `ItineraryBuilder.swift:86–133` | Single-region Dirt route gaps instead of placing a stop |
| 5 | Many snap fallback paths | `OnDeviceRouter.swift:498–571` | Can silently pick a poor start/end edge; hard to diagnose |
| 6 | No diagnostics on fuel-gap decisions | on-device `fuelChain` | Failures are invisible → guesswork |

Items 1, 2, 4 together fully explain "274 km route, 190 km range, no fuel stop."

---

## F. Performance — why it's slow (the big section)

**1. No A\* / goal-directed search — the dominant cost.**
Both engines use plain bounded Dijkstra (`MinHeap`, no heuristic — confirmed in
`OnDeviceRouter.swift` and `find-path-v2.js`). A point-to-point search therefore
expands nodes in **every direction** out to `maxMeters`, instead of aiming at the
destination. On a ~200k-node / ~217k-edge NS graph that is the biggest single
waste. Adding an admissible heuristic (straight-line distance to goal) typically
cuts node expansions **3–10×** with identical results.

**2. On-device fuel chain does O(candidates) separate searches.**
`RoutingSource.swift:272–302` runs a **fresh `shortestGraphMeters` per candidate
station** (up to 16) just to test "does this pump still reach the destination."
The **server engine already solved this**: `fuel-chain.js:564` computes a single
reverse reachability graph from the destination and reuses it for every candidate.
The device engine should do the same — **one reverse search replaces ~16.** This
is pure drift: the optimization exists, it just wasn't ported to Swift.

**3. Dirt route search runs up to 7 width-variant searches.**
`OnDeviceRouter.swift:584–610` searches at corridor widths `[4×,3×,2×,1×]` then
`[6×,8×,∞]` to pick the best dirt candidate — up to 7 Dijkstras per leg. Good for
quality, expensive for speed. Start narrow and widen only on failure, and stop at
the first acceptable candidate, rather than always running the full ladder.

**4. Online adds network latency + a lagging server** on top of all of the above.
On-device removes that entirely — which is why #E-1 (prefer the pack) is the
cheapest big win.

**Net:** a long fuel route today = (7-width dirt search) + (≈16–33 per-candidate
Dijkstras per stop) + (network round-trips to a lagging server). Any one of these
is survivable; stacked, they produce the ~1-minute build.

---

## G. Speed plan (prioritized, each independently testable)

1. **Prefer the installed pack when it covers the route** (`RoutingSource.swift:463`).
   Removes network + timeout. *Small change, immediate.*
2. **Port the destination-graph reuse to the Swift fuel chain** — one reverse
   search from the destination, reuse for all candidates (match `fuel-chain.js`).
   *Medium change, large win, and it re-converges the two engines.*
3. **Add an A\* heuristic to the core search** (straight-line-to-goal), on-device
   first. *Larger change, biggest algorithmic win; results unchanged.*
4. **Short-circuit the 7-width Dirt ladder** — widen only on failure, accept the
   first good candidate. *Medium.*
5. **Progressive placement** — commit and show each proven fuel stop as it's found
   instead of computing the whole chain first. *UX speed + resilience.*
6. **Auto-download the area pack on drop-pin**, and later a **hardened Clean spine**
   (pre-computed connectivity + fuel skeleton) so the canvas blocks in instantly.
   *Product flow + future.*

---

## H. How to actually finish this (stop the churn)

1. **One change → your physical test → keep or drop.** No stacking. (We started this.)
2. **Fix in dependency order**, each verified before the next:
   `source-selection` → `on-device fuel placement (no empty gap + reverse-graph)` →
   `A*` → `auto-download`. Every step is independently testable on-device.
3. **Add cross-engine parity tests** (§C option c) so the two engines can't drift
   again silently. This is the single highest-leverage anti-churn move.
4. **The floor is committed** (restore point `7cd5a40`, the 85–90% baseline). We
   never drop below it.
5. **One agent owns the code changes** end-to-end from a plan you approve; the
   others don't touch the same files. The instability has come as much from three
   agents editing the same routing files as from the code itself.

---

## I. One-line answer to "what will make this work"

Prefer the on-device pack, place fuel stops progressively in the rider's profile
(never an empty gap), give the search a goal (A\*), and stop maintaining two
engines by hand. In that order — and each one is a change you can feel on the
device before we move to the next.
