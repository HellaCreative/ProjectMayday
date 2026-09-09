'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {decodeGraphV4}=require('../routing/lib/pack-v4'),{decodeGeometryV1}=require('../routing/lib/pack-v2');
const {joinV4}=require('../routing/lib/adventure/join-v4'),{createBudget}=require('../routing/lib/adventure/budget');
const {adventureCanaryRequest}=require('../routing/lib/adventure/live-canary');
const root=process.env.REBUILD_PACK_ROOT,output=process.env.REBUILD_MULTI_OUTPUT||'/tmp/dirt-multi-arrival';fs.mkdirSync(output,{recursive:true});
const data={};for(const id of (process.env.REBUILD_DEPLOYMENT?[]:['ns','nb'])){const bytes=fs.readFileSync(path.join(root,id,'graph.v4.bin')),geometry=fs.readFileSync(path.join(root,id,'geometry.v1.bin'));data[id]={pack:decodeGraphV4(bytes,geometry),geom:decodeGeometryV1(geometry),stations:JSON.parse(fs.readFileSync(path.join(root,id,'fuel.v1.json'))).stations,identity:[{regionId:id,releaseId:'fabric-v4-20260908-02',graphSha256:require('crypto').createHash('sha256').update(bytes).digest('hex')}]};}
let combined;
function load(resolution){if(resolution.regionIds.length===1)return data[resolution.regionIds[0]];
 if(!combined){const rows=['ns','nb'].map(id=>data[id]);const joined=joinV4(rows,{budget:createBudget({deadlineAtMs:Date.now()+20000,maxExpansions:20000000})});combined={...joined,stations:[...new Map(rows.flatMap(r=>r.stations).map(s=>[s.id,s])).values()],identity:rows.flatMap(r=>r.identity)};}return combined;}
const cases={neardalhousie:[[44.764810,-63.340233],[47.914772,-65.948078]],coarsepins:[[44.804135,-63.097441],[43.566279,-65.491539],[44.660761,-65.520139],[46.851988,-65.123190]],inverness:[[44.738289,-63.315088],[45.929257,-59.953773],[46.478234,-61.082533],[48.065038,-66.428275]],yarmouth:[[45.251114,-61.187782],[43.839237,-66.119184],[44.360924,-64.459705],[47.625592,-65.517018]]};
(async()=>{for(const [name,pts] of Object.entries(cases)){
 if(process.env.REBUILD_MULTI_CASE&&process.env.REBUILD_MULTI_CASE!==name)continue;
 if(['coarsepins','neardalhousie'].includes(name)&&!process.env.REBUILD_MULTI_CASE)continue;
 const usable=Number(process.env.REBUILD_MULTI_USABLE||225000),profiles=(process.env.REBUILD_MULTI_PROFILES||'balanced,balanced,balanced').split(',');let remaining=usable,history=[];const results=[];
 assert.ok(profiles.every(p=>['dirt','balanced','cleanest'].includes(p)),'Use API profiles dirt, balanced, or cleanest');
 for(let i=0;i<pts.length-1;i++){
  const request={profile:profiles[i]||'balanced',locations:pts.slice(i,i+2).map(([lat,lon])=>({lat,lon})),accessPolicy:{motorizedPermissive:true,motorizedUnknown:process.env.REBUILD_MULTI_UNKNOWN==='1'},options:{mapZoom:Number(process.env.REBUILD_MULTI_ZOOM||9.6),...(history.length?{arrivalEdgeId:history.at(-1).id,priorEdgeIds:history.map(s=>s.id),backtrackFactor:4}:{})},fuel:{usableRangeMeters:usable,firstLegMaxMeters:remaining,minimumFuelStops:0,windowMaxStops:12,allowPartialWindow:true,windowTimeBudgetMs:20000,routeFirstPlan:true,ensureDestinationFuelEscape:i===pts.length-2,forwardFeeler:false}};
  const at=Date.now();let r;
  if(process.env.REBUILD_DEPLOYMENT){
    const requestFile=path.resolve(output,`${name}-${i}-request.json`);fs.writeFileSync(requestFile,JSON.stringify(request));
    const run=require('node:child_process').spawnSync('vercel',['curl','/api/fuel-chain','--deployment',process.env.REBUILD_DEPLOYMENT,'--','--silent','--show-error','--max-time','30','--request','POST','--header','Content-Type: application/json','--data-binary','@'+requestFile],{encoding:'utf8',timeout:45000,maxBuffer:30*1024*1024});
    assert.equal(run.status,0,run.stderr);r=JSON.parse(run.stdout);
  }else r=await adventureCanaryRequest(request,'fuel',{environment:{DIRT_ADVENTURE_CANARY:'ns-nb-v1'},load});
  fs.writeFileSync(path.join(output,`${name}-${i}.json`),JSON.stringify({request,response:r}));
  console.log(JSON.stringify({name,leg:i+1,ms:Date.now()-at,status:r?.status,strategy:r?.diagnostics?.strategy,reason:r?.error,km:r?.routes?.reduce((n,s)=>n+s.distanceMeters,0)/1000,candidates:r?.diagnostics?.adventure?.candidates}));
  assert.equal(r?.status,'complete');
  if(process.env.REBUILD_MULTI_REPEAT_CEILING)assert.ok(r.diagnostics.adventure.quality.repeatedRoadMeters<=Number(process.env.REBUILD_MULTI_REPEAT_CEILING)+1e-5,'repeat distance exceeds qualified comparison');
  if(process.env.REBUILD_MULTI_FIRST_REPEAT_FREE==='1'&&i===0)assert.equal(r.diagnostics.adventure.quality.repeatedRoadMeters,0,'first primary leg must not retain the reproduced fuel repeats');assert.equal(r.diagnostics.strategy,'adventure-preview-v1');assert.equal(r.windowComplete,true);assert.equal(r.diagnostics.adventure.search.poolComplete,true);
  if(name==='inverness'&&i===2&&profiles.every(p=>p==='balanced'))assert.equal(r.diagnostics.adventure.quality.repeatedRoadMeters,0,'Inverness continuation must not retain the reproduced fuel circuit');
  for(let j=0;j<r.routes.length;j++){const route=r.routes[j];assert.ok(route.distanceMeters<=(j?usable:remaining)+1e-5);if(j)assert.deepEqual(route.geometry[0],r.routes[j-1].geometry.at(-1));for(const s of route.segments){history=history.filter(h=>h.id!==s.edgeId);history.push({id:s.edgeId,meters:Math.max(1,s.distanceMeters)});while(history.length>1&&(history.length>256||history.reduce((n,h)=>n+h.meters,0)>30000))history.shift();}}
  remaining=r.stops.length?usable-r.routes.at(-1).distanceMeters:remaining-r.routes.reduce((n,s)=>n+s.distanceMeters,0);
  assert.ok(remaining>=r.destinationEscapeMeters-1e-5);
  // The rider deliberately chose the mapped pump as waypoint 3 in Yarmouth.
  if(name==='yarmouth'&&i===1)remaining=usable;
  results.push(r);
 }
 fs.writeFileSync(path.join(output,name+'-complete.json'),JSON.stringify(results));
}})().catch(e=>{console.error(e);process.exitCode=1;});
