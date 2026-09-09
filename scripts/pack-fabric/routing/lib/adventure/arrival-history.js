"use strict";
const indexes=new WeakMap();
// Pack-owned IDs can differ between a regional and joined graph. Resolve only
// explicit source aliases, never proximity or a guessed array index.
function resolveHistory(pack,ids,arrivalId,budget) {
 if(!arrivalId&&!ids?.length)return {state:'complete',edges:[]};
 if(typeof arrivalId!=='string'||!Array.isArray(ids)||ids.length>256||ids.some(id=>typeof id!=='string')||ids.at(-1)!==arrivalId)return {state:'incomplete',reason:'arrival_history_invalid'};
 let index=indexes.get(pack);
 if(!index){index=new Map();indexes.set(pack,index);}
 const pending=[...new Set(ids)].filter(id=>!index.has(id));
 if(pending.length){
  const targets=new Map(),found=new Map();
  for(const id of pending){for(const variant of new Set([id,id.replace(/#\d+$/,'')])){const originals=targets.get(variant)||[];originals.push(id);targets.set(variant,originals);}}
  const numeric=pending.every(id=>/^w?\d+:/.test(id));
  const ways=new Set(pending.map(id=>id.split(':')[0].replace(/^w/,'')));
  for(let e=0;e<pack.edgeCount;e++){
   if(!budget.consume())return {state:'incomplete',reason:budget.snapshot().reason};
   // Native and joined IDs both carry an OSM way identity. Only construct
   // aliases for requested ways, instead of retaining millions of strings.
   if(numeric&&pack.osmWayIds&&!ways.has(String(pack.osmWayIds[e])))continue;
   const aliases=[pack.edgeId(e),...(pack.edgeAliases?.(e)||[])];
   if(pack.osmNodeIds&&pack.osmWayIds)aliases.push(`${pack.osmWayIds[e]}:${pack.osmNodeIds[pack.edgeFrom[e]]}:${pack.osmNodeIds[pack.edgeTo[e]]}`);
   for(const alias of aliases)for(const id of targets.get(alias)||[]){if(found.has(id)&&found.get(id)!==e)found.set(id,null);else if(!found.has(id))found.set(id,e);}
  }
  // Cache only fully scanned requested identities, bounded per pack instance.
  if(index.size+pending.length>4096){const retained=ids.filter(id=>index.has(id)).map(id=>[id,index.get(id)]);index.clear();for(const [id,e] of retained)index.set(id,e);}
  for(const id of pending)index.set(id,found.get(id)??null);
 }
 const edges=ids.map(id=>index.get(id));
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
