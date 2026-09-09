"use strict";
const indexes=new WeakMap();
// Pack-owned IDs can differ between a regional and joined graph. Resolve only
// explicit source aliases, never proximity or a guessed array index.
function resolveHistory(pack,ids,arrivalId,budget) {
 if(!arrivalId&&!ids?.length)return {state:'complete',edges:[]};
 if(typeof arrivalId!=='string'||!Array.isArray(ids)||ids.length>256||ids.some(id=>typeof id!=='string')||ids.at(-1)!==arrivalId)return {state:'incomplete',reason:'arrival_history_invalid'};
 let index=indexes.get(pack);
 if(!index){index=new Map();for(let e=0;e<pack.edgeCount;e++){
  if(!budget.consume())return {state:'incomplete',reason:budget.snapshot().reason};
  for(const id of new Set([pack.edgeId(e),...(pack.edgeAliases?.(e)||[]),...(pack.osmNodeIds&&pack.osmWayIds?[`${pack.osmWayIds[e]}:${pack.osmNodeIds[pack.edgeFrom[e]]}:${pack.osmNodeIds[pack.edgeTo[e]]}`]:[])])){if(index.has(id)&&index.get(id)!==e)index.set(id,null);else if(!index.has(id))index.set(id,e);}
 }indexes.set(pack,index);}
 const edges=ids.map(id=>index.get(id)??index.get(id.replace(/#\d+$/,'')));
 if(edges.at(-1)==null)return {state:'incomplete',reason:'arrival_edge_not_in_graph'};
 // Earlier history can be outside this region. Seed restrictions conservatively
 // at the start of the continuous known suffix rather than invent connectivity.
 const lastMissing=edges.findLastIndex(e=>e==null);
 return {state:'complete',edges:edges.slice(lastMissing+1)};
}
function directedArrival(pack,edges,point) {
 if(!edges.length)return {state:'complete',arcs:[]};
 const last=edges.at(-1),a=pack.edgeFrom[last],b=pack.edgeTo[last];
 if(last!==point.edgeIndex)return {state:'incomplete',reason:'arrival_snap_mismatch'};
 let to;
 if(point.fraction===0)to=a;
 else if(point.fraction===1)to=b;
 else {
  const prior=edges.at(-2);
  if(prior==null)return {state:'incomplete',reason:'arrival_direction_unknown'};
  const shared=[a,b].filter(n=>n===pack.edgeFrom[prior]||n===pack.edgeTo[prior]);
  if(shared.length!==1)return {state:'incomplete',reason:'arrival_direction_ambiguous'};
  to=shared[0]===a?b:a;
 }
 const arcs=[];
 for(let i=edges.length-1;i>=0;i--){
  const id=edges[i],from=pack.edgeFrom[id]===to?pack.edgeTo[id]:pack.edgeTo[id]===to?pack.edgeFrom[id]:null;
  if(from==null)break;
  if(from===to)return {state:'incomplete',reason:'arrival_direction_ambiguous'};
  arcs.unshift({id,from,to});to=from;
 }
 return {state:'complete',arcs};
}
module.exports={resolveHistory,directedArrival};
