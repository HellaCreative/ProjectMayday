"use strict";

// One owner creates this object. Every search/feasibility phase shares it;
// child work cannot restart the clock or manufacture a no-path proof.
function createBudget({ deadlineAtMs, maxExpansions, signal, now = Date.now }) {
  if (!Number.isFinite(deadlineAtMs)) throw new TypeError("A finite request deadline is required");
  if (!Number.isSafeInteger(maxExpansions) || maxExpansions < 1) throw new TypeError("A positive expansion budget is required");
  let expansions = 0;
  let reason = null;
  function check() {
    if (reason) return false;
    if (signal?.aborted) reason = "cancelled";
    else if (now() >= deadlineAtMs) reason = "deadline";
    return reason === null;
  }
  return Object.freeze({
    check,
    consume() {
      if (!check()) return false;
      if (expansions >= maxExpansions) { reason = "expansion_limit"; return false; }
      expansions++;
      return true;
    },
    snapshot() { check(); return { deadlineAtMs, expansions, maxExpansions, reason }; }
  });
}
module.exports = { createBudget };
