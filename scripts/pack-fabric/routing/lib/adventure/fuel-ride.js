"use strict";
const {fuelCovers,validateFuel}=require("./fuel-math");

const {searchResourcePath}=require("./resource-search");

// Experimental orchestration for one primary leg on an already matched graph.
// The inexpensive road candidate is retained for advisory display. The fuel
// search then constructs a feasible ride with refills in its state; it doesn't
// search for pumps near that candidate and repeatedly insert new detours.
function searchFuelRide({graph,start,end,edgeCost,budget,fuel,lowerBounds=null,avoidanceLowerBounds=null,initialTurnState=null,avoidanceCost=null,onRoadCandidate=null,maxFuelLabels=Infinity,fuelHeuristicWeight=1,preferOnwardFuel=false,retainFuelApproach=false,dirtEntryCost=0,fuelFirst=false,allowZeroRefillAdvisory=false,allowPassingRefillAdvisory=false}) {
  if(fuel!=null)validateFuel(fuel);
  const base={graph,start,end,edgeCost,budget,lowerBounds,avoidanceLowerBounds,initialTurnState,avoidanceCost,dirtEntryCost};
  let road;
  function advisory(){
    if(!road){road=searchResourcePath(base);if(road.state==='found'&&onRoadCandidate)onRoadCandidate(road);}
    return road;
  }
  // Continuations already have a retained itinerary. Search the actual fuel
  // problem first; an advisory road is needed only if that cannot be proved.
  if(!fuelFirst||!fuel||!Number.isFinite(fuel.initialUsableMeters)||graph.stationCount===0) {
    advisory();
    if(road.state!=="found")return {road,fuel:{state:"unverified",reason:road.reason},search:budget.snapshot()};
  }
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
  const searchOptions={...base,fuel,acceptGoal,maxLabels:maxFuelLabels,heuristicWeight:fuelHeuristicWeight,preferOnwardFuel};
  let result;
  // The unweighted, fuel-relaxed search is a lower bound on the fuel problem:
  // minimum urban exposure, then objective cost. A feasible no-repeat result
  // also has the minimum possible retrace (zero) and refill count (zero).
  // Checking arrival-direction escape closes the remaining fuel constraint.
  // This proves the objective, not identity with heuristic-weighted search.
  if(allowZeroRefillAdvisory) {
    const candidate=advisory(),seen=new Set();
    const noRepeat=candidate.state==='found'&&candidate.arcs.every(arc=>{
      if(seen.has(arc.id))return false;seen.add(arc.id);return true;
    });
    if(noRepeat&&fuelCovers(fuel.initialUsableMeters,candidate.distanceMeters)) {
      const remaining=fuel.initialUsableMeters-candidate.distanceMeters;
      const escape=acceptGoal({node:end,turnState:candidate.endTurnState,remainingUsableMeters:remaining});
      if(escape.accepted&&budget.check())result={...candidate,visits:[],remainingUsableMeters:remaining,
        goalEvidence:escape.evidence,diagnostics:{...candidate.diagnostics,zeroRefillAdvisory:true,zeroRefillProof:"minimum-objective-zero-retrace-with-legal-escape"}};
    }
  }
  // Candidate-only fast path: certify fuel on the exact no-repeat road optimum.
  // No roads or detours are inserted. Refills are minimal on this fixed path;
  // no global refill tie-break optimality across equal-cost roads is claimed.
  if(!result&&allowPassingRefillAdvisory) {
    const candidate=advisory(),seen=new Set();
    const noRepeat=candidate.state==='found'&&candidate.arcs.every(arc=>{
      if(seen.has(arc.id))return false;seen.add(arc.id);return true;
    });
    if(noRepeat) {
      const escape=acceptGoal({node:end,turnState:candidate.endTurnState,remainingUsableMeters:fuel.usableRangeMeters});
      if(escape.accepted) {
        const pumps=[];let meters=0;
        const append=node=>{const station=graph.stationAt(node);if(station)pumps.push({stationId:station.id,atMeters:meters,...(station.accessEvidence?{accessEvidence:station.accessEvidence}:{})});};
        append(start);
        for(const arc of candidate.arcs){if(!budget.consume())break;meters+=arc.distanceMeters;append(arc.to);}
        const target=candidate.distanceMeters+escape.evidence.distanceMeters;
        const visits=[];let reach=fuel.initialUsableMeters,index=0,possible=true;
        while(!fuelCovers(reach,target)&&budget.consume()) {
          let last=null;
          while(index<pumps.length&&fuelCovers(reach,pumps[index].atMeters))last=pumps[index++];
          if(!last||last.atMeters+fuel.usableRangeMeters<=reach){possible=false;break;}
          visits.push(last);reach=last.atMeters+fuel.usableRangeMeters;
        }
        if(possible&&fuelCovers(reach,target)&&budget.check())result={...candidate,visits,
          remainingUsableMeters:Math.max(0,reach-candidate.distanceMeters),goalEvidence:escape.evidence,
          diagnostics:{...candidate.diagnostics,passingRefillAdvisory:true,
            passingRefillProof:'minimum-road-objective-zero-retrace-fixed-path-fuel-and-legal-escape'}};
      }
    }
  }
  if(!result)result=searchResourcePath(searchOptions);
  if(result.state!=="found")return {road:advisory(),fuel:{state:"unverified",
    reason:result.state==="incomplete"?result.reason:"no_feasible_chain_in_matched_graph"},fuelSearch:result,
    escapeSearches,search:budget.snapshot()};
  // Spend the extra approach-history search only on a completed candidate
  // containing repeated roads. Refills remain part of that new search, never
  // inserted into finished geometry. Preserve the feasible result if the
  // bounded refinement cannot improve it; diagnostics expose that outcome.
  if(retainFuelApproach&&preferOnwardFuel) {
    const repetition=route=>{
      const seen=new Set();let meters=0;
      for(const arc of route.arcs){
        const key=JSON.stringify([arc.id,...[arc.from,arc.to].sort()]);
        if(seen.has(key))meters+=arc.distanceMeters;else seen.add(key);
      }
      return meters;
    };
    const before=repetition(result);
    if(before>0) {
      const refined=searchResourcePath({...searchOptions,retainFuelApproach:true});
      const after=refined.state==='found'?repetition(refined):null;
      const accepted=after!==null&&after<before&&refined.avoidanceCost<=result.avoidanceCost;
      const refinement={state:refined.state,reason:refined.reason??null,beforeMeters:before,afterMeters:after,accepted};
      if(accepted)result=refined;
      result.diagnostics.approachRefinement=refinement;
    }
  }
  if(fuelFirst&&onRoadCandidate)onRoadCandidate(result);
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
