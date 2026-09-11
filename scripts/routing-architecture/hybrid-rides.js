'use strict';
// Private integration: reuse DIRT's surface comparator and fuel arithmetic over
// complete GraphHopper candidates. This module does not construct road geometry.
const {compareSurface}=require('../pack-fabric/routing/lib/adventure/surface');
const {proveFuel}=require('../pack-fabric/routing/lib/adventure/fuel-proof');
const {createBudget}=require('../pack-fabric/routing/lib/adventure/budget');
const crypto=require('node:crypto');
const STYLES=Object.freeze(['dirt','balanced','clean']);
const OBJECTIVES=Object.freeze(['dirt30','dirt10','paved','distance']);
const fields=new Set(['start','end','profile','fuel','allowUnknown','wander','stations','excludedStationIds','timeoutMillis']);

function normalizeRequest(request){
 if(!request||Array.isArray(request)||typeof request!=='object')throw new TypeError('Request object required');
 for(const key of Object.keys(request))if(!fields.has(key))throw new TypeError(`Unsupported request field: ${key}`);
 if(!STYLES.includes(request.profile))throw new TypeError('Use dirt, balanced or clean');
 for(const name of ['start','end']){
  const p=request[name];
  if(!Array.isArray(p)||p.length!==2||!p.every(Number.isFinite)||Math.abs(p[0])>180||Math.abs(p[1])>90)throw new TypeError(`Invalid ${name}`);
 }
 const timeoutMillis=request.timeoutMillis??90000;
 if(!Number.isSafeInteger(timeoutMillis)||timeoutMillis<1||timeoutMillis>90000)throw new TypeError('timeoutMillis must be 1..90000');
 if(request.allowUnknown!==undefined&&typeof request.allowUnknown!=='boolean')throw new TypeError('allowUnknown must be boolean');
 if(request.wander!==undefined&&(!Number.isFinite(request.wander)||request.wander<0||request.wander>1))throw new TypeError('wander must be 0..1');
 if(request.fuel!==undefined){
  const f=request.fuel;
  if(!f||Object.keys(f).some(k=>!['usableRangeMeters','initialUsableMeters'].includes(k))||!Number.isFinite(f.usableRangeMeters)||f.usableRangeMeters<=0||!Number.isFinite(f.initialUsableMeters)||f.initialUsableMeters<0||f.initialUsableMeters>f.usableRangeMeters)throw new TypeError('Explicit valid usable and initial fuel ranges required');
 }
 if(request.excludedStationIds!==undefined&&(!Array.isArray(request.excludedStationIds)||!request.excludedStationIds.every(x=>typeof x==='string')))throw new TypeError('excludedStationIds must be strings');
 return {...structuredClone(request),timeoutMillis,allowUnknown:request.allowUnknown??false,wander:request.wander??1};
}
function surfaceOf(steps){
 const meters=[0,0,0];let longest=0,run=0,cost=0;
 for(const step of steps){
  if(!Number.isFinite(step.meters)||step.meters<0||![0,1,2].includes(step.surfaceKind)||!Number.isFinite(step.pavedBackroadCost)||step.pavedBackroadCost<0)throw new TypeError('Missing or invalid engine surface/cost evidence');
  meters[step.surfaceKind]+=step.meters;cost+=step.pavedBackroadCost;
  run=step.surfaceKind===1?run+step.meters:0;longest=Math.max(longest,run);
 }
 const distance=meters.reduce((a,b)=>a+b,0),percent=n=>distance?n/distance*100:0;
 return {distanceMeters:distance,knownDirtMeters:meters[1],pavedMeters:meters[0],unknownSurfaceMeters:meters[2],knownDirtPercent:percent(meters[1]),pavedPercent:percent(meters[0]),unknownSurfacePercent:percent(meters[2]),longestDirtRunMeters:longest,pavedBackroadCost:cost};
}
function evaluateCandidate(id,envelope,request,{deadlineAtMs=Date.now()+5000}={}){
 const hasFuel=request.fuel!==undefined;
 const certified=hasFuel&&envelope.state==='fuel_verified'&&envelope.fuel?.state==='found';
 const route=certified?envelope.fuel:envelope.road;
 if(!route||!(certified||envelope.state==='road_only'||route.state==='found'))return null;
 const rawSteps=route.steps??route.edges;
 if(!Array.isArray(rawSteps)||!rawSteps.length)return null;
 const roads=rawSteps.filter(s=>!s.refill),surface=surfaceOf(roads);
 if(Math.abs(surface.distanceMeters-route.distance)>0.01)throw new Error('Engine route distance mismatch');
 let proof={state:hasFuel?'unverified':'not_requested',reason:hasFuel?'engine_fuel_unresolved':undefined};
 if(certified){
  let at=0;const visits=[];
  for(const step of rawSteps){
   if(step.refill){
    if(step.meters!==0||step.from!==step.to||(request.excludedStationIds??[]).includes(step.refill))throw new Error('Invalid refill evidence');
    visits.push({id:`${id}:${visits.length}`,stationId:step.refill,refuel:true,atMeters:at,accessEvidence:'legal_road_projection'});
   }else at+=step.meters;
  }
  if(!Array.isArray(route.escape)||!route.escapeStation||(request.excludedStationIds??[]).includes(route.escapeStation))throw new Error('Missing or excluded destination escape');
  const escapeDistance=route.escape.reduce((n,s)=>{if(!Number.isFinite(s.meters)||s.meters<0||s.refill)throw new Error('Invalid escape');return n+s.meters;},0);
  proof=proveFuel({...request.fuel,segments:roads.map(s=>({distanceMeters:s.meters})),visits,allowProvisionalStations:true,
   destinationEscape:{state:'provisional_station_access',accessEvidence:'legal_road_projection',stationId:route.escapeStation,distanceMeters:escapeDistance},
   budget:createBudget({deadlineAtMs,maxExpansions:1000000})});
  if(proof.state!=='provisional_station_access'||Math.abs(proof.departureUsableMeters-route.remainingUsableMeters)>0.01)throw new Error('DIRT fuel arithmetic disagrees with engine certificate');
 }
 const proofId=crypto.createHash('sha256').update(JSON.stringify({steps:rawSteps,escape:route.escape,escapeStation:route.escapeStation})).digest('hex');
 return {id,proofId,surface,fuel:proof,route,eligible:!hasFuel||proof.state==='provisional_station_access'};
}
function chooseRides(candidates){
 const feasible=candidates.filter(c=>c.eligible),pool=feasible.length?feasible:candidates,choices={};
 for(const style of STYLES){
  const ranked=pool.slice().sort((a,b)=>compareSurface(style,a.surface,b.surface)||
   (style==='clean'?a.surface.pavedBackroadCost/Math.max(1,a.surface.distanceMeters)-b.surface.pavedBackroadCost/Math.max(1,b.surface.distanceMeters):0)||
   a.surface.distanceMeters-b.surface.distanceMeters||a.id.localeCompare(b.id));
  choices[style]=ranked[0]?.id??null;
 }
 return choices;
}
function stable(value){
 if(Array.isArray(value))return value.map(stable);
 if(value&&typeof value==='object')return Object.fromEntries(Object.keys(value).sort().map(k=>[k,stable(value[k])]));
 return value;
}
function poolKey(request,identity){const {profile,...constraints}=request;return JSON.stringify(stable({identity,constraints}));}

