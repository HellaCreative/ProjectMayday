"use strict";

const { summarizeSurface, compareSurface } = require("./surface");
const { proveFuel } = require("./fuel-proof");

// Shared pool prevents the selector itself from hiding a Balanced-discovered
// Dirt candidate. Candidate generation/urban necessity/coherence are separate
// obligations; only explicitly admissible, legally proved candidates enter.
function selectCandidate({profile,candidates,fuel,budget}) {
  if (!["dirt","balanced","clean"].includes(profile)) throw new TypeError("Unknown profile");
  const evaluated = [], rejected = [];
  for (const candidate of candidates) {
    if (!budget.consume()) break;
    if (candidate.legal !== true || candidate.admissible !== true) {
      rejected.push({id:candidate.id,reason:"candidate_unproved"}); continue;
    }
    const surface = summarizeSurface(candidate.segments, budget);
    if (!surface) break;
    const proof = fuel ? proveFuel({...fuel,segments:candidate.segments,visits:candidate.visits,
      destinationEscape:candidate.destinationEscape,budget}) : {state:"not_requested"};
    evaluated.push({candidate,surface,fuel:proof});
  }
  const rank = rows => rows.sort((a,b)=>compareSurface(profile,a.surface,b.surface) || String(a.candidate.id).localeCompare(String(b.candidate.id)));
  const verified=rank(evaluated.filter(row=>row.fuel.state==="verified" || row.fuel.state==="not_requested"));
  const selected=verified[0] || rank(evaluated)[0];
  return {
    road: selected ? {state:"complete",candidate:selected.candidate,surface:selected.surface} : {state:"unverified"},
    fuel: selected ? selected.fuel : {state:"unverified",reason:budget.snapshot().reason || "no_candidate"},
    search: {state:budget.snapshot().reason ? "incomplete" : "candidate_pool_evaluated",...budget.snapshot()},
    evaluated:evaluated.map(row=>({id:row.candidate.id,surface:row.surface,fuel:row.fuel})),rejected
  };
}
module.exports={selectCandidate};
