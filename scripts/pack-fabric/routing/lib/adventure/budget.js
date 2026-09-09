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
// Optional quality work may stop before the request limit. Its expansions
// still belong to the parent; a local timeout must not erase a proved route.
function createRefinementBudget(parent,{maxMilliseconds=2000,now=Date.now}={}) {
 const deadline=Math.min(parent.snapshot().deadlineAtMs-250,now()+maxMilliseconds);
 let reason=null;
 function check(){if(reason)return false;if(!parent.check())reason=parent.snapshot().reason;else if(now()>=deadline)reason='refinement_deadline';return reason===null;}
 return {check,consume(){return check()&&parent.consume();},snapshot(){check();return {...parent.snapshot(),deadlineAtMs:deadline,reason};}};
}
module.exports = { createBudget, createRefinementBudget };
