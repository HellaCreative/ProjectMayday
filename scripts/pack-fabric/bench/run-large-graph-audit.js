"use strict";
// Read-only, fresh-process preparation audit. No restriction is removed to make
// a route pass. Run one region per process so peak RSS has a useful boundary.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {decodeGraphV4}=require('../routing/lib/pack-v4');
const {decodeGeometryV1}=require('../routing/lib/pack-v2');
const {createBudget}=require('../routing/lib/adventure/budget');
const {createPreparationCache}=require('../routing/lib/adventure/preparation-cache');
const {urbanAreasFromPack}=require('../routing/lib/adventure/urban-exposure');
const {createV4Graph}=require('../routing/lib/adventure/v4-graph');
const {buildLowerBounds}=require('../routing/lib/adventure/resource-search');
const root=process.env.REBUILD_PACK_ROOT,region=process.env.REBUILD_REGION;
if(!root||!region)throw Error('REBUILD_PACK_ROOT and REBUILD_REGION required');
const output=path.resolve(process.env.REBUILD_AUDIT_OUTPUT||`scripts/pack-fabric/routing/candidates/rebuild-large-audit/${region}.json`);
const row={region,root,note:'Fresh process. Preparation and relaxed reverse-bound costs, not a completed rider route. OS cache not cleared.'};
function budget(maxExpansions){return createBudget({deadlineAtMs:Date.now()+30000,maxExpansions});}
const start=performance.now(),bytes=fs.readFileSync(path.join(root,region,'graph.v4.bin')),geo=fs.readFileSync(path.join(root,region,'geometry.v1.bin'));
const pack=decodeGraphV4(bytes,geo),geom=decodeGeometryV1(geo);
row.loadMs=Math.round(performance.now()-start);row.graph={nodes:pack.nodeCount,edges:pack.edgeCount,restrictions:pack.restrictions.length};
row.graphSha256=crypto.createHash('sha256').update(bytes).digest('hex');
row.geometrySha256=crypto.createHash('sha256').update(geo).digest('hex');
const areas=urbanAreasFromPack(pack).areas;
row.ambiguous=[];
for(const r of pack.restrictions){if(!r.viaEdges?.length)continue;const a=r.fromEdge,b=r.viaEdges[0];const shared=[pack.edgeFrom[a],pack.edgeTo[a]].filter(n=>n===pack.edgeFrom[b]||n===pack.edgeTo[b]);if(shared.length!==1)row.ambiguous.push({relationId:r.osmRelationId,fromEdge:a,viaEdge:b,shared});}
const cache=createPreparationCache(),options={pack,geom,areas,revision:`${row.graphSha256}/${row.geometrySha256}`};
row.preparation=[];
for(const [label,limit] of [['cold_request_budget',6000000],['explicit_prewarm',50000000],['warm_request_budget',6000000]]){
 const work=budget(limit),at=performance.now(),r=cache.prepare({...options,budget:work});
 row.preparation.push({label,state:r.state,stage:r.stage,reason:r.reason,cacheHit:r.cacheHit,ms:Math.round(performance.now()-at),work:work.snapshot(),peakRssKiB:process.resourceUsage().maxRSS});
 if(global.gc)global.gc();
}
try{
 const at=performance.now(),graph=createV4Graph(pack);row.graphAdapterMs=Math.round(performance.now()-at);
 // Highest-degree node is an explicit reproducible target, not a rider pin.
 let target=0;for(let n=1;n<pack.nodeCount;n++)if(pack.nodeOffsets[n+1]-pack.nodeOffsets[n]>pack.nodeOffsets[target+1]-pack.nodeOffsets[target])target=n;
 row.bounds=[];
 for(const limit of [6000000,50000000]){
  const work=budget(limit),at=performance.now(),r=buildLowerBounds({graph,nodeCount:pack.nodeCount,target,edgeCost:a=>a.distanceMeters,budget:work});
  row.bounds.push({target,limit,state:r.state,reason:r.reason,reachableNodes:r.distances?.reduce((n,v)=>n+Number(Number.isFinite(v)),0),ms:Math.round(performance.now()-at),work:work.snapshot(),peakRssKiB:process.resourceUsage().maxRSS});
  if(global.gc)global.gc();
 }
}catch(error){row.graphAdapterError={code:error.code,message:error.message,details:error.details};}
row.peakRssKiB=process.resourceUsage().maxRSS;
fs.mkdirSync(path.dirname(output),{recursive:true});fs.writeFileSync(output,JSON.stringify(row,null,2));console.log(JSON.stringify(row));
