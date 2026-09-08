"use strict";
// A trigger to investigate, never a ban on access to a necessary pump.
const investigationMeters=1000;
function fuelSpurStation(result) {
 const audit=result.qualityAudit,visits=result.fuel.plannedRefills;
 if(audit?.state!=='complete'||audit.repeatedRoadMeters<investigationMeters||!visits?.length)return null;
 let longest=0,station=null;
 for(const revisit of audit.revisitedNodes) {
  const length=revisit.atMeters-revisit.firstAtMeters;
  if(length<=longest||length<2*investigationMeters)continue;
  const inside=visits.filter(v=>v.movable&&v.atMeters>revisit.firstAtMeters&&v.atMeters<revisit.atMeters);
  // A multi-stop circuit needs a wider itinerary decision, not this one-pump trial.
  if(inside.length===1){longest=length;station=inside[0].stationId;}
 }
 return station;
}
function preferFuelAlternative(original,alternative) {
 if(!['provisional_station_access','verified'].includes(alternative.fuel?.state)||alternative.qualityAudit?.state!=='complete')return false;
 if((alternative.road.avoidanceMeters||0)>(original.road.avoidanceMeters||0))return false;
 if(alternative.qualityAudit.repeatedRoadMeters>=original.qualityAudit.repeatedRoadMeters)return false;
 // Compare fresh dirt earned per kilometre actually ridden. Displayed surface
 // totals remain the physical totals; retracing dirt cannot inflate this score.
 const fresh=r=>(r.road.surface.knownDirtMeters-r.qualityAudit.repeatedKnownDirtMeters)/Math.max(1,r.road.distanceMeters);
 return fresh(alternative)>fresh(original)&&alternative.road.distanceMeters<original.road.distanceMeters;
}
module.exports={fuelSpurStation,preferFuelAlternative};
