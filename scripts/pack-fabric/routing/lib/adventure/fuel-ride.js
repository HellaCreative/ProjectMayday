"use strict";
const {fuelCovers,validateFuel}=require("./fuel-math");

const {searchResourcePath}=require("./resource-search");

// Experimental orchestration for one primary leg on an already matched graph.
// The inexpensive road candidate is retained for advisory display. The fuel
// search then constructs a feasible ride with refills in its state; it doesn't
// search for pumps near that candidate and repeatedly insert new detours.
function searchFuelRide({graph,start,end,edgeCost,budget,fuel,lowerBounds=null,initialTurnState=null,avoidanceCost=null,onRoadCandidate=null,maxFuelLabels=Infinity}) {
  if(fuel!=null)validateFuel(fuel);
  const base={graph,start,end,edgeCost,budget,lowerBounds,initialTurnState,avoidanceCost};
  const road=searchResourcePath(base);
  if(road.state!=="found")return {road,fuel:{state:"unverified",reason:road.reason},search:budget.snapshot()};
  if(onRoadCandidate)onRoadCandidate(road);
  if(!fuel)return {road,fuel:{state:"not_requested"},search:budget.snapshot()};
  if(!Number.isFinite(fuel.initialUsableMeters))return {road,fuel:{state:"unverified",reason:"initial_fuel_unknown"},search:budget.snapshot()};
  if(graph.stationCount===0)return {road,fuel:{state:"unverified",reason:"no_station_bindings"},search:budget.snapshot()};
  const escapes=new Map();
  let escapeSearches=0;
  function acceptGoal({node,turnState,remainingUsableMeters}) {
    // Arrival direction and full restriction state affect which pump is
    // reachable. Distance-to-nearest by coordinate cannot establish escape.
    const key=graph.stateKey(node,turnState);
    let escape=escapes.get(key);
    if(!escape) {
      escapeSearches++;
      escape=searchResourcePath({graph,start:node,end:node=>!!graph.stationAt(node),initialTurnState:turnState,
        edgeCost:arc=>arc.distanceMeters,budget});
      if(escape.state!=="incomplete")escapes.set(key,escape);
    }
    if(escape.state!=="found")return {accepted:false};
    const finalNode=escape.arcs.length?escape.arcs[escape.arcs.length-1].to:node;
    return {accepted:fuelCovers(remainingUsableMeters,escape.distanceMeters),
      evidence:{stationId:graph.stationAt(finalNode).id,distanceMeters:escape.distanceMeters,arcs:escape.arcs,
        ...(graph.stationAt(finalNode).accessEvidence?{accessEvidence:graph.stationAt(finalNode).accessEvidence}:{})}};
  }
  const result=searchResourcePath({...base,fuel,acceptGoal,maxLabels:maxFuelLabels});
  if(result.state!=="found")return {road,fuel:{state:"unverified",
    reason:result.state==="incomplete"?result.reason:"no_feasible_chain_in_matched_graph"},fuelSearch:result,
    escapeSearches,search:budget.snapshot()};
  // A required destination at a station explicitly plans a refill even when
  // arrival fuel was already enough to satisfy the zero-distance escape.
  const arrivalUsableMeters=result.remainingUsableMeters;
  const destinationStation=graph.stationAt(end);
  if(destinationStation) {
    if(!result.visits.some(visit=>visit.stationId===destinationStation.id&&visit.atMeters===result.distanceMeters)) {
      result.visits.push({stationId:destinationStation.id,atMeters:result.distanceMeters,
        ...(destinationStation.accessEvidence?{accessEvidence:destinationStation.accessEvidence}:{})});
    }
    result.remainingUsableMeters=fuel.usableRangeMeters;
  }
  const provisional=result.visits.some(v=>v.accessEvidence==="legal_road_projection")||result.goalEvidence?.accessEvidence==="legal_road_projection";
  return {road:result,fuel:{state:provisional?"provisional_station_access":"verified_on_supplied_station_access",arrivalUsableMeters,
    departureUsableMeters:result.remainingUsableMeters,
    destinationEscape:result.goalEvidence,plannedRefills:result.visits},escapeSearches,search:budget.snapshot()};
}
module.exports={searchFuelRide};