class HybridRides {
 constructor({runCandidate,identity,strictCostMask=false,maxCacheBytes=16*1024*1024}){
  if(!identity||typeof runCandidate!=='function')throw new TypeError('Engine identity and runner required');
  this.runCandidate=runCandidate;this.identity=identity;this.strictCostMask=strictCostMask;this.maxCacheBytes=maxCacheBytes;this.cache=null;this.busy=false;
 }
 async route(input,{signal}={}){
  const q=normalizeRequest(input),started=performance.now();
  if(signal?.aborted)throw new Error('cancelled');
  const key=poolKey(q,this.identity);
  if(this.cache?.key===key){const result=JSON.parse(this.cache.json);return this.finish(result,q,started,true);}
  if(this.busy)throw new Error('bounded_selection_busy');
  this.busy=true;
  try{
   const candidates=[],attempts=[],objectives=this.strictCostMask?['dirt30']:OBJECTIVES;
   let incompleteReason=null;
   for(const objective of objectives){
    if(signal?.aborted)throw new Error('cancelled');
    const remaining=Math.floor(q.timeoutMillis-(performance.now()-started));
    if(remaining<=0){incompleteReason='shared_request_deadline';break;}
    const {profile,...constraints}=q;
    let envelope;
    try{envelope=await this.runCandidate({...constraints,profile:objective,timeoutMillis:remaining},{signal});}
    catch(error){if(signal?.aborted)throw new Error('cancelled');attempts.push({objective,error:String(error)});incompleteReason='candidate_error';continue;}
    if(signal?.aborted)throw new Error('cancelled');
    try{
     const candidate=evaluateCandidate(objective,envelope,q,{deadlineAtMs:Date.now()+Math.max(0,q.timeoutMillis-(performance.now()-started))});
     attempts.push({objective,state:envelope.state,fuel:envelope.fuel?.state,error:envelope.error,seconds:envelope.fuel?.seconds??envelope.road?.seconds,resources:envelope.resources});
     if(candidate)candidates.push(candidate);else incompleteReason='candidate_incomplete';
     if(candidate&&!candidate.eligible)incompleteReason='candidate_fuel_unresolved';
     if(envelope.road?.alternativesComplete===false||envelope.road?.errors?.length)incompleteReason='candidate_search_incomplete';
    }catch(error){attempts.push({objective,error:String(error)});incompleteReason='candidate_evidence_rejected';}
   }
   if(performance.now()-started>=q.timeoutMillis)incompleteReason='shared_request_deadline';
   const choices=chooseRides(candidates);
   const result={engine:'dirt-graphhopper-shared-rides-v1',sourceIdentity:this.identity,navigationReady:false,productProfileParity:false,
    scope:this.strictCostMask?'fixed_500x_cost_and_mask_shared_by_all_styles':'shared_additive_candidate_pool',
    poolComplete:attempts.length===objectives.length&&!incompleteReason,incompleteReason,choices,candidates,attempts,
    constraints:{...q,profile:undefined},generationSeconds:(performance.now()-started)/1000,
    limitations:['best of generated candidates, not global optimum','physical station access remains provisional','urban necessity and full riding coherence not qualified']};
   // Cache one complete pool, independent of requested riding style. Serialized
   // bytes are bounded; this does not cap topology, graph memory or total RSS.
   if(result.poolComplete&&this.maxCacheBytes>0){const json=JSON.stringify(result);this.cache=Buffer.byteLength(json)<=this.maxCacheBytes?{key,json}:null;}
   return this.finish(result,q,started,false);
  }finally{this.busy=false;}
 }
 finish(result,q,started,cacheHit){
  const selected=result.candidates.find(c=>c.id===result.choices[q.profile]);
  return {...result,profile:q.profile,selectedCandidateId:selected?.id??null,state:selected?(q.fuel?(selected.eligible?'fuel_provisional':'fuel_unresolved'):'road_only'):'incomplete',
   cacheHit,selectionSeconds:(performance.now()-started)/1000};
 }
}
module.exports={HybridRides,evaluateCandidate,chooseRides,normalizeRequest,surfaceOf,poolKey};
