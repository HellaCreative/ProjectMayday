"use strict";

const {allows}=require("../v4-access-policy");
const {restrictionAppliesToMotorcycle}=require("../legal-topology/restrictions");

// Node-to-node experiment adapter. Endpoint projection/region stitching remain
// outside this adapter; it never invents snaps or nearby station membership.
function createV4Graph(pack,{allowUnknown=false,endpointEdges=[],stations=new Map()}={}) {
  if(pack.graphBinaryVersion!==4)throw new TypeError("Verified V4 graph required");
  const endpoints=new Set(endpointEdges),nodeTurns=new Map(),starts=new Map(),rules=[];
  for(const restriction of pack.restrictions || []) {
    if(!restrictionAppliesToMotorcycle(restriction))continue;
    if(!(restriction.viaEdges || []).length) {
      const nodes=restriction.viaNode!=null?[Number(restriction.viaNode)]:(restriction.viaNodeIds || []).map(Number);
      if(!nodes.length)throw new Error("Restriction has no resolved via node");
      for(const node of nodes) {
        const key=`${node}:${restriction.fromEdge}`;
        const row=nodeTurns.get(key) || {only:new Set(),no:new Set()};
        (restriction.only?row.only:row.no).add(Number(restriction.toEdge));nodeTurns.set(key,row);
      }
      continue;
    }
    const sequence=[restriction.fromEdge,...restriction.viaEdges,restriction.toEdge].map(Number);
    const first=sequence[0],next=sequence[1];
    const shared=[pack.edgeFrom[first],pack.edgeTo[first]].filter(node=>node===pack.edgeFrom[next]||node===pack.edgeTo[next]);
    // Ambiguous attachment needs a richer source representation; never guess.
    if(shared.length!==1)throw Object.assign(new Error(`Ambiguous via-way entry in restriction ${restriction.osmRelationId||"unknown"}`),
      {code:"ambiguous_via_way_entry",details:{relationId:restriction.osmRelationId||null,fromEdge:first,viaEdge:next,sharedNodes:shared}});
    const group=`${shared[0]}:${first}`;
    const id=rules.length;rules.push({sequence,only:restriction.only===true,group});
    const list=starts.get(group)||[];list.push(id);starts.set(group,list);
  }
  const states=[{incoming:-1,active:[]}],interned=new Map([["-1|",0]]);
  const transitionCache=new Map();
  function intern(incoming,active) {
    active.sort((a,b)=>a[0]-b[0]||a[1]-b[1]);
    const unique=active.filter((pair,i)=>!i||pair[0]!==active[i-1][0]||pair[1]!==active[i-1][1]);
    const key=`${incoming}|${unique.map(pair=>pair.join(":")).join(",")}`;
    let id=interned.get(key);if(id==null){id=states.length;states.push({incoming,active:unique});interned.set(key,id);}return id;
  }
  function transition(stateId,arc) {
    stateId=stateId??0;
    const cacheKey=`${stateId}:${arc.from}:${arc.id}`;
    const cached=transitionCache.get(cacheKey);if(cached)return cached;
    const state=states[stateId];if(!state)throw new TypeError("Unknown turn state");
    const nodeRule=nodeTurns.get(`${arc.from}:${state.incoming}`);
    if(nodeRule&&(nodeRule.no.has(arc.id)||(nodeRule.only.size&&!nodeRule.only.has(arc.id))))return {allowed:false};
    const groups=new Map(),active=[];
    for(const [id,position] of state.active) {
      const rule=rules[id],matches=rule.sequence[position]===arc.id;
      if(rule.only){const group=groups.get(rule.group)||{matches:false};group.matches ||= matches;groups.set(rule.group,group);}
      if(matches) {
        if(position===rule.sequence.length-1){if(!rule.only)return {allowed:false};}
        else active.push([id,position+1]);
      }
    }
    if([...groups.values()].some(group=>!group.matches))return {allowed:false};
    for(const id of starts.get(`${arc.to}:${arc.id}`)||[])active.push([id,1]);
    // Incoming edge is only relevant at a node with node restrictions. Keeping
    // every arrival distinct everywhere multiplies labels for no legal benefit.
    const incoming=nodeTurns.has(`${arc.to}:${arc.id}`)?arc.id:-1;
    const result={allowed:true,state:intern(incoming,active)};
    transitionCache.set(cacheKey,result);return result;
  }
  return {
    seedArrival(arcs) {
      if(!arcs.length)return {allowed:true,state:0};
      // Include restrictions that could have begun before the retained suffix.
      // This can conservatively reject an uncertain passage, never permit one
      // by forgetting its history. Completed suffix transitions refine it.
      const active=[];
      for(let id=0;id<rules.length;id++)for(let pos=1;pos<rules[id].sequence.length;pos++)
        if(rules[id].sequence[pos]===arcs[0].id)active.push([id,pos]);
      let state=intern(-1,active);
      for(const arc of arcs){const result=transition(state,arc);if(!result.allowed)return result;state=result.state;}
      return {allowed:true,state};
    },
    stateKey:(node,state)=>`${node}:${state??0}`,
    transition,
    stationAt:node=>stations.get(node)||null,
    forEachOutgoing(node,visit) {
      for(let offset=pack.nodeOffsets[node];offset<pack.nodeOffsets[node+1];offset++) {
        const id=pack.edgeUndirectedIndex[offset],to=pack.edgeTargets[offset];
        const endpoint=endpoints.has(id)?id:-1;
        if(!allows(pack,id,node,to,allowUnknown,endpoint,endpoint))continue;
        if(visit({id,from:node,to,roadClassLeaf:pack.enums.roadClassLeafNames?.[pack.edgeRoadClassLeaf[id]]||null,distanceMeters:pack.edgeMeters[id],surfaceLeaf:pack.enums.surfaceLeafNames[pack.edgeSurfaceLeaf[id]] || null})===false)return false;
      }
    },
    *outgoing(node) {
      for(let offset=pack.nodeOffsets[node];offset<pack.nodeOffsets[node+1];offset++) {
        const id=pack.edgeUndirectedIndex[offset],to=pack.edgeTargets[offset];
        const endpoint=endpoints.has(id)?id:-1;
        if(!allows(pack,id,node,to,allowUnknown,endpoint,endpoint))continue;
        yield {id,from:node,to,roadClassLeaf:pack.enums.roadClassLeafNames?.[pack.edgeRoadClassLeaf[id]]||null,distanceMeters:pack.edgeMeters[id],surfaceLeaf:pack.enums.surfaceLeafNames[pack.edgeSurfaceLeaf[id]] || null};
      }
    },
    diagnostics:()=>({turnStates:states.length,cachedTransitions:transitionCache.size})
  };
}
module.exports={createV4Graph};
