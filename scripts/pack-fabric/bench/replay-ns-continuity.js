'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {decodeGraphV4}=require('../routing/lib/pack-v4'),{decodeGeometryV1}=require('../routing/lib/pack-v2');
const {buildRideAlternatives,createRideAlternativeContext}=require('../routing/lib/adventure/ride-alternatives');
const {createBudget}=require('../routing/lib/adventure/budget');
const root=process.env.REBUILD_PACK_ROOT;if(!root)throw Error('REBUILD_PACK_ROOT required');
const out=process.env.REBUILD_CONTINUITY_OUTPUT||'/tmp/dirt-continuity';fs.mkdirSync(out,{recursive:true});
const bytes=fs.readFileSync(path.join(root,'ns/graph.v4.bin')),geometry=fs.readFileSync(path.join(root,'ns/geometry.v1.bin'));
const pack=decodeGraphV4(bytes,geometry),geom=decodeGeometryV1(geometry),stations=JSON.parse(fs.readFileSync(path.join(root,'ns/fuel.v1.json'))).stations;
const fixture=require('./fixtures/ns-short-diversions-20260908.json'),body=fixture.request;
const input={mode:'from_here',anchors:body.locations.map((p,i)=>({id:i?'b':'a',...p})),legs:[{from:'a',to:'b',profile:'dirt',allowUnknown:false}],fuel:{fullRangeMeters:250000,reserveFraction:0.1,initialUsableMeters:225000}};
const summary=[];
for(const meters of (process.env.REBUILD_CONTINUITY_METERS||'0,500,1000').split(',').map(Number)){
 const at=performance.now(),deadlineAtMs=Date.now()+20000;
 const result=buildRideAlternatives({pavedFuelHeuristicWeight:process.env.REBUILD_PAVED_WEIGHT?Number(process.env.REBUILD_PAVED_WEIGHT):undefined,input,pack,geom,stations,revision:'ns02-continuity-bench',context:createRideAlternativeContext(),maxFuelLabels:400000,fuelHeuristicWeight:Number(process.env.REBUILD_CONTINUITY_WEIGHT||1),preferOnwardFuel:true,dirtContinuityMeters:meters,budget:createBudget({deadlineAtMs,maxExpansions:30000000}),preparationBudget:createBudget({deadlineAtMs,maxExpansions:20000000})});
 fs.writeFileSync(path.join(out,`${meters}.json`),JSON.stringify(result));
 const s=result.selected;let atMeters=0;const localDirt=[];
 for(const seg of s?.road.segments||[]){if(atMeters<20000&&!['asphalt','paved','concrete'].includes(seg.surfaceLeaf))localDirt.push({atMeters,edge:seg.edgeId,meters:seg.distanceMeters});atMeters+=seg.distanceMeters;}
 const row={meters,ms:Math.round(performance.now()-at),state:result.state,objective:result.selectedObjective,poolComplete:result.search.poolComplete,fuel:s?.fuel.state,km:s?.road.distanceMeters/1000,dirt:s?.road.surface.knownDirtPercent,repeat:s?.qualityAudit?.repeatedRoadMeters,localDirt,candidates:result.candidates.map(c=>({id:c.id,fuel:c.fuel,reason:c.reason}))};
 if(process.env.REBUILD_QUALIFY==='1') {
  assert.equal(result.search.poolComplete,true);assert.equal(s.fuel.state,'provisional_station_access');
  assert.equal(s.qualityAudit.repeatedRoadMeters,0);assert.equal(localDirt.length,0);assert.ok(s.road.surface.knownDirtPercent>65);
  let previous=0;for(const stop of s.fuel.plannedRefills){assert.ok(stop.atMeters-previous<=225000+1e-6);previous=stop.atMeters;}
  assert.ok(s.road.distanceMeters-previous+s.fuel.destinationEscape.distanceMeters<=225000+1e-6);
 }
 summary.push(row);console.log(JSON.stringify(row));
}
fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify(summary,null,2));
