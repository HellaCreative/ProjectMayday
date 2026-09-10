'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {createTargetBoundsCache}=require('./target-bounds-cache');
const {createBudget}=require('./budget');
const budget=()=>createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:10000});
const pack={};
function graph(key='same',identity=pack){return {reverseTopology:{pack:identity,key},outgoing:n=>n<2?[{from:n,to:n+1,distanceMeters:2}]:[]};}
test('bounds share only identical topology, cost, target and stopping node',()=>{
 const cache=createTargetBoundsCache(),cost=a=>a.distanceMeters;
 const options={graph:graph(),target:2,nodeCount:3,edgeCost:cost,budget:budget(),stopAt:0};
 const first=cache.prepare(options),g=graph();
 const second=cache.prepare({...options,graph:g,budget:budget()});
 assert.equal(second.cacheHit,true);assert.equal(second.graph,g);assert.equal(second.distances,first.distances);
 for(const delta of [{graph:graph('changed')},{graph:graph('same',{})},{target:1},{stopAt:1},{edgeCost:a=>a.distanceMeters*2}]){
  cache.prepare({...options,budget:budget()});
  assert.equal(cache.prepare({...options,...delta,budget:budget()}).cacheHit,false);
 }
});
test('cached bounds do not override cancellation',()=>{
 const cache=createTargetBoundsCache(),g=graph(),cost=a=>a.distanceMeters;
 const options={graph:g,target:2,nodeCount:3,edgeCost:cost,budget:budget()};cache.prepare(options);
 const signal={aborted:true};const b=createBudget({deadlineAtMs:Date.now()+1000,maxExpansions:100,signal});
 assert.equal(cache.prepare({...options,budget:b}).reason,'cancelled');
});
