"use strict";

const {createV4Graph}=require("./v4-graph");

// Add positions ON existing road edges, never connectors between nearby roads.
// At an interior projection the rider must continue in the same legal direction.
// A mapped junction/dead end can permit reversal; a POI projection alone cannot
// invent a turnaround or let a turn restriction disappear midway along an edge.
function createProjectedGraph(pack,{points,allowUnknown=false,endpointEdges=[],budget,allowProvisionalStations=false}) {
  const base=createV4Graph(pack,{allowUnknown,endpointEdges});
  const byEdge=new Map(),pointNodes=new Map(),virtual=new Map(),stations=new Map();
  let nodeCount=pack.nodeCount;
  for(const point of points) {
    if(!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason};
    if(typeof point.id!=="string"||!point.id||pointNodes.has(point.id))throw new TypeError("Unique projected point id required");
    const edge=point.edgeIndex,fraction=point.fraction;
    if(!Number.isSafeInteger(edge)||edge<0||edge>=pack.edgeCount||!Number.isFinite(fraction)||fraction<0||fraction>1)throw new TypeError("Invalid road projection");
    let list=byEdge.get(edge);
    if(!list) {
      list=[{fraction:0,node:pack.edgeFrom[edge]},{fraction:1,node:pack.edgeTo[edge]}];
      byEdge.set(edge,list);
    }
    let position=list.find(p=>p.fraction===fraction);
    if(!position){position={fraction,node:nodeCount++};list.push(position);virtual.set(position.node,{edge,position});}
    pointNodes.set(point.id,position.node);
    if(point.station) {
      // Verified bindings remain the default. Explicit experimental opt-in
      // preserves road projections as provisional evidence, never verified.
      if(!point.station.id||!(point.station.accessEvidence==="verified"||(allowProvisionalStations===true&&point.station.accessEvidence==="legal_road_projection")))throw new TypeError("Station access evidence required");
      const existing=stations.get(position.node);
      if(existing&&existing.id!==point.station.id)throw new TypeError("Ambiguous station identity at projected point");
      stations.set(position.node,point.station);
    }
  }
  const permissions=new Map();
  for(const [edge,list] of byEdge) {
    if(!budget.consume())return {state:"incomplete",reason:budget.snapshot().reason};
    list.sort((a,b)=>a.fraction-b.fraction);
    const from=pack.edgeFrom[edge],to=pack.edgeTo[edge];
    const directions={forward:false,reverse:false};
    for(const arc of base.outgoing(from))if(arc.id===edge&&arc.to===to)directions.forward=true;
    for(const arc of base.outgoing(to))if(arc.id===edge&&arc.to===from)directions.reverse=true;
    permissions.set(edge,directions);
    list.forEach((position,index)=>{if(virtual.has(position.node))virtual.set(position.node,{edge,index,position});});
  }
  const transits=[],transitIds=new Map();
  function transit(state,edge,forward) {
    const key=`${state}:${edge}:${forward?1:0}`;
    let id=transitIds.get(key);
    if(id==null){id=transits.length;transits.push({state,edge,forward});transitIds.set(key,id);}
    return `transit:${id}`;
  }
  function partial(edge,a,b) {
    return {id:edge,from:a.node,to:b.node,distanceMeters:pack.edgeMeters[edge]*Math.abs(b.fraction-a.fraction),
      surfaceLeaf:pack.enums.surfaceLeafNames[pack.edgeSurfaceLeaf[edge]]||null,
      fromFraction:a.fraction,toFraction:b.fraction};
  }
  function transition(state,arc) {
    if(arc.fromFraction==null)return base.transition(state,arc);
    const forward=arc.toFraction>arc.fromFraction;
    let result;
    if(typeof state==="string"&&state.startsWith("transit:")) {
      const prior=transits[Number(state.slice(8))];
      if(!prior||prior.edge!==arc.id||prior.forward!==forward)return {allowed:false};
      result={allowed:true,state:prior.state};
    } else {
      // Evaluate the original directed edge once, including restrictions at
      // its real departure junction. Carry the result through all split pieces.
      result=base.transition(state,{...arc,from:forward?pack.edgeFrom[arc.id]:pack.edgeTo[arc.id],
        to:forward?pack.edgeTo[arc.id]:pack.edgeFrom[arc.id]});
    }
    if(!result.allowed)return result;
    return virtual.has(arc.to)?{allowed:true,state:transit(result.state,arc.id,forward)}:result;
  }
  return {
    state:"complete",nodeCount,pointNodes,stationCount:stations.size,
    stateKey:(node,state)=>`${node}:${state??0}`,
    transition,
    stationAt:node=>stations.get(node)||null,
    *outgoing(node) {
      const mid=virtual.get(node);
      if(mid) {
        const list=byEdge.get(mid.edge),directions=permissions.get(mid.edge);
        if(directions.forward&&mid.index+1<list.length)yield partial(mid.edge,mid.position,list[mid.index+1]);
        if(directions.reverse&&mid.index>0)yield partial(mid.edge,mid.position,list[mid.index-1]);
        return;
      }
      for(const arc of base.outgoing(node)) {
        const list=byEdge.get(arc.id);
        if(!list){yield arc;continue;}
        if(node===pack.edgeFrom[arc.id])yield partial(arc.id,list[0],list[1]);
        else yield partial(arc.id,list[list.length-1],list[list.length-2]);
      }
    },
    diagnostics:()=>({...base.diagnostics(),projectedNodes:virtual.size,splitEdges:byEdge.size,transitStates:transits.length,stations:stations.size})
  };
}
module.exports={createProjectedGraph};
