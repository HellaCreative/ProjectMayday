'use strict';
const fs=require('fs'),crypto=require('crypto'),path=require('path');
const base=path.resolve(__dirname,'../../pack-fabric');
const {readPreparedJoined}=require(base+'/bench/prepared-joined-runtime');
const {buildFromHere}=require(base+'/routing/lib/adventure/from-here');
const {createBudget}=require(base+'/routing/lib/adventure/budget');
const {surfaceKind}=require(base+'/routing/lib/adventure/surface');
const root='/Users/richardsmith/.codex/experiments/routing-architecture-20260911',out=root+'/unified-stress';
const input=JSON.parse(fs.readFileSync(out+'/contract.json'));const started=performance.now();
const receipt=JSON.parse(fs.readFileSync(input.joined+'.receipt.json'));
const maskReceipt=JSON.parse(fs.readFileSync(out+'/mask-receipt.json')),mask=fs.readFileSync(out+'/blocked-source-edges.bin');
if(maskReceipt.sourceManifestSha256!==receipt.manifestSha256||maskReceipt.maskSha256!==crypto.createHash('sha256').update(mask).digest('hex'))throw Error('Mask identity mismatch');
const {pack:sourcePack,geom}=readPreparedJoined(input.joined,{expectedIdentity:receipt.identity,manifestSha256:receipt.manifestSha256,geometryPaths:Object.fromEntries(receipt.identity.map(x=>[x.regionId,`/tmp/dirt-performance-packs/${x.regionId}/geometry.v1.bin`]))});
const pack={...sourcePack,edgeAccess:new Uint8Array(sourcePack.edgeAccess)};
for(let edge=0;edge<mask.length;edge++)if(mask[edge]){pack.edgeAccess[edge*2]=2;pack.edgeAccess[edge*2+1]=2;}
const stations=new Map();for(const region of receipt.identity){const b=fs.readFileSync(`/tmp/dirt-performance-packs/${region.regionId}/fuel.v1.json`);if(crypto.createHash('sha256').update(b).digest('hex')!==region.fuelSha256)throw Error('Fuel identity mismatch');for(const s of JSON.parse(b).stations)stations.set(s.id,s);}
const budget=createBudget({deadlineAtMs:Date.now()+90000,maxExpansions:500000000});
const result=buildFromHere({input:{mode:'from_here',anchors:input.anchors,legs:[{from:'start',to:'end',profile:'dirt',allowUnknown:false}],fuel:{fullRangeMeters:input.fuelMeters,reserveFraction:0,initialUsableMeters:input.fuelMeters}},pack,geom,revision:'unified-stress-500x',stations:[...stations.values()],budget,edgeCost:arc=>arc.distanceMeters*(surfaceKind(arc.surfaceLeaf)==='dirt'?1:500),objectiveId:'dirt500-hard-urban',maxFuelLabels:500000,reverseCostCache:require(base+'/routing/lib/adventure/reverse-cost-cache').createReverseCostCache({maxBytes:512*1024*1024,useIncomingBounds:true}),ridePreferences:{wander:1,avoidCities:false,avoidHighways:false}});
fs.writeFileSync(out+'/'+(process.env.DIRT_STRESS_RESULT||'bespoke-response.json'),JSON.stringify(result));
console.log(JSON.stringify({seconds:(performance.now()-started)/1000,stage:result.stage,road:result.road.state,fuel:result.fuel.state,reason:result.fuel.reason,search:result.search,memory:process.memoryUsage()}));
