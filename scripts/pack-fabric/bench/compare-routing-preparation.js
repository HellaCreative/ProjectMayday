'use strict';
// Private benchmark of the actual candidate pool, not a hand-written objective.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),zlib=require('node:zlib');
const {decodeGraphV4,decodeGeometryV1}=require('../routing/lib/pack-v4');
const {adventureCanaryRequest}=require('../routing/lib/adventure/live-canary');
const {createRideAlternativeContext}=require('../routing/lib/adventure/ride-alternatives');
const {joinV4}=require('../routing/lib/adventure/join-v4');
const {createBudget}=require('../routing/lib/adventure/budget');
const {resolveGraphRequest}=require('../routing/regional/select');
const {qualifiedPack}=require('../routing/lib/adventure/pack-revision-qualification');
const cases=require('../../../docs/experiments/routing-performance-2026-09-10/matrix-inputs.json');
const [caseId,variant,out,repeatsArg='3']=process.argv.slice(2),fixture=cases.find(c=>c.id===caseId);
if(!fixture||!['baseline','incoming','neutral','combined'].includes(variant)||!out)throw Error('CASE baseline|incoming OUTPUT [REPEATS] required');
fs.mkdirSync(path.dirname(out),{recursive:true});
const root=process.env.PERFORMANCE_PACK_ROOT||'/tmp/dirt-performance-packs',releaseId='fabric-v4-20260909-02';
const environment={DIRT_ADVENTURE_CANARY:'national-v1',DIRT_PASSING_REFILL_ADVISORY:'candidate-v1',DIRT_FUEL_COMPLETION_POLICY:'feasible-v1',DIRT_FUEL_CONNECTIVITY_PROBE:'candidate-v1',DIRT_ZERO_REFILL_ADVISORY:'proved-national-v1'};
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
const context=createRideAlternativeContext({maxReverseBytes:256*1024*1024,useIncomingBounds:['incoming','combined'].includes(variant),fastNeutralTurns:['neutral','combined'].includes(variant)});
const packCache=new Map();let joinedCache=null,loadTrace=[];
function loadRegion(id) {
 const cached=packCache.get(id);if(cached){loadTrace.push({id,cacheHit:true});return cached;}
 const at=performance.now(),folder=path.join(root,id),g=fs.readFileSync(path.join(folder,'graph.v4.bin')),geo=fs.readFileSync(path.join(folder,'geometry.v1.bin')),f=fs.readFileSync(path.join(folder,'fuel.v1.json')),readMs=performance.now()-at;
 const validate=performance.now(),identity={regionId:id,releaseId,graphSha256:hash(g),geometrySha256:hash(geo),fuelSha256:hash(f)};
 if(!qualifiedPack(identity))throw Error('Unqualified immutable pack '+id);
 const validationMs=performance.now()-validate,decode=performance.now(),row={pack:decodeGraphV4(g,geo),geom:decodeGeometryV1(geo),stations:JSON.parse(f).stations,identity:[identity]};
 packCache.set(id,row);loadTrace.push({id,cacheHit:false,readMs,validationMs,decodeMs:performance.now()-decode,readBytes:g.length+geo.length+f.length});return row;
}
async function load(resolution) {
 const rows=resolution.regionIds.map(loadRegion);
 if(rows.length===1)return rows[0];
 const key=JSON.stringify(rows.flatMap(r=>r.identity));
 if(joinedCache?.key===key){loadTrace.push({joinCacheHit:true});return joinedCache.data;}
 joinedCache=null;const at=performance.now();
 const joined=joinV4(rows,{budget:createBudget({deadlineAtMs:Date.now()+90000,maxExpansions:Math.max(20000000,rows.reduce((n,r)=>n+r.pack.nodeCount+r.pack.edgeCount+r.pack.edgeTargets.length,0)+1)})});
 const stations=new Map();for(const row of rows)for(const s of row.stations){const p=stations.get(s.id);if(p&&(p.lat!==s.lat||p.lon!==s.lon))throw Error('Conflicting canonical station');stations.set(s.id,s);}
 const data={pack:joined.pack,geom:joined.geom,stations:[...stations.values()],identity:rows.flatMap(r=>r.identity)};
 joinedCache={key,data};loadTrace.push({joinCacheHit:false,joinMs:performance.now()-at,joinedNodes:joined.pack.nodeCount,joinedEdges:joined.pack.edgeCount});return data;
}
function proof(result){return {status:result?.status,error:result?.error,windowComplete:result?.windowComplete,stops:result?.stops,
 destinationEscapeMeters:result?.destinationEscapeMeters,fuelAccessEvidence:result?.fuelAccessEvidence,
 routes:(result?.routes||(result?.segments?[result]:[])).map(r=>({distanceMeters:r.distanceMeters,segments:r.segments,stats:r.stats}))};}
