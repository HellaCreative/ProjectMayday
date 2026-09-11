'use strict';
// One immutable pack's incoming adjacency, independent of profile and projections.
// Keep exact source CSR order so reverse Dijkstra ties match the materialized path.
function createIncomingIndexCache({maxBytes=256*1024*1024}={}) {
 if(!Number.isSafeInteger(maxBytes)||maxBytes<0)throw new TypeError('Finite incoming index byte limit required');
 let entry=null;
 return {
  prepare({pack,revision,budget}) {
   if(typeof revision!=='string'||!revision)throw new TypeError('Immutable incoming revision required');
   if(!budget.check())return {state:'incomplete',reason:budget.snapshot().reason};
   if(entry&&entry.pack===pack&&entry.revision===revision)return {...entry,cacheHit:true};
   const count=pack.edgeTargets.length,byteLength=pack.nodeCount*4+count*8;
   if(byteLength>maxBytes)return {state:'incomplete',reason:'reverse_storage_limit'};
   entry=null;
   const heads=new Int32Array(pack.nodeCount);heads.fill(-1);
   const next=new Int32Array(count),sources=new Int32Array(count);
   for(let from=0;from<pack.nodeCount;from++) {
    if(!budget.consume())return {state:'incomplete',reason:budget.snapshot().reason};
    for(let at=pack.nodeOffsets[from];at<pack.nodeOffsets[from+1];at++) {
     if(!budget.consume())return {state:'incomplete',reason:budget.snapshot().reason};
     const to=pack.edgeTargets[at];
     if(!Number.isInteger(to)||to<0||to>=pack.nodeCount)throw new TypeError('Arc target outside graph');
     sources[at]=from;next[at]=heads[to];heads[to]=at;
    }
   }
   entry={state:'complete',pack,revision,heads,next,sources,byteLength};
   return {...entry,cacheHit:false};
  },
  clear(){entry=null;},
  diagnostics(){return {entries:entry?1:0,residentBytes:entry?.byteLength||0,maxBytes};}
 };
}

// The small endpoint/pump overlay is rebuilt per projected graph. It is never
// shared across arrivals or requests. All unsplit source arcs remain discoverable.
function projectedIncoming({pack,graph,splitEdges,affectedNodes,allowUnknown,endpointEdges,index,budget}) {
 const {allows}=require('../v4-access-policy'),endpoints=new Set(endpointEdges),overlay=new Map();
 for(const from of affectedNodes) {
  if(!budget.consume())return {state:'incomplete',reason:budget.snapshot().reason};
  let order=from<pack.nodeCount?pack.nodeOffsets[from]:0;
  let incomplete=false;
  graph.forEachOutgoing(from,arc=>{
   if(!budget.consume()){incomplete=true;return false;}
   if(from<pack.nodeCount) {
    while(order<pack.nodeOffsets[from+1]&&pack.edgeUndirectedIndex[order]!==arc.id)order++;
    if(order>=pack.nodeOffsets[from+1])throw new Error('Projected arc has no source CSR entry');
   }
   if(splitEdges.has(arc.id)) {
    const list=overlay.get(arc.to)||[];list.push({arc,order});overlay.set(arc.to,list);
   }
   order++;
  });
  if(incomplete)return {state:'incomplete',reason:budget.snapshot().reason};
 }
 for(const list of overlay.values())list.sort((a,b)=>b.arc.from-a.arc.from||b.order-a.order);
 const leaves=pack.enums,empty=Object.freeze([]);
 return {state:'complete',overlayArcs:[...overlay.values()].reduce((n,a)=>n+a.length,0),forEachIncoming(node,visit) {
  const added=overlay.get(node)||empty;let i=0,at=node<pack.nodeCount?index.heads[node]:-1;
  while(at!==-1||i<added.length) {
   const from=at===-1?-1:index.sources[at],extra=added[i];
   if(extra&&(extra.arc.from>from||(extra.arc.from===from&&extra.order>at))) {
    if(visit(extra.arc)===false)return false;i++;continue;
   }
   const id=pack.edgeUndirectedIndex[at];at=index.next[at];
   if(splitEdges.has(id))continue;
   const endpoint=endpoints.has(id)?id:-1;
   if(!allows(pack,id,from,node,allowUnknown,endpoint,endpoint))continue;
   if(visit({id,from,to:node,roadClassLeaf:leaves.roadClassLeafNames?.[pack.edgeRoadClassLeaf[id]]||null,
    distanceMeters:pack.edgeMeters[id],surfaceLeaf:leaves.surfaceLeafNames[pack.edgeSurfaceLeaf[id]]||null})===false)return false;
  }
 }};
}
module.exports={createIncomingIndexCache,projectedIncoming};
