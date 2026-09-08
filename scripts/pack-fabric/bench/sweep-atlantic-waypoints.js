"use strict";
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {decodeGraphV4}=require('../routing/lib/pack-v4'),{decodeGeometryV1}=require('../routing/lib/pack-v2');
const {buildRideAlternatives,createRideAlternativeContext}=require('../routing/lib/adventure/ride-alternatives');
const {createBudget}=require('../routing/lib/adventure/budget');
const root=process.env.REBUILD_PACK_ROOT;if(!root)throw Error('REBUILD_PACK_ROOT required');
const output=process.env.REBUILD_CROSS_OUTPUT||'scripts/pack-fabric/routing/candidates/rebuild-cross-adventure';fs.mkdirSync(output,{recursive:true});
const {joinV4}=require('../routing/lib/adventure/join-v4');
const regions=['ns','nb'].map(id=>{const bytes=fs.readFileSync(path.join(root,id,'graph.v4.bin')),geometry=fs.readFileSync(path.join(root,id,'geometry.v1.bin'));return {pack:decodeGraphV4(bytes,geometry),geom:decodeGeometryV1(geometry),stations:JSON.parse(fs.readFileSync(path.join(root,id,'fuel.v1.json'))).stations,sha:crypto.createHash('sha256').update(bytes).digest('hex')};});
const at=Date.now(),joined=joinV4(regions,{budget:createBudget({deadlineAtMs:Date.now()+20000,maxExpansions:20000000})});
console.log(JSON.stringify({joinMs:Date.now()-at,join:joined.diagnostics}));
const {pack,geom}=joined,identity=regions.map(r=>({regionId:r.pack.regionId,sha:r.sha})),context=createRideAlternativeContext();
const stationMap=new Map();for(const r of regions)for(const station of r.stations){const prior=stationMap.get(station.id);if(prior&&(prior.lat!==station.lat||prior.lon!==station.lon))throw Error('Conflicting station coordinates');stationMap.set(station.id,station);}
const stations=[...stationMap.values()],start={lat:44.764834,lon:-63.340240},end={lat:47.762610,lon:-65.856301},summary=[];
const source=JSON.parse(fs.readFileSync(process.env.REBUILD_SWEEP_SOURCE)).result.selected.road;
let atMeters=0;const positions=source.segments.map(s=>{const p={at:atMeters,point:s.geometry[0]};atMeters+=s.distanceMeters;return p;});
const targets=[{id:'moved',lat:47.743529,lon:-64.911236},{id:'previous-near-dalhousie',lat:47.914772,lon:-65.948078},{id:'dalhousie',lat:47.986597,lon:-66.328424}];
for(const back of [5000,15000,35000,60000,90000]){const p=positions.reduce((a,b)=>Math.abs(b.at-(source.distanceMeters-back))<Math.abs(a.at-(source.distanceMeters-back))?b:a);targets.push({id:`tail-${back}`,lat:p.point[1],lon:p.point[0]});}
for(const target of targets){
 const input={mode:'from_here',anchors:[{id:'a',lat:44.764810,lon:-63.340233},{...target,id:'b'}],legs:[{from:'a',to:'b',profile:'dirt',allowUnknown:false}],fuel:{fullRangeMeters:225000,reserveFraction:0,initialUsableMeters:225000}};
 const deadlineAtMs=Date.now()+20000,started=performance.now();
 const result=buildRideAlternatives({input,pack,geom,stations,preferOnwardFuel:true,additionalUrbanAreas:require('../routing/lib/adventure/nb-urban-review-20260908-01.json').cores,expandedCandidates:true,maxFuelLabels:200000,fuelHeuristicWeight:2,revision:JSON.stringify(identity),context,budget:createBudget({deadlineAtMs,maxExpansions:30000000}),preparationBudget:createBudget({deadlineAtMs,maxExpansions:20000000})});
 const r=result.selected;assert.equal(result.state,'complete');assert.equal(r.fuel.state,'provisional_station_access');assert.equal(result.search.poolComplete,true);assert.ok(result.candidates.every(c=>c.fuel==='provisional_station_access'));assert.ok(r.qualityAudit.repeatedRoadMeters<=2000);assert.ok(r.road.surface.knownDirtPercent>=60);
 let previous=0;for(const stop of r.fuel.plannedRefills){assert.ok(stop.atMeters-previous<=225000+1e-6);previous=stop.atMeters;}
 assert.ok(r.road.distanceMeters-previous+r.fuel.destinationEscape.distanceMeters<=225000+1e-6);
 const row={target,ms:Math.round(performance.now()-started),km:r.road.distanceMeters/1000,dirt:r.road.surface.knownDirtPercent,repeatKm:r.qualityAudit.repeatedRoadMeters/1000,stops:r.fuel.plannedRefills.length,candidateFailures:result.candidates.filter(c=>c.fuel!=='provisional_station_access')};summary.push(row);console.log(JSON.stringify(row));
 fs.writeFileSync(path.join(output,target.id+'.json'),JSON.stringify({input,result}));
}
fs.writeFileSync(path.join(output,'summary.json'),JSON.stringify(summary,null,2));
