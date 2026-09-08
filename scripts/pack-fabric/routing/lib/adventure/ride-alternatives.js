"use strict";
const {buildFromHere}=require('./from-here');
const {fuelSpurStation,preferFuelAlternative}=require('./fuel-spur-alternative');
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
  const result=buildFromHere({...options,...context,objectiveId:objective.id,edgeCost:objective.cost});
  results.push({id:objective.id,result});
  if(options.budget.snapshot().reason)break;
 }
 const poolComplete=results.length===candidates.length&&!options.budget.snapshot().reason;
 // Establish every base candidate before spending the remaining deadline on
 // quality trials. An interrupted trial cannot replace a feasible original.
 if(options.fuelSpurAlternatives)for(const row of results) {
  const stationId=fuelSpurStation(row.result);
  if(!stationId)continue;
  if(!options.budget.check())break;
  const original=row.result,objective=candidates.find(c=>c.id===row.id);
  const alternative=buildFromHere({...options,...context,stations:options.stations.filter(s=>s.id!==stationId),objectiveId:objective.id,edgeCost:objective.cost});
  const accepted=preferFuelAlternative(original,alternative);
  if(accepted)row.result=alternative;
  row.result.fuelSpurTrial={stationId,accepted,originalRepeatedMeters:original.qualityAudit.repeatedRoadMeters,alternativeRepeatedMeters:alternative.qualityAudit?.repeatedRoadMeters,alternativeState:alternative.fuel.state,alternativeReason:alternative.fuel.reason};
 }
 const profile=options.input.legs[0].profile;
 const roads=results.filter(r=>r.result.road.state==='complete');
 const feasible=roads.filter(r=>['provisional_station_access','verified','not_requested'].includes(r.result.fuel.state));
 const pool=feasible.length?feasible:roads;
 pool.sort((a,b)=>(a.result.road.avoidanceMeters??a.result.road.urbanMeters??0)-(b.result.road.avoidanceMeters??b.result.road.urbanMeters??0)||compareSurface(profile,a.result.road.surface,b.result.road.surface)||a.id.localeCompare(b.id));
 const selected=pool[0];
 return {state:selected?'complete':'incomplete',selected:selected?.result||null,selectedObjective:selected?.id||null,
  candidates:results.map(r=>({id:r.id,road:r.result.road.state,fuel:r.result.fuel.state,reason:r.result.fuel.reason,surface:r.result.road.surface,urbanMeters:r.result.road.urbanMeters,timing:r.result.timing,fuelSpurTrial:r.result.fuelSpurTrial})),
  search:{...options.budget.snapshot(),poolComplete},
  limitations:['bounded shared candidate pool; not global best ride proof','station access may remain provisional']};
}
module.exports={buildRideAlternatives,createRideAlternativeContext};
