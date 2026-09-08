"use strict";
const {buildFromHere}=require('./from-here');
const {surfaceKind,compareSurface}=require('./surface');
const {createPreparationCache}=require('./preparation-cache');
const {createReverseCostCache}=require('./reverse-cost-cache');
const {createStationMatchCache}=require('./station-match-cache');
// A small shared candidate pool, not three unrelated profile engines. Positive
// additive searches generate candidates; the requested surface objective selects
// from the same fuel-feasible pool. No global optimality is claimed.
const highwayFactor=a=>/^(motorway|motorway_link|freeway)$/.test(a.roadClassLeaf||"")?8:1;
const objectives=Object.freeze([
 {id:'paved',cost:a=>a.distanceMeters*highwayFactor(a)*(surfaceKind(a.surfaceLeaf)==='paved'?1:30)},
 {id:'dirt-10',cost:a=>a.distanceMeters*highwayFactor(a)*(surfaceKind(a.surfaceLeaf)==='dirt'?1:10)},
 {id:'dirt-30',cost:a=>a.distanceMeters*highwayFactor(a)*(surfaceKind(a.surfaceLeaf)==='dirt'?1:30)}
]);
const expandedObjectives=Object.freeze([...objectives,{id:'mixed-2',cost:a=>a.distanceMeters*highwayFactor(a)*(surfaceKind(a.surfaceLeaf)==='dirt'?1:2)},{id:'mixed-3',cost:a=>a.distanceMeters*highwayFactor(a)*(surfaceKind(a.surfaceLeaf)==='dirt'?1:3)},{id:'mixed-5',cost:a=>a.distanceMeters*highwayFactor(a)*(surfaceKind(a.surfaceLeaf)==='dirt'?1:5)}]);
function createRideAlternativeContext(){return {preparationCache:createPreparationCache(),reverseCostCache:createReverseCostCache(),stationMatchCache:createStationMatchCache()};}
function buildRideAlternatives(options) {
 const context=options.context||createRideAlternativeContext(),results=[];
 const candidates=options.expandedCandidates?expandedObjectives:objectives;
 for(const objective of candidates) {
  if(!options.budget.check())break;
  const result=buildFromHere({...options,...context,objectiveId:objective.id,edgeCost:objective.cost,preferOnwardFuel:options.preferOnwardFuel===true});
  results.push({id:objective.id,result});
  if(options.budget.snapshot().reason)break;
 }
 const poolComplete=results.length===candidates.length&&!options.budget.snapshot().reason&&results.every(r=>['provisional_station_access','verified','not_requested'].includes(r.result.fuel.state));
 const profile=options.input.legs[0].profile;
 const roads=results.filter(r=>r.result.road.state==='complete');
 const feasible=roads.filter(r=>['provisional_station_access','verified','not_requested'].includes(r.result.fuel.state));
 const pool=feasible.length?feasible:roads;
 pool.sort((a,b)=>(a.result.road.avoidanceMeters??a.result.road.urbanMeters??0)-(b.result.road.avoidanceMeters??b.result.road.urbanMeters??0)||compareSurface(profile,a.result.road.surface,b.result.road.surface)||a.id.localeCompare(b.id));
 const selected=pool[0];
 return {state:selected?'complete':'incomplete',selected:selected?.result||null,selectedObjective:selected?.id||null,
  candidates:results.map(r=>({id:r.id,road:r.result.road.state,fuel:r.result.fuel.state,reason:r.result.fuel.reason,surface:r.result.road.surface,urbanMeters:r.result.road.urbanMeters,timing:r.result.timing,repeatedRoadMeters:r.result.qualityAudit?.repeatedRoadMeters})),
  search:{...options.budget.snapshot(),poolComplete},
  limitations:['bounded shared candidate pool; not global best ride proof','station access may remain provisional']};
}
module.exports={buildRideAlternatives,createRideAlternativeContext};
