'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {decodeGraphV4}=require('../routing/lib/pack-v4'),{decodeGeometryV1}=require('../routing/lib/pack-v2');
const {adventureCanaryRequest}=require('../routing/lib/adventure/live-canary');
const samples=JSON.parse(fs.readFileSync(process.env.REBUILD_GAPS||path.join(__dirname,'waypoint-area-fixtures.json')));
const output=process.env.REBUILD_AREA_OUTPUT||'/tmp/dirt-waypoint-area';fs.mkdirSync(output,{recursive:true});
const data={};
function load(r){const id=r.regionIds[0];if(r.regionIds.length!==1)throw Error('Single-region fixture required');if(!data[id]){const dir=path.join(process.env.REBUILD_PACK_ROOT,id),gb=fs.readFileSync(path.join(dir,'geometry.v1.bin'));data[id]={pack:decodeGraphV4(fs.readFileSync(path.join(dir,'graph.v4.bin')),gb),geom:decodeGeometryV1(gb),stations:JSON.parse(fs.readFileSync(path.join(dir,'fuel.v1.json'))).stations,identity:[{regionId:id,releaseId:'fabric-v4-20260908-02',graphSha256:'area-fixture-02'}]};}return data[id];}
const selected=[];for(const region of ['ns','nb']){const rows=samples.filter(s=>s.region===region);for(const i of [...new Set([0,Math.floor(rows.length/2),rows.length-1])])if(rows[i])selected.push(rows[i]);}
(async()=>{const summary=[];for(const [i,s] of selected.entries())for(const profile of ['dirt','balanced','cleanest']){
 const start=s.region==='ns'?{lat:44.764835,lon:-63.340265}:{lat:46.214882,lon:-64.269805};
 const request={profile,locations:[start,{lat:s.lat,lon:s.lon}],options:{mapZoom:7},accessPolicy:{motorizedPermissive:true,motorizedUnknown:false},fuel:{usableRangeMeters:225000,firstLegMaxMeters:225000,windowMaxStops:12,allowPartialWindow:true,windowTimeBudgetMs:20000,routeFirstPlan:true,ensureDestinationFuelEscape:true}};
 const at=Date.now();let response;
 if(process.env.REBUILD_DEPLOYMENT){const file=path.resolve(output,`${i}-${profile}-request.json`);fs.writeFileSync(file,JSON.stringify(request));const run=require('node:child_process').spawnSync('vercel',['curl','/api/fuel-chain','--deployment',process.env.REBUILD_DEPLOYMENT,'--','--silent','--show-error','--max-time','30','--request','POST','--header','Content-Type: application/json','--data-binary','@'+file],{encoding:'utf8',timeout:45000,maxBuffer:30*1024*1024});assert.equal(run.status,0,run.stderr);response=JSON.parse(run.stdout);}else response=await adventureCanaryRequest(request,'fuel',{environment:{DIRT_ADVENTURE_CANARY:'ns-nb-v1'},load});
 fs.writeFileSync(path.join(output,`${i}-${profile}.json`),JSON.stringify({request,response}));
 const row={case:i,region:s.region,point:[s.lat,s.lon],profile,status:response.status,elapsedMs:Date.now()-at,snap:response.diagnostics?.adventure?.waypointSnap,error:response.error};summary.push(row);console.log(JSON.stringify(row));
 assert.equal(response.status,'complete');assert.equal(response.windowComplete,true);assert.equal(response.diagnostics.adventure.search.poolComplete,true);
 assert.ok(row.snap.endDistanceMeters>2000);assert.ok(row.snap.endDistanceMeters<=20000);assert.ok(row.snap.attempts>1);
 for(let j=0;j<response.routes.length;j++){assert.ok(response.routes[j].distanceMeters<=225000+1e-5);if(j)assert.deepEqual(response.routes[j].geometry[0],response.routes[j-1].geometry.at(-1));}
 assert.ok(response.routes.at(-1).distanceMeters+response.destinationEscapeMeters<=225000+1e-5);
 }fs.writeFileSync(path.join(output,'summary.json'),JSON.stringify(summary,null,2));})().catch(e=>{console.error(e);process.exitCode=1;});
