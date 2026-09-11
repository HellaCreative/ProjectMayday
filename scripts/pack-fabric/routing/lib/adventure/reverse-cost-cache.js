"use strict";
const {prepareReverseCosts}=require('./resource-search');
// Bounded storage for exact projected topology and immutable additive costs.
// Never retains request turn histories: each request supplies a fresh graph.
function createReverseCostCache({maxBytes=64*1024*1024,useIncomingBounds=false}={}) {
 if(!Number.isSafeInteger(maxBytes)||maxBytes<0)throw new TypeError('Finite reverse cache byte limit required');
 let entry=null;
 const incoming=useIncomingBounds?require('./incoming-index').createIncomingIndexCache({maxBytes}):null;
 return {
  prepare({graph,revision,edgeCost,budget}) {
   if(typeof revision!=='string'||!revision||!graph.reverseTopology)throw new TypeError('Revision and projected topology required');
   if(!budget.check())return {state:'incomplete',reason:budget.snapshot().reason,cacheHit:false};
   const {pack,key}=graph.reverseTopology;
   if(incoming&&graph.prepareIncoming) {
    const index=incoming.prepare({pack,revision,budget});
    if(index.state!=='complete')return index;
    const overlay=graph.prepareIncoming({index,budget});
    if(overlay.state!=='complete')return overlay;
    return {state:'complete',cacheHit:index.cacheHit,reverseCosts:{state:'complete',graph,nodeCount:graph.nodeCount,edgeCost,
      forEachIncoming:overlay.forEachIncoming,byteLength:index.byteLength,overlayArcs:overlay.overlayArcs}};
   }
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
  clear(){entry=null;incoming?.clear();},
  diagnostics(){if(incoming)return {...incoming.diagnostics(),representation:'incoming-source-index'};return {entries:entry?1:0,residentBytes:entry?.costs.byteLength||0,maxBytes};}
 };
}
module.exports={createReverseCostCache};
