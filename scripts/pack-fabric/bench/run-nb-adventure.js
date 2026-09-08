"use strict";
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {decodeGraphV4}=require('../routing/lib/pack-v4'),{decodeGeometryV1}=require('../routing/lib/pack-v2');
const {buildRideAlternatives,createRideAlternativeContext}=require('../routing/lib/adventure/ride-alternatives');
const {createBudget}=require('../routing/lib/adventure/budget');
const root=process.env.REBUILD_PACK_ROOT;if(!root)throw Error('REBUILD_PACK_ROOT required');
const output=process.env.REBUILD_NB_OUTPUT||'scripts/pack-fabric/routing/candidates/rebuild-nb-adventure';fs.mkdirSync(output,{recursive:true});
const bytes=fs.readFileSync(path.join(root,'nb/graph.v4.bin')),geometry=fs.readFileSync(path.join(root,'nb/geometry.v1.bin')),fuel=fs.readFileSync(path.join(root,'nb/fuel.v1.json'));
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const identity={regionId:'nb',graphSha256:sha(bytes),geometrySha256:sha(geometry),fuelSha256:sha(fuel)};
const pack=decodeGraphV4(bytes,geometry),geom=decodeGeometryV1(geometry),stations=JSON.parse(fuel).stations,context=createRideAlternativeContext();
const start={lat:46.646799,lon:-64.87533},end={lat:47.762610,lon:-65.856301},summary=[];
for(const usable of [333000,162000])for(const allowUnknown of [false,true])for(const reverse of [false,true])for(const profile of ['dirt','balanced','clean']) {
 const anchors=[{id:'a',...(reverse?end:start)},{id:'b',...(reverse?start:end)}];
 const input={mode:'from_here',anchors,legs:[{from:'a',to:'b',profile,allowUnknown:profile==='clean'?false:allowUnknown}],fuel:{fullRangeMeters:usable/.9,reserveFraction:.1,initialUsableMeters:usable}};
 const deadlineAtMs=Date.now()+20000,at=performance.now();
 const result=buildRideAlternatives({input,pack,geom,stations,expandedCandidates:true,revision:JSON.stringify(identity),context,budget:createBudget({deadlineAtMs,maxExpansions:30000000}),preparationBudget:createBudget({deadlineAtMs,maxExpansions:20000000})});
 const selected=result.selected,id=`${usable}-${allowUnknown?'unknown':'known'}-${reverse?'reverse':'forward'}-${profile}`;
 fs.writeFileSync(path.join(output,id+'.json'),JSON.stringify({identity,input,result}));
 const row={id,usable,allowUnknown,reverse,profile,ms:Math.round(performance.now()-at),state:result.state,fuel:selected?.fuel.state,km:selected?.road.surface?.distanceMeters/1000,dirtPercent:selected?.road.surface?.knownDirtPercent,stops:selected?.fuel.plannedRefills?.length,search:result.search};summary.push(row);console.log(JSON.stringify(row));
 assert.equal(result.state,'complete');assert.equal(selected.fuel.state,'provisional_station_access');assert.equal(result.search.poolComplete,true);
 let previous=0;for(const stop of selected.fuel.plannedRefills){assert.ok(stop.atMeters>=previous);assert.ok(stop.atMeters-previous<=usable+1e-6);previous=stop.atMeters;}
 const remaining=usable-(selected.road.distanceMeters-previous);assert.ok(remaining>=-1e-6);assert.ok(selected.fuel.destinationEscape.distanceMeters<=remaining+1e-6);

}
for(const usable of [333000,162000])for(const allowUnknown of [false,true])for(const reverse of [false,true]) {const rows=summary.filter(r=>r.usable===usable&&r.allowUnknown===allowUnknown&&r.reverse===reverse);assert.ok(rows[0].dirtPercent>=rows[1].dirtPercent);assert.ok(rows[1].dirtPercent>=rows[2].dirtPercent);}
fs.writeFileSync(path.join(output,'summary.json'),JSON.stringify({identity,summary},null,2));
