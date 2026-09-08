"use strict";
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
const deployment=process.env.REBUILD_DEPLOYMENT;if(!deployment)throw Error('REBUILD_DEPLOYMENT required');
const output=process.env.REBUILD_LIVE_OUTPUT||'routing/candidates/rebuild-atlantic-live';fs.mkdirSync(output,{recursive:true});
const start={lat:44.764834,lon:-63.340240},end={lat:47.762610,lon:-65.856301},summary=[];
for(const reverse of [false,true])for(const profile of ['dirt','balanced','cleanest']) {
 const id=`${reverse?'reverse':'forward'}-${profile}`,body={profile,locations:reverse?[end,start]:[start,end],accessPolicy:{motorizedPermissive:true,motorizedUnknown:false},options:{mapZoom:10.3},fuel:{usableRangeMeters:225000,firstLegMaxMeters:225000,minimumFuelStops:0,windowMaxStops:12,allowPartialWindow:true,windowTimeBudgetMs:20000,routeFirstPlan:true,ensureDestinationFuelEscape:true,forwardFeeler:false}};
 const request=path.resolve(output,id+'-request.json');fs.writeFileSync(request,JSON.stringify(body));
 const at=Date.now(),run=spawnSync('vercel',['curl','/api/fuel-chain','--deployment',deployment,'--','--silent','--show-error','--max-time','25','--request','POST','--header','Content-Type: application/json','--data-binary','@'+request],{encoding:'utf8',timeout:45000,maxBuffer:24*1024*1024});
 fs.writeFileSync(path.join(output,id+'-response.json'),run.stdout||'');assert.equal(run.status,0,run.stderr);
 const r=JSON.parse(run.stdout);assert.equal(r.status,'complete',r.message);assert.equal(r.diagnostics.strategy,'adventure-preview-v1');assert.equal(r.windowComplete,true);assert.equal(r.routes.length,r.stops.length+1);assert.deepEqual([...r.regionIds].sort(),['nb','ns']);assert.ok(r.packIdentity.every(p=>p.releaseId==='fabric-v4-20260908-02'));
 let total=0;for(let i=0;i<r.routes.length;i++){const route=r.routes[i];assert.equal(route.debug.engine,'adventure-shared-candidates');assert.ok(route.distanceMeters<=225000+1e-6);assert.ok(route.geometry.length>1);if(i)assert.deepEqual(route.geometry[0],r.routes[i-1].geometry.at(-1));total+=route.distanceMeters;}
 assert.ok(r.destinationEscapeMeters<=225000-r.routes.at(-1).distanceMeters+1e-6);
 // Calculate from the same public surface taxonomy, without rounded hop percentages.
 const {summarizeSurface}=require('../routing/lib/adventure/surface');const surface=summarizeSurface(r.routes.flatMap(r=>r.segments));
 const row={id,httpIncludingCliMs:Date.now()-at,serverMs:r.debug.adventureTotalMs,km:total/1000,dirtPercent:surface.knownDirtPercent,stops:r.stops.length,build:r.serviceBuild};summary.push(row);console.log(JSON.stringify(row));
}
fs.writeFileSync(path.join(output,'summary.json'),JSON.stringify({deployment,summary},null,2));
