"use strict";
const {prepareReverseCosts}=require('./resource-search');
// Bounded storage for exact projected topology and immutable additive costs.
// Never retains request turn histories: each request supplies a fresh graph.
function createReverseCostCache({maxBytes=64*1024*1024}={}) {
 if(!Number.isSafeInteger(maxBytes)||maxBytes<0)throw new TypeError('Finite reverse cache byte limit required');
 let entry=null;
 return {
  prepare({graph,revision,edgeCost,budget}) {
   if(typeof revision!=='string'||!revision||!graph.reverseTopology)throw new TypeError('Revision and projected topology required');
   if(!budget.check())return {state:'incomplete',reason:budget.snapshot().reason,cacheHit:false};
   const {pack,key}=graph.reverseTopology;
   if(entry&&entry.pack===pack&&entry.key===key&&entry.revision===revision&&entry.edgeCost===edgeCost) {
    return {state:'complete',cacheHit:true,reverseCosts:{...entry.costs,graph}};
   }
   // Release the old entry before allocating the replacement. The caller must
   // not retain previous results if it requires this residency bound.
   entry=null;
   const costs=prepareReverseCosts({graph,nodeCount:graph.nodeCount,edgeCost,budget,maxBytes:maxBytes});
   if(costs.state!=='complete')return {...costs,cacheHit:false};
   // Omit graph: retaining it would retain its growing request turn-state cache.
   const {graph:ignored,...stored}=costs;
   entry={pack,key,revision,edgeCost,costs:stored};
   return {state:'complete',cacheHit:false,reverseCosts:costs};
  },
  clear(){entry=null;},
  diagnostics(){return {entries:entry?1:0,residentBytes:entry?.costs.byteLength||0,maxBytes};}
 };
}
module.exports={createReverseCostCache};