function validate(result,request) {
 const routes=result?.routes||(result?.segments?[result]:[]);let previous=null;
 for(const [i,r] of routes.entries()) {
  if(request.fuel&&r.distanceMeters>(i===0?request.fuel.firstLegMaxMeters:request.fuel.usableRangeMeters)+1)throw Error('Fuel hop exceeds available range');
  for(const s of r.segments||[]) {
   if(previous) {const a=previous.geometry.at(-1),b=s.geometry[0];if(Math.abs(a[0]-b[0])>1e-7||Math.abs(a[1]-b[1])>1e-7)throw Error('Disconnected returned geometry');}
   if(['motorized_denied','motorized_impassable'].includes(s.accessClass))throw Error('Blocked returned road');
   if(!request.accessPolicy?.motorizedUnknown&&s.accessClass==='motorized_unknown')throw Error('Unknown access bypass');previous=s;
  }
 }
 if(request.fuel&&result?.status==='complete'&&result.windowComplete) {
  const last=routes.at(-1),available=routes.length===1?request.fuel.firstLegMaxMeters:request.fuel.usableRangeMeters;
  if(!Number.isFinite(result.destinationEscapeMeters)||(last?.distanceMeters||0)+result.destinationEscapeMeters>available+1)throw Error('Unproved destination escape range');
 }
 return {continuous:true,access:true,range:true};
}
(async()=>{
 const report={caseId,variant,fixture,environment,scope:'Local full immutable pack loader and actual live-canary candidate pool; single retained joined graph. No hosted speed claim.',node:process.version,runs:[]};
 const checkpoint=()=>{fs.mkdirSync(path.dirname(out),{recursive:true});fs.writeFileSync(out,JSON.stringify(report,null,2));};
 for(let run=0;run<Number(repeatsArg);run++) {
  let request=structuredClone(fixture.request),history=[],excluded=[],windows=[],proofs=[],meters=0,stops=0,complete=false;
  for(let window=0;window<24;window++) {
   loadTrace=[];const at=performance.now(),result=await adventureCanaryRequest(request,request.fuel?'fuel':'route',{environment,load,context}),ms=performance.now()-at;
   const memoryBeforeProof=process.memoryUsage(),checks=result?.status==='complete'?validate(result,request):null,p=proof(result);
   const diag=result?.diagnostics||result?.debug?.diagnostics,regions=resolveGraphRequest(request).regionIds;
   windows.push({window,ms,status:result?.status,error:result?.error,windowComplete:result?.windowComplete,load:loadTrace,
    stages:{dataMs:result?.debug?.adventureDataMs,searchMs:result?.debug?.adventureSearchMs,responseMs:result?.debug?.adventureResponseMs},
    candidates:diag?.adventure?.candidates,selected:diag?.selectedReason,search:diag?.adventure?.search,
    signature:hash(JSON.stringify(p)),meters:p.routes.reduce((n,r)=>n+r.distanceMeters,0),stops:result?.stops?.map(s=>s.id),
    checks,regions,memoryBeforeProof,reverse:context.reverseCostCache.diagnostics()});
   report.active={run,windows};checkpoint();
   if(run===0)proofs.push(p);
   if(result?.status!=='complete')break;
   meters+=p.routes.reduce((n,r)=>n+r.distanceMeters,0);stops+=result.stops?.length||0;
   if(!request.fuel||result.windowComplete){complete=true;break;}
   if(!result.stops?.length)throw Error('Incomplete window has no proved onward pump');
   for(const r of result.routes)for(const s of r.segments||[]) {
    history=history.filter(h=>h.id!==s.edgeId);history.push({id:s.edgeId,meters:Math.max(1,s.distanceMeters)});
    while(history.length>1&&(history.length>256||history.reduce((n,h)=>n+h.meters,0)>30000))history.shift();
   }
   for(const s of result.stops){if(excluded.includes(s.id))throw Error('Repeated excluded pump');excluded.push(s.id);}
   const last=result.stops.at(-1);request.locations[0]={lat:last.lat,lon:last.lon};
   request.options.priorEdgeIds=history.map(h=>h.id);request.options.arrivalEdgeId=history.at(-1).id;
   request.fuel.firstLegMaxMeters=request.fuel.usableRangeMeters;request.fuel.excludedStationIds=excluded;
   const single=resolveGraphRequest(request).regionIds.length===1;request.fuel.windowMaxStops=single?4:1;request.fuel.forwardFeeler=!single;
  }
  const peakRoutingMiB=process.resourceUsage().maxRSS/1024;
  if(run===0)fs.writeFileSync(out+'.proof.json.gz',zlib.gzipSync(JSON.stringify(proofs)));
  proofs.length=0;
  if(global.gc)global.gc();
  delete report.active;
  report.runs.push({run,complete,ms:windows.reduce((n,w)=>n+w.ms,0),meters,stops,windows,peakRoutingMiB,retained:process.memoryUsage()});
  checkpoint();console.log(JSON.stringify({caseId,variant,run,complete,ms:report.runs.at(-1).ms,meters,stops,peakRoutingMiB}));
  // Do not spend repeated full timeouts on a failing case; preserve the first result.
  if(!complete)break;
 }
})().catch(error=>{console.error(error.stack);process.exitCode=1;});
