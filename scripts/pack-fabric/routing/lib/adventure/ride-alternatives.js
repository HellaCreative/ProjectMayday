"use strict";
const {buildFromHere}=require('./from-here');
const {createRefinementBudget}=require('./budget');
const {surfaceKind,compareSurface}=require('./surface');
const {pavedBackroadCost}=require('./paved-backroad-cost');
const {createPreparationCache}=require('./preparation-cache');
const {createReverseCostCache}=require('./reverse-cost-cache');
const {createStationMatchCache}=require('./station-match-cache');
// A small shared candidate pool, not three unrelated profile engines. Positive
// additive searches generate candidates; the requested surface objective selects
// from the same fuel-feasible pool. No global optimality is claimed.
const highwayFactor=a=>/^(motorway|motorway_link|freeway)$/.test(a.roadClassLeaf||"")?8:1;
const objectives=Object.freeze([
 {id:'paved',cost:pavedBackroadCost},
 {id:'dirt-10',cost:a=>a.distanceMeters*highwayFactor(a)*(surfaceKind(a.surfaceLeaf)==='dirt'?1:10)},
 {id:'dirt-30',cost:a=>a.distanceMeters*highwayFactor(a)*(surfaceKind(a.surfaceLeaf)==='dirt'?1:30)}
]);
const expandedObjectives=Object.freeze([...objectives,{id:'mixed-2',cost:a=>a.distanceMeters*highwayFactor(a)*(surfaceKind(a.surfaceLeaf)==='dirt'?1:2)},{id:'mixed-3',cost:a=>a.distanceMeters*highwayFactor(a)*(surfaceKind(a.surfaceLeaf)==='dirt'?1:3)},{id:'mixed-5',cost:a=>a.distanceMeters*highwayFactor(a)*(surfaceKind(a.surfaceLeaf)==='dirt'?1:5)}]);
function createRideAlternativeContext(){return {preparationCache:createPreparationCache(),reverseCostCache:createReverseCostCache(),stationMatchCache:createStationMatchCache()};}
function buildRideAlternatives(options) {
 const continuityMeters=options.dirtContinuityMeters??0;
 if(!Number.isFinite(continuityMeters)||continuityMeters<0)throw new TypeError("Continuity distance must be finite and nonnegative");
 const context=options.context||createRideAlternativeContext(),results=[];
 const continuation=!!options.arrivalHistory?.priorEdgeIds?.length;
 // Four distinct continuation objectives retain paved, moderate mixed, and
 // both dirt strengths. Fresh-route candidate coverage remains unchanged.
 const candidates=continuation?[...objectives,expandedObjectives[3]]:options.expandedCandidates?expandedObjectives:objectives;
 const profile=options.input.legs[0].profile;
 const rankFor=profile=>(a,b)=>(a.result.road.avoidanceMeters??a.result.road.urbanMeters??0)-(b.result.road.avoidanceMeters??b.result.road.urbanMeters??0)||compareSurface(profile,a.result.road.surface,b.result.road.surface)||a.id.localeCompare(b.id);
 const rank=rankFor(profile);
 const feasibleResult=r=>r.road.state==='complete'&&['provisional_station_access','verified','not_requested'].includes(r.fuel.state);
 const build=(objective,refine,budget=options.budget)=>buildFromHere({...options,...context,budget,fuelFirst:continuation,preparationBudget:budget===options.budget?options.preparationBudget:budget,objectiveId:objective.id,edgeCost:objective.cost,fuelHeuristicWeight:objective.id==='paved'?(options.pavedFuelHeuristicWeight??options.fuelHeuristicWeight):options.fuelHeuristicWeight,dirtEntryCost:objective.id==='paved'?0:continuityMeters*(Number(objective.id.split('-')[1])-1),preferOnwardFuel:options.preferOnwardFuel===true,retainFuelApproach:refine});
 for(const objective of candidates) {
  if(!options.budget.check())break;
  // Preserve the accepted fresh-route behavior. For continuations, finish
  // the shared comparison before spending work on approach refinements.
  const result=build(objective,!continuation&&objective.id==='paved');
  results.push({id:objective.id,result});
  if(options.budget.snapshot().reason)break;
 }
 // All profiles refine the same set of potential winners in the same order.
 // This preserves a shared candidate pool: Balanced cannot gain a candidate
 // that Dirt never had the opportunity to select. Optional refinement has its
 // own short limit, charged to the original request's work/clock budget.
 if(continuation&&results.length===candidates.length&&results.every(r=>feasibleResult(r.result))) {
  const attempted=new Set();
  while(options.budget.check()) {
   const feasible=results.filter(r=>feasibleResult(r.result));
   const winners=['clean','dirt','balanced'].map(p=>feasible.slice().sort(rankFor(p))[0]).sort((a,b)=>a.result.road.distanceMeters-b.result.road.distanceMeters||a.id.localeCompare(b.id));
   const best=winners.find(r=>r&&!attempted.has(r.id)&&r.result.qualityAudit?.repeatedRoadMeters>0);
   if(!best)break;
   attempted.add(best.id);
   const budget=createRefinementBudget(options.budget,{maxMilliseconds:4000});
   if(!budget.check())break;
   const refined=build(candidates.find(c=>c.id===best.id),true,budget);
   if(feasibleResult(refined))best.result=refined;
   else best.refinement={state:'incomplete',reason:budget.snapshot().reason||refined.fuel.reason};
  }
 }
 const poolComplete=results.length===candidates.length&&!options.budget.snapshot().reason&&results.every(r=>['provisional_station_access','verified','not_requested'].includes(r.result.fuel.state));
 const roads=results.filter(r=>r.result.road.state==='complete');
 const feasible=roads.filter(r=>['provisional_station_access','verified','not_requested'].includes(r.result.fuel.state));
 const pool=feasible.length?feasible:roads;
 pool.sort(rank);
 const selected=pool[0];
 return {state:selected?'complete':'incomplete',selected:selected?.result||null,selectedObjective:selected?.id||null,
  candidates:results.map(r=>({id:r.id,road:r.result.road.state,fuel:r.result.fuel.state,reason:r.result.fuel.reason,surface:r.result.road.surface,urbanMeters:r.result.road.urbanMeters,timing:r.result.timing,repeatedRoadMeters:r.result.qualityAudit?.repeatedRoadMeters,approachRefinement:r.refinement||r.result.search?.fuelSearch?.approachRefinement})),
  search:{...options.budget.snapshot(),poolComplete},
  limitations:['bounded shared candidate pool; not global best ride proof','station access may remain provisional']};
}
module.exports={buildRideAlternatives,createRideAlternativeContext};
