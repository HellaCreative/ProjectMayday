"use strict";
const {normalizeRequest}=require("./contracts");
const {createReverseCostCache}=require("./reverse-cost-cache");
const {createPreparationCache}=require("./preparation-cache");
const {urbanAreasFromPack}=require("./urban-exposure");
const {createStationMatchCache}=require("./station-match-cache");
const {matchStations}=require("./station-matching");
const {selectConnectedSnapPair,weakComponentIds}=require("../legal-topology/snap");
const {haversineMeters}=require("../legal-topology/find-path-v4");
const {pointFromMatch,materializeRoute}=require("./route-geometry");
const {createProjectedGraph}=require("./projected-graph");
const {buildLowerBounds}=require("./resource-search");
const {searchFuelRide}=require("./fuel-ride");
const {auditRideShape}=require("./ride-shape-audit");
const {proveFuel}=require("./fuel-proof");

// Experimental single-region From Here integration. Road projections are
// explicitly provisional station access; they never become physical entrance
// proof. Caller supplies the experimental cost model, not a hidden final style.
function buildFromHere({input,pack,geom,revision,stations,budget,preparationBudget=budget,edgeCost,objectiveId,
  preparationCache=createPreparationCache(),reverseCostCache=createReverseCostCache(),stationMatchCache=createStationMatchCache(),stationRadiusMeters=150,endpointRadiusMeters=2000,maxFuelLabels=100000,fuelHeuristicWeight=1,avoidMotorways=false,ridePreferences=null,additionalUrbanAreas=[],preferOnwardFuel=false,retainFuelApproach=false,dirtEntryCost=0,arrivalHistory=null,fuelFirst=false}) {
  if(preparationBudget.snapshot().deadlineAtMs>budget.snapshot().deadlineAtMs)throw new TypeError("Preparation cannot outlive the request deadline");
  const request=normalizeRequest(input);
  if(request.mode!=="from_here")throw new TypeError("From Here requires exactly two fixed rider anchors");
  if(typeof edgeCost!=="function"||!objectiveId)throw new TypeError("Explicit experimental objective required");
  if(!Array.isArray(stations))throw new TypeError("Canonical station records required");
  const stationById=new Map();
  for(const station of stations) {
    if(typeof station?.id!=="string"||!station.id||stationById.has(station.id))throw new TypeError("Unique canonical station identities required");
    stationById.set(station.id,station);
  }
  const timing={},at=performance.now(),classification=urbanAreasFromPack(pack,{additionalAreas:additionalUrbanAreas}),allowUnknown=request.legs[0].allowUnknown;
  let stage="preparation",fallback=null,stationDiagnostics=null;
  const provenance={revision,objectiveId,maxFuelLabels,fuelHeuristicWeight,dirtEntryCost,regionId:pack.regionId||pack.meta?.regionId,classification:classification.evidence};
  function incomplete(reason) {
    return {request,provenance,road:fallback||{state:"unverified"},fuel:{state:"unverified",reason},
      stage,stationDiagnostics,timing:{...timing,totalMs:Math.round(performance.now()-at)},search:budget.snapshot()};
  }
  const prepared=preparationCache.prepare({pack,geom,revision,areas:classification.areas,budget:preparationBudget});
  provenance.preparationWork={...preparationBudget.snapshot(),separateAllowance:preparationBudget!==budget};
  if(prepared.state!=="complete")return incomplete(prepared.reason);
  timing.preparationMs=Math.round(performance.now()-at);provenance.preparationCacheHit=prepared.cacheHit;
  const {index,urban}=prepared.prepared;
  const isMotorway=arc=>/^(motorway|motorway_link|freeway)$/.test(arc.roadClassLeaf||"");
  // Minimize exposure before ride cost. Necessary connections stay available;
  // a shorter motorway is never a reason to abandon a zero-exposure connection.
  edgeCost=require("./ride-preferences").preferenceEdgeCost(edgeCost,ridePreferences);
  const avoidanceCost=ridePreferences
    ? (ridePreferences.avoidCities?urban.urbanMeters:()=>0)
    : avoidMotorways?arc=>isMotorway(arc)?arc.distanceMeters:urban.urbanMeters(arc):urban.urbanMeters;
  function recordExposure(road,result) {
    road.avoidanceMeters=result.avoidanceCost;
    road.urbanMeters=result.arcs.reduce((sum,arc)=>sum+urban.urbanMeters(arc),0);
    road.motorwayMeters=result.arcs.reduce((sum,arc)=>sum+(isMotorway(arc)?arc.distanceMeters:0),0);
  }
  stage="endpoint_matching";let phase=performance.now();
  let radius=Math.min(2000,endpointRadiusMeters);
  let endpoints=matchStations({pack,geom,index,stations:request.anchors,maxMeters:radius,allowUnknown,budget});
  if(endpoints.state!=="complete")return incomplete(endpoints.reason);
  const {resolveHistory,directedArrival}=require('./arrival-history');
  const history=resolveHistory(pack,arrivalHistory?.priorEdgeIds||[],arrivalHistory?.arrivalEdgeId,budget);
  if(history.state!=='complete')return incomplete(history.reason);
  if(history.edges.length){
    const prior=new Set(history.edges),baseCost=edgeCost;
    // Positive cost discourages recently ridden roads without rewarding a
    // circuit or forbidding a necessary return from a fixed rider waypoint.
    const factor=ridePreferences?.preferDifferentRoads?16:4;
    edgeCost=arc=>baseCost(arc)*(prior.has(arc.id)?factor:1);
    provenance.priorRoadPreference={edges:prior.size,factor};
  }
  let startCandidates=history.edges.length?(endpoints.matches[0].candidates||[]).filter(c=>c.edgeIndex===history.edges.at(-1)):endpoints.matches[0].candidates||[];
  const endCandidates=endpoints.matches[1].candidates||[];
  let picked=selectConnectedSnapPair(pack,startCandidates,endCandidates,{allowUnknown});
  // The app recognizes a rider waypoint at a mapped pump within 150 m.
  // Such a point is a fixed service destination, not a broad area selection.
  const fixedFuel=request.anchors.map(a=>Boolean(a.stationId)||stations.some(s=>
    haversineMeters([a.lon,a.lat],[s.lon,s.lat])<=stationRadiusMeters));
  let startComponentRecovery=false;
  // Candidate caps can hide a nearby connected road behind several isolated
  // edges. Re-query against the destination components without changing the
  // allowed radius, access checks, fixed fuel stop or exact arrival edge.
  function recoverStart() {
    if(picked.ok||fixedFuel[0]||history.edges.length||!endCandidates.length)return null;
    const components=weakComponentIds(pack,allowUnknown);
    const endComponents=new Set(endCandidates.map(c=>components[pack.edgeFrom[c.edgeIndex]]));
    const starts=matchStations({pack,geom,index,stations:[request.anchors[0]],maxMeters:radius,allowUnknown,budget,
      eligibleEdge:e=>endComponents.has(components[pack.edgeFrom[e]])});
    if(starts.state==='complete') {
      picked=selectConnectedSnapPair(pack,starts.matches[0].candidates,endCandidates,{allowUnknown});
      startComponentRecovery=picked.ok;
    }
    return starts;
  }
  const recovered=recoverStart();
  if(recovered&&recovered.state!=='complete')return incomplete(recovered.reason);
  let attempts=1;
  while(!picked.ok&&radius<endpointRadiusMeters) {
    if(fixedFuel[1]&&startCandidates.length&&(!endCandidates.length||fixedFuel[0]||history.edges.length))break;
    if(!budget.check())return incomplete(budget.snapshot().reason);
    radius=Math.min(endpointRadiusMeters,radius*2);attempts++;
    if(!startCandidates.length&&!fixedFuel[0]){
      const starts=matchStations({pack,geom,index,stations:[request.anchors[0]],maxMeters:radius,allowUnknown,budget,
        eligibleEdge:history.edges.length?e=>e===history.edges.at(-1):null});
      if(starts.state!=='complete')return incomplete(starts.reason);
      startCandidates=starts.matches[0].candidates||[];
    }
    const components=weakComponentIds(pack,allowUnknown);
    const allowed=new Set(startCandidates.map(c=>components[pack.edgeFrom[c.edgeIndex]]));
    const ends=matchStations({pack,geom,index,stations:[request.anchors[1]],maxMeters:fixedFuel[1]?Math.min(2000,radius):radius,allowUnknown,budget,
      eligibleEdge:e=>allowed.has(components[pack.edgeFrom[e]])});
    if(ends.state!=='complete')return incomplete(ends.reason);
    picked=selectConnectedSnapPair(pack,startCandidates,ends.matches[0].candidates,{allowUnknown});
    const recovered=recoverStart();
    if(recovered&&recovered.state!=='complete')return incomplete(recovered.reason);
  }
  provenance.waypointSnap={attempts,startComponentRecovery,radiusMeters:radius,maximumMeters:endpointRadiusMeters,
    ...(picked.ok?{startDistanceMeters:picked.start.distanceM,endDistanceMeters:picked.end.distanceM}:{})};
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
  const matched=stationMatchCache.match({pack,geom,revision,index,stations,maxMeters:stationRadiusMeters,allowUnknown,budget});
  provenance.stationMatchingCacheHit=matched.cacheHit;
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
  const arrival=directedArrival(pack,history.edges,points[0]);
  if(arrival.state!=='complete')return incomplete(arrival.reason);
  const initial=graph.seedArrival(arrival.arcs,'anchor-0');
  if(!initial.allowed)return incomplete('arrival_restriction_context_unproved');
  provenance.arrivalHistoryEdges=arrival.arcs.length;
  stage="reverse_bounds";phase=performance.now();
  const reverse=reverseCostCache.prepare({graph,revision,edgeCost,budget});
  provenance.reversePreparationCacheHit=reverse.cacheHit;
  if(reverse.state!=="complete")return incomplete(reverse.reason);
  const bounds=buildLowerBounds({graph,nodeCount:graph.nodeCount,target:end,edgeCost,budget,reverseCosts:reverse.reverseCosts,stopAt:start});
  if(bounds.state!=="complete")return incomplete(bounds.reason);
  timing.reverseBoundsMs=Math.round(performance.now()-phase);
  stage="fuel_search";phase=performance.now();
  const result=searchFuelRide({graph,start,end,initialTurnState:initial.state,edgeCost,budget,fuel:request.fuel,lowerBounds:bounds,avoidanceCost,maxFuelLabels,fuelHeuristicWeight,preferOnwardFuel,retainFuelApproach,dirtEntryCost,fuelFirst,
    onRoadCandidate:road=>{const rendered=materializeRoute({pack,geom,result:road,budget});if(rendered.state==="complete"){recordExposure(rendered,road);fallback=rendered;}}});
  timing.searchAndAdvisoryMs=Math.round(performance.now()-phase);
  if(result.road.state!=="found")return incomplete(result.road.reason);
  if(!["provisional_station_access","verified_on_supplied_station_access"].includes(result.fuel.state)) {
    return {...incomplete(result.fuel.reason||result.fuel.state),fuel:result.fuel};
  }
  stage="geometry_and_fuel_proof";phase=performance.now();
  const road=materializeRoute({pack,geom,result:result.road,budget});
  if(road.state!=="complete")return incomplete(road.reason);
  recordExposure(road,result.road);
  const escape=result.fuel.destinationEscape;
  const proof=proveFuel({...request.fuel,segments:road.segments,visits:result.road.visits.map((v,i)=>({...v,id:`fuel-${i}`,refuel:true,
    legalStationVisit:v.accessEvidence==="verified"})),allowProvisionalStations:true,budget,
    destinationEscape:{...escape,state:escape.accessEvidence==="legal_road_projection"?"provisional_station_access":"verified"}});
  const stops=result.road.visits.map(v=>{
    const riderAnchorIds=request.anchors.filter((a,i)=>a.stationId===v.stationId&&v.atMeters===(i===0?0:road.distanceMeters)).map(a=>a.id);
    return {...v,riderAnchorIds,movable:riderAnchorIds.length===0,station:stationById.get(v.stationId),roadMatch:bindingById.get(v.stationId)?.match||null};
  });
  const qualityAudit=auditRideShape({segments:road.segments,budget});
  timing.geometryAndProofMs=Math.round(performance.now()-phase);
  return {request,provenance,road,qualityAudit,fuel:{...proof,plannedRefills:stops,destinationEscape:escape},stage:"complete",
    stationDiagnostics,timing:{...timing,totalMs:Math.round(performance.now()-at)},
    search:{...budget.snapshot(),fuelSearch:result.road.diagnostics,escapeSearches:result.escapeSearches},
    limitations:["nearest eligible road projection does not prove station entrance/exit or operation",
      "one station projection and one connected endpoint pair; alternatives not exhausted",
      "experimental additive ride objective; full profile quality not qualified","single region; no app/API adapter"]};
}
module.exports={buildFromHere};
