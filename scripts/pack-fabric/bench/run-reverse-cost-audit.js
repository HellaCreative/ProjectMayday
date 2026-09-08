"use strict";
// One implementation per fresh process. Uses preserved packs read-only.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {decodeGraphV4}=require('../routing/lib/pack-v4');
const {createV4Graph}=require('../routing/lib/adventure/v4-graph');
const impl=require(process.env.REBUILD_REVERSE_IMPL?path.resolve(process.env.REBUILD_REVERSE_IMPL):'../routing/lib/adventure/resource-search');
const {createBudget}=require('../routing/lib/adventure/budget');
const root=process.env.REBUILD_PACK_ROOT,region=process.env.REBUILD_REGION||'on';
if(!root)throw Error('REBUILD_PACK_ROOT required');
const bytes=fs.readFileSync(path.join(root,region,'graph.v4.bin')),geo=fs.readFileSync(path.join(root,region,'geometry.v1.bin'));
const pack=decodeGraphV4(bytes,geo),graph=createV4Graph(pack),nodeCount=pack.nodeCount,edgeCost=a=>a.distanceMeters;
const work=n=>createBudget({deadlineAtMs:Date.now()+30000,maxExpansions:n});
let target=0;for(let n=1;n<nodeCount;n++)if(pack.nodeOffsets[n+1]-pack.nodeOffsets[n]>pack.nodeOffsets[target+1]-pack.nodeOffsets[target])target=n;
const report={region,graphSha256:crypto.createHash('sha256').update(bytes).digest('hex'),geometrySha256:crypto.createHash('sha256').update(geo).digest('hex'),nodeCount,edgeCount:pack.edgeCount,implementation:impl.prepareReverseCosts?'compact_reused':'previous_objects',targets:[]};
let reverseCosts;
if(impl.prepareReverseCosts){const budget=work(50000000),at=performance.now();reverseCosts=impl.prepareReverseCosts({graph,nodeCount,edgeCost,budget});report.preparation={state:reverseCosts.state,ms:Math.round(performance.now()-at),bytes:reverseCosts.byteLength,work:budget.snapshot()};}
for(const destination of [target,pack.edgeFrom[0],pack.edgeTo[0]]){
 const budget=work(50000000),at=performance.now(),bounds=impl.buildLowerBounds({graph,nodeCount,edgeCost,target:destination,reverseCosts,budget});
 report.targets.push({target:destination,state:bounds.state,ms:Math.round(performance.now()-at),work:budget.snapshot(),distanceSha256:bounds.distances?crypto.createHash('sha256').update(Buffer.from(bounds.distances.buffer)).digest('hex'):null});
 if(global.gc)global.gc();
}
report.peakRssKiB=process.resourceUsage().maxRSS;
const output=process.env.REBUILD_REVERSE_OUTPUT;if(output){fs.mkdirSync(path.dirname(output),{recursive:true});fs.writeFileSync(output,JSON.stringify(report,null,2));}console.log(JSON.stringify(report));
