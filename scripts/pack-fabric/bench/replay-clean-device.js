"use strict";
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {decodeGraphV4}=require('../routing/lib/pack-v4'),{decodeGeometryV1}=require('../routing/lib/pack-v2');
const {buildRideAlternatives,createRideAlternativeContext}=require('../routing/lib/adventure/ride-alternatives');
const {createBudget}=require('../routing/lib/adventure/budget');
const root=process.env.REBUILD_PACK_ROOT;if(!root)throw Error('REBUILD_PACK_ROOT required');
const output=process.env.REBUILD_CROSS_OUTPUT||'scripts/pack-fabric/routing/candidates/rebuild-clean-device';fs.mkdirSync(output,{recursive:true});
const {joinV4}=require('../routing/lib/adventure/join-v4');
const regions=['ns','nb'].map(id=>{const bytes=fs.readFileSync(path.join(root,id,'graph.v4.bin')),geometry=fs.readFileSync(path.join(root,id,'geometry.v1.bin'));return {pack:decodeGraphV4(bytes,geometry),geom:decodeGeometryV1(geometry),stations:JSON.parse(fs.readFileSync(path.join(root,id,'fuel.v1.json'))).stations,sha:crypto.createHash('sha256').update(bytes).digest('hex')};});
const at=Date.now(),joined=joinV4(regions,{budget:createBudget({deadlineAtMs:Date.now()+20000,maxExpansions:20000000})});
console.log(JSON.stringify({joinMs:Date.now()-at,join:joined.diagnostics}));
const {pack,geom}=joined,identity=regions.map(r=>({regionId:r.pack.regionId,sha:r.sha})),context=createRideAlternativeContext();
const stationMap=new Map();for(const r of regions)for(const station of r.stations){const prior=stationMap.get(station.id);if(prior&&(prior.lat!==station.lat||prior.lon!==station.lon))throw Error('Conflicting station coordinates');stationMap.set(station.id,station);}
const stations=[...stationMap.values()],start={lat:44.764834,lon:-63.340240},end={lat:47.762610,lon:-65.856301},summary=[];
const dalhousie=process.env.REBUILD_DEVICE_CASE==='dalhousie';
for(const avoidMotorways of (dalhousie?[false]:[false,true])) {
 const input={mode:'from_here',anchors:[{id:'a',lat:44.76484254584986,lon:-63.34021846556175},{id:'b',lat:46.792506,lon:-67.569371}],legs:[{from:'a',to:'b',profile:'clean',allowUnknown:false}],fuel:{fullRangeMeters:225000,reserveFraction:0,initialUsableMeters:225000}};
 if(dalhousie){input.anchors=[{id:'a',lat:44.764831,lon:-63.340263},{id:'b',lat:47.986597,lon:-66.328424}];input.legs[0].profile='dirt';}
 const deadlineAtMs=Date.now()+20000,at=performance.now();
 const result=buildRideAlternatives({preferOnwardFuel:!!process.env.REBUILD_PRICE_RETRACE,additionalUrbanAreas:process.env.REBUILD_NB_URBAN?require('../routing/lib/adventure/nb-urban-review-20260908-01.json').cores:[],input,pack,geom,stations:stations.filter(s=>s.id!==process.env.REBUILD_EXCLUDE_STATION),avoidMotorways,expandedCandidates:true,maxFuelLabels:400000,fuelHeuristicWeight:2,revision:JSON.stringify(identity),context,budget:createBudget({deadlineAtMs,maxExpansions:30000000}),preparationBudget:createBudget({deadlineAtMs,maxExpansions:20000000})});
 const r=result.selected,classes={};for(const s of r?.road.segments||[])classes[s.roadClassLeaf]=(classes[s.roadClassLeaf]||0)+s.distanceMeters;
 const row={avoidMotorways,ms:Math.round(performance.now()-at),state:result.state,fuel:r?.fuel.state,reason:r?.fuel.reason,km:r?.road.distanceMeters/1000,surface:r?.road.surface,urban:r?.road.urbanMeters,motorway:r?.road.motorwayMeters,classes,search:result.search,candidates:result.candidates,cores:pack.meta.urbanCores};
 console.log(JSON.stringify(row));fs.writeFileSync(path.join(output,`clean-${avoidMotorways}.json`),JSON.stringify({identity,input,result}));
 assert.equal(result.state,'complete');assert.equal(r.fuel.state,'provisional_station_access');assert.equal(result.search.poolComplete,true);
 let previous=0;for(const stop of r.fuel.plannedRefills){assert.ok(stop.atMeters>=previous);assert.ok(stop.atMeters-previous<=225000+1e-6);previous=stop.atMeters;}
 assert.ok(r.road.distanceMeters-previous+r.fuel.destinationEscape.distanceMeters<=225000+1e-6);
 const {canarySupported,toLiveResponse}=require('../routing/lib/adventure/live-canary');
 const body={profile:dalhousie?'dirt':'cleanest',locations:input.anchors,options:{avoidMotorways,mapZoom:10.7},fuel:{usableRangeMeters:225000,firstLegMaxMeters:225000,windowMaxStops:12,allowPartialWindow:true}};
 assert.equal(canarySupported(body,'fuel',{DIRT_ADVENTURE_CANARY:'ns-nb-v1'}),true);
 const response=toLiveResponse(result,body,'fuel',identity);
 assert.equal(response.diagnostics.strategy,'adventure-preview-v1');assert.equal(response.windowComplete,true);assert.equal(response.routes.length,response.stops.length+1);
 fs.writeFileSync(path.join(output,`clean-${avoidMotorways}-response.json`),JSON.stringify(response));
}
