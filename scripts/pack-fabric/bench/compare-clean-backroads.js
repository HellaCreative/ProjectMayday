'use strict';
// Diagnostic comparison only. No live defaults are changed by this benchmark.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {decodeGraphV4}=require('../routing/lib/pack-v4'),{decodeGeometryV1}=require('../routing/lib/pack-v2');
const {joinV4}=require('../routing/lib/adventure/join-v4');
const {buildFromHere}=require('../routing/lib/adventure/from-here');
const {createRideAlternativeContext}=require('../routing/lib/adventure/ride-alternatives');
const {surfaceKind}=require('../routing/lib/adventure/surface');
const {pavedBackroadCost}=require('../routing/lib/adventure/paved-backroad-cost');
const {createBudget}=require('../routing/lib/adventure/budget');
const root=process.env.REBUILD_PACK_ROOT;if(!root)throw Error('REBUILD_PACK_ROOT required');
const output=process.env.REBUILD_CLEAN_OUTPUT||'/tmp/dirt-clean-backroads';fs.mkdirSync(output,{recursive:true});
const regions=['ns','nb'].map(id=>{const b=fs.readFileSync(path.join(root,id,'graph.v4.bin')),g=fs.readFileSync(path.join(root,id,'geometry.v1.bin'));return {pack:decodeGraphV4(b,g),geom:decodeGeometryV1(g),stations:JSON.parse(fs.readFileSync(path.join(root,id,'fuel.v1.json'))).stations};});
const {pack,geom}=joinV4(regions,{budget:createBudget({deadlineAtMs:Date.now()+20000,maxExpansions:20000000})});
const stations=[...new Map(regions.flatMap(r=>r.stations).map(s=>[s.id,s])).values()],context=createRideAlternativeContext();
const input={mode:'from_here',anchors:[{id:'a',lat:44.76484254584986,lon:-63.34021846556175},{id:'b',lat:46.792506,lon:-67.569371}],legs:[{from:'a',to:'b',profile:'clean',allowUnknown:false}],fuel:{fullRangeMeters:250000,reserveFraction:.1,initialUsableMeters:225000}};
const summary=[];
for(const [id,major,nonpaved] of [['baseline',false,30],['backroads',true,30],['backroads-surface',true,100]]){
 const classes={primary:4,primary_link:4,trunk:8,trunk_link:8,motorway:32,motorway_link:32,freeway:32,service:6};
 const edgeCost=id==='backroads-surface'?pavedBackroadCost:a=>a.distanceMeters*(major?(classes[a.roadClassLeaf]||1):(/^(motorway|motorway_link|freeway)$/.test(a.roadClassLeaf||'')?8:1))*(surfaceKind(a.surfaceLeaf)==='paved'?1:nonpaved);
 const deadlineAtMs=Date.now()+20000,at=performance.now();
 const result=buildFromHere({input,pack,geom,stations,revision:'ns02-nb02-clean-test',...context,objectiveId:id,edgeCost,avoidMotorways:true,preferOnwardFuel:true,maxFuelLabels:400000,fuelHeuristicWeight:2,additionalUrbanAreas:require('../routing/lib/adventure/nb-urban-review-20260908-01.json').cores,budget:createBudget({deadlineAtMs,maxExpansions:30000000}),preparationBudget:createBudget({deadlineAtMs,maxExpansions:20000000})});
 fs.writeFileSync(path.join(output,id+'.json'),JSON.stringify(result));
 const roadClasses={};for(const s of result.road.segments||[])roadClasses[s.roadClassLeaf]=(roadClasses[s.roadClassLeaf]||0)+s.distanceMeters;
 const row={id,ms:Math.round(performance.now()-at),fuel:result.fuel.state,reason:result.fuel.reason,km:result.road.distanceMeters/1000,surface:result.road.surface,urban:result.road.urbanMeters,motorway:result.road.motorwayMeters,repeat:result.qualityAudit?.repeatedRoadMeters,stops:result.fuel.plannedRefills?.length,roadClasses};console.log(JSON.stringify(row));summary.push(row);
 assert.equal(result.fuel.state,'provisional_station_access');
 let atStop=0;for(const stop of result.fuel.plannedRefills){assert.ok(stop.atMeters-atStop<=225000+1e-6);atStop=stop.atMeters;}
 assert.ok(result.road.distanceMeters-atStop+result.fuel.destinationEscape.distanceMeters<=225000+1e-6);
}
fs.writeFileSync(path.join(output,'summary.json'),JSON.stringify(summary,null,2));
