"use strict";
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
const deployment=process.env.REBUILD_DEPLOYMENT;if(!deployment)throw Error('REBUILD_DEPLOYMENT required');
const output=process.env.REBUILD_LIVE_OUTPUT||'routing/candidates/rebuild-live-preview/smoke';fs.mkdirSync(output,{recursive:true});
const results=[];
for(const profile of ['dirt','balanced','cleanest']){
 const body={profile,locations:[{lat:44.76484,lon:-63.34023,label:'Porters Lake'},{lat:43.47454,lon:-65.60197,label:'Southwest NS'}],vehicle:'dual-sport-motorcycle',accessPolicy:{motorizedPermissive:true,motorizedUnknown:false},options:{mapZoom:12},fuel:{usableRangeMeters:270000,firstLegMaxMeters:270000,requireFuelStopBeforeEnd:false,minimumFuelStops:0,profileMeters:250000,riderLegId:'canary-device-check',windowMaxStops:4,allowPartialWindow:true,windowTimeBudgetMs:20000,routeFirstPlan:true,ensureDestinationFuelEscape:true}};
 const input=path.resolve(output,profile+'-request.json'),response=path.resolve(output,profile+'-response.json');fs.writeFileSync(input,JSON.stringify(body));
 const at=Date.now(),run=spawnSync('vercel',['curl','/api/fuel-chain','--deployment',deployment,'--','--silent','--show-error','--max-time','30','--request','POST','--header','Content-Type: application/json','--data-binary','@'+input],{encoding:'utf8',timeout:60000,maxBuffer:16*1024*1024});
 fs.writeFileSync(response,run.stdout||'');if(run.status!==0)throw Error(`Transport failed ${run.stderr}`);
 const r=JSON.parse(run.stdout);assert.equal(r.status,'complete',JSON.stringify({error:r.error,message:r.message}));assert.equal(r.diagnostics?.strategy,'adventure-preview-v1');assert.equal(r.serviceContract,'dirt-routing.r0.v1');assert.equal(r.windowComplete,true);
 assert.equal(r.routes.length,r.stops.length+1);let dirt=0,total=0;
 for(let i=0;i<r.routes.length;i++){
  const route=r.routes[i];assert.equal(route.status,'complete');assert.equal(route.debug.engine,'adventure-shared-candidates');assert.ok(route.geometry.length>1);assert.ok(route.geometry.every(p=>p.length===2&&p.every(Number.isFinite)));
  assert.ok(route.distanceMeters<=270000+1e-6);assert.equal(route.stats.surfaceFamilyMode,'leaf-v3');
  if(i)assert.deepEqual(route.geometry[0],r.routes[i-1].geometry.at(-1));
  const meters=route.segments.reduce((n,s)=>n+s.distanceMeters,0);assert.ok(Math.abs(meters-route.distanceMeters)<1e-4);
  const {summarizeSurface}=require('../routing/lib/adventure/surface');const s=summarizeSurface(route.segments);dirt+=s.knownDirtMeters;total+=s.distanceMeters;
 }
 assert.ok(270000-r.routes.at(-1).distanceMeters>=r.destinationEscapeMeters-1e-6);
 assert.ok(r.packIdentity.every(p=>p.regionId==='ns'&&p.releaseId==='fabric-v4-20260908-02'));
 results.push({profile,elapsedIncludingCliMs:Date.now()-at,serverMs:r.debug.adventureTotalMs,km:total/1000,dirtPercent:dirt/total*100,stops:r.stops.length,build:r.serviceBuild});
 console.log(JSON.stringify(results.at(-1)));
}
assert.ok(results[0].dirtPercent>=results[1].dirtPercent);assert.ok(results[2].dirtPercent<=results[1].dirtPercent);
fs.writeFileSync(path.resolve(output,'summary.json'),JSON.stringify({deployment,passed:true,results},null,2));
