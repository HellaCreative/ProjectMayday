'use strict';
// Replay an exact recorded request, retaining arrival history and remaining fuel.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {spawnSync}=require('node:child_process');
const {auditRideShape}=require('../routing/lib/adventure/ride-shape-audit');
const {createBudget}=require('../routing/lib/adventure/budget');
const {summarizeSurface}=require('../routing/lib/adventure/surface');
const {haversineMeters}=require('../routing/lib/legal-topology/find-path-v4');
const deployment=process.env.REBUILD_DEPLOYMENT,source=process.env.REBUILD_EXPECT_SOURCE;
assert.ok(deployment&&source&&process.env.REBUILD_SAVED_REQUEST,'Deployment, exact source and saved request required');
const request=JSON.parse(fs.readFileSync(process.env.REBUILD_SAVED_REQUEST));
if(process.env.REBUILD_PROFILE)request.profile=process.env.REBUILD_PROFILE;
assert.ok(['dirt','balanced','cleanest'].includes(request.profile));
const output=process.env.REBUILD_SAVED_OUTPUT||'/tmp/dirt-saved-fuel';fs.mkdirSync(output,{recursive:true});
const requestFile=path.resolve(output,'request.json');fs.writeFileSync(requestFile,JSON.stringify(request));
const run=spawnSync('vercel',['curl','/api/fuel-chain','--deployment',deployment,'--','--silent','--show-error','--max-time','30','--request','POST','--header','Content-Type: application/json','--data-binary','@'+requestFile],{encoding:'utf8',timeout:45000,maxBuffer:30*1024*1024});
fs.writeFileSync(path.join(output,'response.json'),run.stdout||'');assert.equal(run.status,0,run.stderr);
const r=JSON.parse(run.stdout);assert.equal(r.serviceBuild,source);assert.equal(r.status,'complete',r.message);
assert.equal(r.diagnostics.strategy,'adventure-preview-v1');assert.equal(r.windowComplete,true);
assert.equal(r.diagnostics.adventure.search.poolComplete,true);
assert.ok(r.packIdentity.length&&r.packIdentity.every(p=>p.releaseId==='fabric-v4-20260908-02'));
assert.equal(r.routes.length,r.stops.length+1);
if(process.env.REBUILD_EXPECT_START_RECOVERY==='1'){
 const snap=r.diagnostics.adventure.waypointSnap;
 assert.equal(snap.startComponentRecovery,true);assert.ok(snap.radiusMeters<=snap.maximumMeters);
 const moved=haversineMeters([request.locations[0].lon,request.locations[0].lat],r.routes[0].geometry[0]);
 assert.ok(moved<=snap.maximumMeters+1e-6);assert.ok(Math.abs(moved-snap.startDistanceMeters)<.1);
}
for(let i=0;i<r.routes.length;i++){
 assert.ok(r.routes[i].distanceMeters<=(i?request.fuel.usableRangeMeters:request.fuel.firstLegMaxMeters)+1e-6);
 if(i)assert.deepEqual(r.routes[i].geometry[0],r.routes[i-1].geometry.at(-1));
}
assert.ok(r.routes.at(-1).distanceMeters+r.destinationEscapeMeters<=(r.stops.length?request.fuel.usableRangeMeters:request.fuel.firstLegMaxMeters)+1e-6);
assert.ok(r.diagnostics.adventure.candidates.every(c=>c.fuel==='provisional_station_access'));
if(process.env.REBUILD_EXPECT_RETRY==='1')assert.ok(r.diagnostics.adventure.candidates.some(c=>c.searchRetry?.state==='provisional_station_access'));
const segments=r.routes.flatMap(x=>x.segments),quality=auditRideShape({segments,budget:createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:1000000})});
assert.equal(quality.state,'complete');
if(process.env.REBUILD_REPEAT_CEILING)assert.ok(quality.repeatedRoadMeters<=Number(process.env.REBUILD_REPEAT_CEILING)+1e-6);
const summary={source:r.serviceBuild,profile:request.profile,ms:r.debug.adventureTotalMs,surface:summarizeSurface(segments),repeatedRoadMeters:quality.repeatedRoadMeters,retries:r.diagnostics.adventure.candidates.filter(c=>c.searchRetry).map(c=>({id:c.id,...c.searchRetry}))};
fs.writeFileSync(path.join(output,'summary.json'),JSON.stringify(summary,null,2));console.log(JSON.stringify(summary));
