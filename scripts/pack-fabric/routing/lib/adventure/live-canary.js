"use strict";
const {buildRideAlternatives,createRideAlternativeContext}=require('./ride-alternatives');
const {createBudget}=require('./budget');
const {summarizeSurface,surfaceKind}=require('./surface');
const {withServiceIdentity}=require('../service-contract');
const context=createRideAlternativeContext();
let joinedCache=null;
const {joinV4}=require('./join-v4');
const warning={code:'adventure_preview',message:'DEV routing preview. Fuel stops are planned from mapped station locations; entrances, exits and current availability are not verified.'};
function canarySupported(body,kind,environment=process.env) {
 if(!['ns-v1','ns-nb-v1'].includes(environment.DIRT_ADVENTURE_CANARY)||body.action||body.locations?.length!==2||!['dirt','balanced','cleanest'].includes(body.profile))return false;
 const o=body.options||{},f=body.fuel||{};
 if(body.accessPolicy?.motorizedPermissive===false)return false;
 if(o.avoidEdgeIds?.length||o.maxPathMeters!=null||o.regionalHopMinimumMeters?.length||o.cleanMetroMultiplier!=null)return false;
 if(kind==='fuel'&&(f.requiredFirstStationId||f.requireFuelStopBeforeEnd||f.minimumFuelStops>0||f.destinationFuelUsedLimitMeters!=null||f.forwardFeeler||f.probeFirstReachableStation))return false;
 return true;
}
function routeResponse(segments,profile,identity,diagnostics,point=null) {
 const geometry=[];
 for(const s of segments)geometry.push(...s.geometry.slice(geometry.length?1:0));
 if(!geometry.length&&point)geometry.push(point,point);
 const surface=summarizeSurface(segments),moving=segments.reduce((n,s)=>n+s.distanceMeters/(surfaceKind(s.surfaceLeaf)==='paved'?60/3.6:35/3.6),0);
 return withServiceIdentity({status:'complete',profile,geometry,segments:segments.map(s=>({...s,surfaceClass:surfaceKind(s.surfaceLeaf),accessClass:s.accessClass||'motorized_unknown'})),distanceMeters:surface.distanceMeters,
  estimatedMovingSeconds:Math.round(moving),estimatedElapsedSeconds:Math.round(moving*1.15),
  stats:{unknownAccessPercent:Math.round(segments.filter(s=>s.accessClass==="motorized_unknown").reduce((n,s)=>n+s.distanceMeters,0)/Math.max(1,surface.distanceMeters)*100),dirtPercent:Math.round(surface.knownDirtPercent),pavedPercent:Math.round(surface.pavedPercent),unknownSurfacePercent:Math.round(surface.unknownSurfacePercent),surfaceFamilyMode:'leaf-v3'},
  warnings:[warning],maneuvers:[],debug:{routingRevision:'adventure-preview-v1',engine:'adventure-shared-candidates',regionIds:identity.map(p=>p.regionId),packIdentity:identity,diagnostics}});
}
function toLiveResponse(pool,body,kind,identity) {
 const r=pool.selected;
 if(!r||!pool.search.poolComplete)return {status:'unknown',error:'adventure_search_incomplete',message:'Route search did not complete. No fuel gap has been proved.',diagnostics:{strategy:'adventure-preview-v1',reason:pool.search.reason,adventure:{candidates:pool.candidates,search:pool.search}},stops:[],routes:[],windowComplete:false};
 const diagnostics={allowUnknown:body.profile!=='cleanest'&&body.accessPolicy?.motorizedUnknown===true,mapZoom:body.options?.mapZoom,strategy:'adventure-preview-v1',selectedReason:pool.selectedObjective,adventure:{waypointSnap:r.provenance.waypointSnap,dirtEntryCost:r.provenance.dirtEntryCost,fuelHeuristicWeight:r.provenance.fuelHeuristicWeight,candidates:pool.candidates,search:pool.search,quality:r.qualityAudit,fuelState:r.fuel.state},packIdentity:identity};
 if(kind==='route')return routeResponse(r.road.segments,body.profile,identity,diagnostics);
 if(!['provisional_station_access','verified'].includes(r.fuel.state))return {status:'unknown',error:r.fuel.reason||'fuel_unverified',message:'Road found, but fuel planning remains unverified.',routes:[routeResponse(r.road.segments,body.profile,identity,diagnostics)],stops:[],windowComplete:true,diagnostics};
 const visits=r.fuel.plannedRefills;
 if(visits.some(v=>v.atMeters<=1e-6||v.atMeters>=r.road.distanceMeters-1e-6))return {status:'unknown',error:'adventure_endpoint_refill_unqualified',routes:[],stops:[],windowComplete:false,diagnostics};
 const maxStops=body.fuel.windowMaxStops??visits.length;
 if(!Number.isSafeInteger(maxStops)||maxStops<0||(maxStops===0&&visits.length>0)||(!body.fuel.allowPartialWindow&&visits.length>maxStops))return {status:'unknown',error:'adventure_fuel_window_unsupported',routes:[],stops:[],windowComplete:false,diagnostics};
 const kept=visits.slice(0,maxStops),complete=kept.length===visits.length;
 const boundaries=kept.map(v=>v.atMeters);if(complete)boundaries.push(r.road.distanceMeters);
 const routes=[];let at=0,index=0;
 for(const boundary of boundaries){const segments=[];while(index<r.road.segments.length&&at<boundary-1e-6){const s=r.road.segments[index++];segments.push(s);at+=s.distanceMeters;}
  if(Math.abs(at-boundary)>1e-4)throw Error('Fuel stop does not coincide with a built road position');
  routes.push(routeResponse(segments,body.profile,identity,diagnostics));
 }
 return {status:'complete',message:warning.message,stops:kept.map(v=>({...v.station,graphMeters:v.atMeters})),routes,graphMeters:routes.map(r=>r.distanceMeters),windowComplete:complete,
  regionIds:identity.map(p=>p.regionId),packIdentity:identity,destinationEscapeMeters:complete?r.fuel.destinationEscape.distanceMeters:null,diagnostics,
  fuelAccessEvidence:r.fuel.state};
}
async function adventureCanaryRequest(body,kind,{environment=process.env,load=null}={}) {
 if(!canarySupported(body,kind,environment)){
  // Within the opted-in Atlantic ride flow, unsupported context is an explicit
  // incomplete result, never a silent switch to the retired engine.
  if(body.action||!['ns-v1','ns-nb-v1'].includes(environment.DIRT_ADVENTURE_CANARY)||body.locations?.length!==2||!['dirt','balanced','cleanest'].includes(body.profile))return null;
  const r=require('../../regional/select').resolveGraphRequest(body),enabled=environment.DIRT_ADVENTURE_CANARY==='ns-nb-v1'?['ns','nb']:['ns'];
  if(!r.ok||!r.regionIds.length||r.regionIds.some(id=>!enabled.includes(id)))return null;
  return {status:'unknown',error:'adventure_unsupported_controls',message:'This route request needs controls not yet supported by the new engine.',routes:[],stops:[],windowComplete:false,diagnostics:{strategy:'adventure-preview-v1',reason:'unsupported_controls'}};
 }
 if(kind==='fuel'&&(!Number.isFinite(body.fuel?.usableRangeMeters)||body.fuel.usableRangeMeters<=0||!Number.isFinite(body.fuel.firstLegMaxMeters)||body.fuel.firstLegMaxMeters<0||body.fuel.firstLegMaxMeters>body.fuel.usableRangeMeters))return {status:'unknown',error:'adventure_invalid_fuel',routes:[],stops:[],windowComplete:false,diagnostics:{strategy:'adventure-preview-v1'}};
 const {resolveGraphRequest}=require('../../regional/select');
 const resolution=resolveGraphRequest(body);
 const enabled=environment.DIRT_ADVENTURE_CANARY==='ns-nb-v1'?['ns','nb']:['ns'];
 if(!resolution.ok||!resolution.regionIds.length||resolution.regionIds.length>enabled.length||resolution.regionIds.some(id=>!enabled.includes(id)))return null;
 const started=Date.now(),window=Number(body.fuel?.windowTimeBudgetMs||20000);
 const deadlineAtMs=started+Math.min(20000,Math.max(100,window));
 const data=load?await load(resolution):await (async()=>{
  const {loadGraphsForRequest}=require('../graph'),{loadRegionFuel}=require('../fuel-data');
  const rows=[];
  for(const regionId of resolution.regionIds) {
   const single=resolveGraphRequest({regionId});
   const [runtime,fuel]=await Promise.all([loadGraphsForRequest(single,{locations:body.locations,profile:body.profile}),loadRegionFuel(regionId)]);
   rows.push({...runtime,stations:fuel.stations,identity:runtime.packIdentity.map(p=>({...p,...fuel.packIdentity}))});
  }
  if(rows.length===1)return rows[0];
  if(rows.some(r=>r.identity.some(p=>p.releaseId!=='fabric-v4-20260908-02')))return {pack:{graphBinaryVersion:0}};
  const key=JSON.stringify(rows.flatMap(r=>r.identity));
  if(!joinedCache||joinedCache.key!==key||rows.some((r,i)=>joinedCache.inputs[i]!==r.pack)) {
   joinedCache=null;
   const joined=joinV4(rows,{budget:createBudget({deadlineAtMs,maxExpansions:20000000})});
   const stationMap=new Map();for(const row of rows)for(const station of row.stations){const prior=stationMap.get(station.id);if(prior&&(prior.lat!==station.lat||prior.lon!==station.lon))throw Error('Conflicting canonical station coordinates');stationMap.set(station.id,station);}
   joinedCache={key,inputs:rows.map(r=>r.pack),data:{pack:joined.pack,geom:joined.geom,stations:[...stationMap.values()],identity:rows.flatMap(r=>r.identity)}};
  }
  return joinedCache.data;
 })();
 if(data.pack.graphBinaryVersion!==4)return {status:'unknown',error:'adventure_pack_unqualified',routes:[],stops:[],windowComplete:false,diagnostics:{strategy:'adventure-preview-v1'}};
 const identity=data.identity||data.packIdentity||[],revision=identity.map(p=>`${p.graphSha256}/${p.geometrySha256}`).join('|');
 if(!identity.length||!revision||identity.some(p=>p.releaseId!=='fabric-v4-20260908-02'))return {status:'unknown',error:'adventure_pack_unqualified',routes:[],stops:[],windowComplete:false,diagnostics:{strategy:'adventure-preview-v1'}};
 const excluded=new Set(body.fuel?.excludedStationIds||[]),profile=body.profile==='cleanest'?'clean':body.profile;
 const input={mode:'from_here',anchors:body.locations.map((p,i)=>({id:`rider-${i}`,lat:p.lat,lon:p.lon})),legs:[{from:'rider-0',to:'rider-1',profile,allowUnknown:profile!=='clean'&&body.accessPolicy?.motorizedUnknown===true}],
  fuel:kind==='fuel'?{fullRangeMeters:body.fuel.usableRangeMeters,reserveFraction:0,initialUsableMeters:body.fuel.firstLegMaxMeters}:null};
 const signal=body.options?.abortSignal;
 const {waypointRadiusMeters}=require('./waypoint-radius');
 const endpointRadiusMeters=waypointRadiusMeters({zoom:body.options?.mapZoom,lat:body.locations[0].lat,requestedMeters:body.options?.matchLimitMeters,graphBinaryVersion:4});
 const pool=buildRideAlternatives({arrivalHistory:{priorEdgeIds:body.options?.priorEdgeIds||[],arrivalEdgeId:body.options?.arrivalEdgeId},pavedFuelHeuristicWeight:3,dirtContinuityMeters:1000,preferOnwardFuel:true,additionalUrbanAreas:resolution.regionIds.includes('nb')?require('./nb-urban-review-20260908-01.json').cores:[],avoidMotorways:body.options?.avoidMotorways===true,input,pack:data.pack,geom:data.geom,revision,stations:data.stations.filter(s=>!excluded.has(s.id)),context,endpointRadiusMeters,expandedCandidates:resolution.regionIds.includes('nb')||!!body.options?.priorEdgeIds?.length,maxFuelLabels:400000,fuelHeuristicWeight:resolution.regionIds.length>1?2:1.5,
  budget:createBudget({deadlineAtMs,maxExpansions:30000000,signal}),preparationBudget:createBudget({deadlineAtMs,maxExpansions:20000000,signal})});
 const response=toLiveResponse(pool,body,kind,identity);
 if(response){response.debug={...(response.debug||{}),adventureTotalMs:Date.now()-started};response.legId=body.legId;}
 return response;
}
module.exports={adventureCanaryRequest,canarySupported,toLiveResponse,routeResponse};
