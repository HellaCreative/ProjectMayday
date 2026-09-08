"use strict";
const test=require('node:test'),assert=require('node:assert/strict');
const {prepareReverseCosts,buildLowerBounds}=require('./resource-search');
const {createBudget}=require('./budget');
const budget=(n=1000000,signal)=>createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:n,signal});
const edgeCost=a=>a.distanceMeters;
function chain(n){return {outgoing:i=>i+1<n?[{to:i+1,distanceMeters:1}]:[]};}
test('reusable reverse costs span chunks and preserve directed reachability across targets',()=>{
 const nodeCount=17000,graph=chain(nodeCount),reverseCosts=prepareReverseCosts({graph,nodeCount,edgeCost,budget:budget()});
 assert.equal(reverseCosts.state,'complete');assert.equal(reverseCosts.chunks.length,2);
 // Reuse must not enumerate the graph again; it is target-independent.
 graph.outgoing=()=>{throw Error('unexpected rebuild');};
 const last=buildLowerBounds({graph,nodeCount,edgeCost,target:16999,reverseCosts,budget:budget()});
 const middle=buildLowerBounds({graph,nodeCount,edgeCost,target:10,reverseCosts,budget:budget()});
 assert.equal(last.distances[0],16999);assert.equal(middle.distances[0],10);assert.equal(middle.distances[11],Infinity);
 assert.equal(reverseCosts.byteLength,nodeCount*4+2*16384*16);
});
test('bounded or interrupted reverse preparation never publishes partial reachability',()=>{
 const graph=chain(4),args={graph,nodeCount:4,edgeCost};
 assert.deepEqual(prepareReverseCosts({...args,budget:budget(),maxBytes:16}),{state:'incomplete',reason:'reverse_storage_limit'});
 assert.equal(prepareReverseCosts({...args,budget:budget(1)}).reason,'expansion_limit');
 const reverseCosts=prepareReverseCosts({...args,budget:budget()});
 const cancelled=buildLowerBounds({...args,target:3,reverseCosts,budget:budget(100,{aborted:true})});
 assert.equal(cancelled.reason,'cancelled');assert.equal(cancelled.distances,undefined);
 assert.equal(buildLowerBounds({...args,target:3,budget:budget(),maxReverseBytes:16}).reason,'reverse_storage_limit');
});
test('reverse costs cannot be reused across graph or cost identities',()=>{
 const graph=chain(4),args={graph,nodeCount:4,edgeCost},reverseCosts=prepareReverseCosts({...args,budget:budget()});
 for(const changed of [{graph:chain(4)},{edgeCost:a=>2*a.distanceMeters},{nodeCount:5},{reverseCosts:{state:'incomplete'}}])
  assert.throws(()=>buildLowerBounds({...args,target:3,reverseCosts,...changed,budget:budget()}),/Reverse costs/);
});
