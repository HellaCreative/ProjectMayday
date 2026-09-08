"use strict";
const fs=require('fs'),path=require('path');
const {decodeGraphV4}=require('../routing/lib/pack-v4'),{decodeGeometryV1}=require('../routing/lib/pack-v2');
const {adventureCanaryRequest}=require('../routing/lib/adventure/live-canary');
const root=process.env.REBUILD_PACK_ROOT;if(!root)throw Error('REBUILD_PACK_ROOT required');
const graph=fs.readFileSync(path.join(root,'ns/graph.v4.bin')),geometry=fs.readFileSync(path.join(root,'ns/geometry.v1.bin')),stations=JSON.parse(fs.readFileSync(path.join(root,'ns/fuel.v1.json'))).stations;
const sha=b=>require('crypto').createHash('sha256').update(b).digest('hex');
const data={pack:decodeGraphV4(graph,geometry),geom:decodeGeometryV1(geometry),stations,identity:[{regionId:'ns',releaseId:'fabric-v4-20260908-02',graphSha256:sha(graph),geometrySha256:sha(geometry)}]};
const output=process.env.REBUILD_CANARY_OUTPUT||'scripts/pack-fabric/routing/candidates/rebuild-live-canary';fs.mkdirSync(output,{recursive:true});
(async()=>{for(const profile of (process.env.REBUILD_CAPE_UNKNOWN?['dirt']:['dirt','balanced','cleanest'])){
 const body=process.env.REBUILD_REQUEST_PATH?JSON.parse(fs.readFileSync(process.env.REBUILD_REQUEST_PATH)):{profile,locations:[{lat:44.76484,lon:-63.34023},(process.env.REBUILD_CAPE_UNKNOWN?{lat:46.873410,lon:-60.531752}:{lat:43.47454,lon:-65.60197})],accessPolicy:{motorizedUnknown:process.env.REBUILD_CAPE_UNKNOWN==='true'},fuel:{usableRangeMeters:process.env.REBUILD_CAPE_UNKNOWN?225000:270000,firstLegMaxMeters:process.env.REBUILD_CAPE_UNKNOWN?225000:270000,windowMaxStops:4,windowTimeBudgetMs:20000,routeFirstPlan:true,ensureDestinationFuelEscape:true}};
 const at=Date.now(),r=await adventureCanaryRequest(body,'fuel',{environment:{DIRT_ADVENTURE_CANARY:'ns-v1'},load:async()=>data});
 fs.writeFileSync(path.join(output,profile+'.json'),JSON.stringify({body,result:r}));
 console.log(JSON.stringify({profile,elapsedMs:Date.now()-at,status:r?.status,stops:r?.stops?.length,km:r?.routes?.reduce((n,r)=>n+r.distanceMeters,0)/1000,candidates:r?.diagnostics?.adventure?.candidates}));
 if(r?.status!=='complete')process.exitCode=1;
}})().catch(e=>{console.error(e);process.exitCode=1;});
