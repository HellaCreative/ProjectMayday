"use strict";
const {normalizeRequest}=require("./contracts");
const {createPreparationCache}=require("./preparation-cache");
const {urbanAreasFromPack}=require("./urban-exposure");
const {matchStations}=require("./station-matching");
const {selectConnectedSnapPair}=require("../legal-topology/snap");
const {haversineMeters}=require("../legal-topology/find-path-v4");
const {pointFromMatch,materializeRoute}=require("./route-geometry");
const {createProjectedGraph}=require("./projected-graph");
const {buildLowerBounds}=require("./resource-search");
const {searchFuelRide}=require("./fuel-ride");
const {proveFuel}=require("./fuel-proof");

// Experimental single-region From Here integration. Road projections are
// explicitly provisional station access; they never become physical entrance
// proof. Caller supplies the experimental cost model, not a hidden final style.
function buildFromHere({input,pack,geom,revision,stations,budget,edgeCost,objectiveId,
  preparationCache=createPreparationCache(),stationRadiusMeters=150,endpointRadiusMeters=2000,maxFuelLabels=100000}) {
  const request=normalizeRequest(input);
  if(request.mode!=="from_here")throw new TypeError("From Here requires exactly two fixed rider anchors");
  if(typeof edgeCost!=="function"||!objectiveId)throw new TypeError("Explicit experimental objective required");
  if(!Array.isArray(stations))throw new TypeError("Canonical station records required");
  const stationById=new Map();
  for(const station of stations) {
    if(typeof station?.id!=="string"||!station.id||stationById.has(station.id))throw new TypeError("Unique canonical station identities required");
    stationById.set(station.id,station);
  }
  const timing={},at=performance.now(),classification=urbanAreasFromPack(pack),allowUnknown=request.legs[0].allowUnknown;
  let stage="preparation",fallback=null,stationDiagnostics=null;
  const provenance={revision,objectiveId,maxFuelLabels,regionId:pack.regionId||pack.meta?.regionId,classification:classification.evidence};
  function incomplete(reason) {
    return {request,provenance,road:fallback||{state:"unverified"},fuel:{state:"unverified",reason},
      stage,stationDiagnostics,timing:{...timing,totalMs:Math.round(performance.now()-at)},search:budget.snapshot()};
  }
  const prepared=preparationCache.prepare({pack,geom,revision,areas:classification.areas,budget});
  if(prepared.state!=="complete")return incomplete(prepared.reason);
  timing.preparationMs=Math.round(performance.now()-at);provenance.preparationCacheHit=prepared.cacheHit;
  const {index,urban}=prepared.prepared;
  stage="endpoint_matching";let phase=performance.now();
  const endpoints=matchStations({pack,geom,index,stations:request.anchors,maxMeters:endpointRadiusMeters,allowUnknown,budget});
  if(endpoints.state!=="complete")return incomplete(endpoints.reason);
  const picked=selectConnectedSnapPair(pack,endpoints.matches[0].candidates,endpoints.matches[1].candidates,{allowUnknown});
  if(!picked.ok)return incomplete(`endpoint_${picked.reason}`);
  const selected=[picked.start,picked.end];
  const points=request.anchors.map((anchor,i)=> {
    let binding=null;
    if(anchor.stationId) {
      const station=stationById.get(anchor.stationId),match=selected[i];
      if(!station||![station.lat,station.lon].every(Number.isFinite)||Math.abs(station.lat)>90||Math.abs(station.lon)>180||haversineMeters([station.lon,station.lat],[anchor.lon,anchor.lat])>stationRadiusMeters||
        haversineMeters([station.lon,station.lat],[match.lon,match.lat])>stationRadiusMeters)throw new TypeError("Fixed station anchor does not match canonical station location");
      binding={id:station.id,accessEvidence:"legal_road_projection"};
    }
    return pointFromMatch(`anchor-${i}`,selected[i],geom,budget,binding);
  });
  if(points.some(p=>!p))return incomplete(budget.snapshot().reason);
  timing.endpointMatchingMs=Math.round(performance.now()-phase);
  stage="station_matching";phase=performance.now();
  const matched=matchStations({pack,geom,index,stations,maxMeters:stationRadiusMeters,allowUnknown,budget});
  stationDiagnostics={sourceCount:stations.length,matchingState:matched.state,matchingRadiusMeters:stationRadiusMeters,
    records:matched.matches,accessEvidence:"legal_road_projection"};
  if(matched.state!=="complete")return incomplete(matched.reason);
  const bindingById=new Map(),occupied=new Map();
  const pointKey=p=>p.fraction===0?`node:${pack.edgeFrom[p.edgeIndex]}`:p.fraction===1?`node:${pack.edgeTo[p.edgeIndex]}`:`edge:${p.edgeIndex}:${p.fraction}`;
  for(const point of points)if(point.station)occupied.set(pointKey(point),point.station.id);
  stationDiagnostics.coincidentAlternatives=[];
  for(const row of matched.matches) {
    if(!budget.consume())return incomplete(budget.snapshot().reason);
    if(row.state!=="candidates")continue;
    // Retain all candidate evidence, but choose one nearest eligible road
    // position per station for this first experiment. No cross-road stitching.
    const match=row.candidates[0],station=stationById.get(row.stationId);
    const point=pointFromMatch(`station-${row.stationId}`,match,geom,budget,{id:row.stationId,accessEvidence:"legal_road_projection"});
    if(!point)return incomplete(budget.snapshot().reason);
    bindingById.set(row.stationId,{station,match,point});
    const key=pointKey(point),existing=occupied.get(key);
    if(existing) {
      if(existing!==row.stationId)stationDiagnostics.coincidentAlternatives.push({stationId:row.stationId,representedBy:existing,match});
      continue;
    }
    occupied.set(key,row.stationId);points.push(point);
  }
  timing.stationMatchingMs=Math.round(performance.now()-phase);
  stage="projected_graph";phase=performance.now();
  const graph=createProjectedGraph(pack,{points,budget,allowUnknown,allowProvisionalStations:true,
    endpointEdges:points.slice(0,2).map(p=>p.edgeIndex)});
  if(graph.state!=="complete")return incomplete(graph.reason);
  timing.projectedGraphMs=Math.round(performance.now()-phase);
  const start=graph.pointNodes.get("anchor-0"),end=graph.pointNodes.get("anchor-1");
  stage="reverse_bounds";phase=performance.now();
  const bounds=buildLowerBounds({graph,nodeCount:graph.nodeCount,target:end,edgeCost,budget});
  if(bounds.state!=="complete")return incomplete(bounds.reason);
  timing.reverseBoundsMs=Math.round(performance.now()-phase);
  stage="fuel_search";phase=performance.now();
  const result=searchFuelRide({graph,start,end,edgeCost,budget,fuel:request.fuel,lowerBounds:bounds,avoidanceCost:urban.urbanMeters,maxFuelLabels,
    onRoadCandidate:road=>{const rendered=materializeRoute({pack,geom,result:road,budget});if(rendered.state==="complete")fallback=rendered;}});
  timing.searchAndAdvisoryMs=Math.round(performance.now()-phase);
  if(result.road.state!=="found")return incomplete(result.road.reason);
  if(!["provisional_station_access","verified_on_supplied_station_access"].includes(result.fuel.state)) {
    return {...incomplete(result.fuel.reason||result.fuel.state),fuel:result.fuel};
  }
  stage="geometry_and_fuel_proof";phase=performance.now();
  const road=materializeRoute({pack,geom,result:result.road,budget});
  if(road.state!=="complete")return incomplete(road.reason);
  const escape=result.fuel.destinationEscape;
  const proof=proveFuel({...request.fuel,segments:road.segments,visits:result.road.visits.map((v,i)=>({...v,id:`fuel-${i}`,refuel:true,
    legalStationVisit:v.accessEvidence==="verified"})),allowProvisionalStations:true,budget,
    destinationEscape:{...escape,state:escape.accessEvidence==="legal_road_projection"?"provisional_station_access":"verified"}});
  const stops=result.road.visits.map(v=>{
    const riderAnchorIds=request.anchors.filter((a,i)=>a.stationId===v.stationId&&v.atMeters===(i===0?0:road.distanceMeters)).map(a=>a.id);
    return {...v,riderAnchorIds,movable:riderAnchorIds.length===0,station:stationById.get(v.stationId),roadMatch:bindingById.get(v.stationId)?.match||null};
  });
  timing.geometryAndProofMs=Math.round(performance.now()-phase);
  return {request,provenance,road,fuel:{...proof,plannedRefills:stops,destinationEscape:escape},stage:"complete",
    stationDiagnostics,timing:{...timing,totalMs:Math.round(performance.now()-at)},
    search:{...budget.snapshot(),fuelSearch:result.road.diagnostics,escapeSearches:result.escapeSearches},
    limitations:["nearest eligible road projection does not prove station entrance/exit or operation",
      "one station projection and one connected endpoint pair; alternatives not exhausted",
      "experimental additive ride objective; full profile quality not qualified","single region; no app/API adapter"]};
}
module.exports={buildFromHere};
