"use strict";
const {buildRideAlternatives}=require('./ride-alternatives');
const {haversineMeters}=require('../legal-topology/find-path-v4');

// A replacement is an explicit first refill, followed by a proved continuation.
// Both searches share the caller's work/deadline budget and existing objectives.
function buildFuelReplacement({body,options,identity,routeResponse,toLiveResponse,build=buildRideAlternatives}) {
 const fail=reason=>({status:'unknown',error:reason,message:'This fuel stop could not be verified for this route.',routes:[],stops:[],windowComplete:false,diagnostics:{strategy:'adventure-preview-v1',reason}});
 const station=options.stations.find(s=>s.id===body.fuel.requiredFirstStationId);
 if(!station)return fail('replacement_station_unavailable');
 const [start,end]=options.input.anchors;
 const pump={id:'replacement',lat:station.lat,lon:station.lon,stationId:station.id};
 const leg=options.input.legs[0];
 const first=build({...options,stations:[station],input:{...options.input,anchors:[start,pump],legs:[{...leg,to:pump.id}]}});
 const a=first.selected;
 if(!first.search.poolComplete||!a||!['verified','provisional_station_access'].includes(a.fuel.state))return fail('replacement_approach_unproved');
 const meters=a.road.distanceMeters,last=a.road.geometry.at(-1);
 if(!Number.isFinite(meters)||meters<=0||meters>body.fuel.firstLegMaxMeters+1e-6||!last||haversineMeters(last,[station.lon,station.lat])>150||
    a.fuel.plannedRefills.some(v=>v.atMeters>1e-6&&v.atMeters<meters-1e-6))return fail('replacement_outside_remaining_range');
 const edges=a.road.segments.map(s=>s.edgeId).filter(Boolean);
 const next=build({...options,arrivalHistory:{priorEdgeIds:[...(options.arrivalHistory?.priorEdgeIds||[]),...edges].slice(-256),arrivalEdgeId:edges.at(-1)},
  input:{...options.input,anchors:[{...pump,lat:last[1],lon:last[0]},end],legs:[{...leg,from:pump.id}],fuel:{...options.input.fuel,initialUsableMeters:body.fuel.usableRangeMeters}}});
 const maxStops=body.fuel.windowMaxStops;
 if(maxStops!=null&&maxStops<1)return fail('replacement_window_unavailable');
 const tail=toLiveResponse(next,{...body,fuel:{...body.fuel,firstLegMaxMeters:body.fuel.usableRangeMeters,windowMaxStops:maxStops==null?undefined:maxStops-1}},'fuel',identity);
 if(tail.status!=='complete'||!tail.windowComplete)return fail('replacement_continuation_unproved');
 const head=routeResponse(a.road.segments,body.profile,identity,{strategy:'adventure-preview-v1',selectedReason:first.selectedObjective});
 const tailStart=tail.routes[0]?.geometry?.[0];
 if(!tailStart||haversineMeters(last,tailStart)>1)return fail('replacement_geometry_disconnected');
 return {...tail,routes:[head,...tail.routes],stops:[{...station,latitude:station.lat,longitude:station.lon,graphMeters:meters},...tail.stops.map(s=>({...s,graphMeters:s.graphMeters+meters}))],
  graphMeters:[meters,...tail.graphMeters],diagnostics:{...tail.diagnostics,requiredFirstStationId:station.id},
  fuelAccessEvidence:'provisional_station_access'};
}
module.exports={buildFuelReplacement};
