"use strict";

// Resolve at OSM member level, before graph-edge expansion. Never reinterpret
// each Cartesian pack row as a separate source maneuver.
function repairRepeatedSource({relation,ways,nodes,pack,edgeIndexes}) {
  const members=role=>relation.members.filter(m=>m.role===role&&m.type==="way").map(m=>String(m.ref));
  const from=members("from"),via=members("via"),to=members("to");
  const fail=reason=>{throw new Error(`Restriction ${relation.id}: ${reason}`);};
  if(from.length!==1||to.length!==1||via[0]!==from[0])fail("not a repeated first source-way relation");
  const original=[from[0],...via,to[0]];
  if(new Set(original).size===1)return {type:"quarantine",wayIds:[from[0]],reason:"all_source_roles_same_way_without_unique_junction"};
  const chain=[from[0],...via.slice(1),to[0]],junctions=[];
  for(let i=0;i<chain.length-1;i++) {
    const left=new Set(ways.get(chain[i]).nodeIds);
    const shared=[...new Set(ways.get(chain[i+1]).nodeIds.filter(n=>left.has(n)))];
    if(shared.length!==1)fail("source junction is not unique");
    junctions.push(shared[0]);
  }
  const osmNode=i=>String(pack.osmNodeIds[i]);
  const nodesForEdge=e=>[osmNode(pack.edgeFrom[e]),osmNode(pack.edgeTo[e])];
  const directionAllowed=(e,start)=>pack.edgeAccess[e*2+(nodesForEdge(e)[0]===start?0:1)]!==2;
  const touching=(way,node)=>edgeIndexes.get(way).filter(e=>nodesForEdge(e).includes(node));
  const structuralIncoming=touching(from[0],junctions[0]);
  let incoming=structuralIncoming.filter(e=> {
    const ns=nodesForEdge(e);return directionAllowed(e,ns[0]===junctions[0]?ns[1]:ns[0]);
  });
  const lastJunction=junctions.at(-1);
  const structuralOutgoing=touching(to[0],lastJunction);
  let outgoing=structuralOutgoing.filter(e=>directionAllowed(e,lastJunction));
  const prohibitedApproach=!incoming.length;
  // An otherwise uniquely resolved prohibition may already be enforced by
  // one-way access. Retain its rule; do not invent another legal approach.
  if(!incoming.length&&structuralIncoming.length===1)incoming=structuralIncoming;
  if(!outgoing.length&&structuralOutgoing.length===1)outgoing=structuralOutgoing;
  const viaEdges=[],viaWayIds=[];
  for(let i=1;i<chain.length-1;i++) {
    const way=ways.get(chain[i]),start=way.nodeIds.indexOf(junctions[i-1]),end=way.nodeIds.indexOf(junctions[i]);
    if(start===end||start<0||end<0)fail("empty source via path");
    const ordered=edgeIndexes.get(chain[i]).map(e=>({e,p:nodesForEdge(e).map(n=>way.nodeIds.indexOf(n))}))
      .filter(r=>r.p.every(p=>p>=Math.min(start,end)&&p<=Math.max(start,end)))
      .sort((a,b)=>Math.min(...a.p)-Math.min(...b.p));
    if(start>end)ordered.reverse();
    let at=junctions[i-1];
    for(const {e} of ordered) {
      const ns=nodesForEdge(e);if(!ns.includes(at)||!directionAllowed(e,at))fail("via path is discontinuous or prohibited");
      at=ns[0]===at?ns[1]:ns[0];viaEdges.push(e);viaWayIds.push(chain[i]);
    }
    if(at!==junctions[i]||!ordered.length)fail("incomplete source via path");
  }
  const evidence={originalMemberWays:original,normalizedMemberWays:chain,sourceJunctions:junctions,prohibitedApproach};
  // Multiple approaches on an unsplit two-way source require an unambiguous
  // maneuver. Keep this strict and reject unsupported shapes rather than
  // broadening a left-turn prohibition to the opposite right turn.
  if(incoming.length*outgoing.length>1) {
    if(viaEdges.length||relation.tags.restriction!=="no_left_turn")fail("multiple directed source maneuvers");
    const j=junctions[0],origin=nodes.get(j),lat=Math.cos(origin.lat*Math.PI/180);
    const near=(way,node,edge)=> {
      const list=ways.get(way).nodeIds,at=list.indexOf(node),other=nodesForEdge(edge).find(n=>n!==node);
      return nodes.get(list[at+(list.indexOf(other)>at?1:-1)]);
    };
    const candidates=[];
    for(const a of incoming)for(const z of outgoing) {
      const before=near(from[0],j,a),after=near(to[0],j,z);
      const u=[(origin.lon-before.lon)*lat,origin.lat-before.lat],v=[(after.lon-origin.lon)*lat,after.lat-origin.lat];
      const angle=Math.atan2(u[0]*v[1]-u[1]*v[0],u[0]*v[0]+u[1]*v[1])*180/Math.PI;
      if(angle>45&&angle<135)candidates.push({a,z,angle});
    }
    if(candidates.length!==1)fail("left maneuver is not uniquely established");
    incoming=[candidates[0].a];outgoing=[candidates[0].z];evidence.leftTurnDegrees=candidates[0].angle;
  }
  if(incoming.length!==1||outgoing.length!==1)fail("source maneuver lacks one legal approach and exit");
  const fromEdge=incoming[0],toEdge=outgoing[0];
  const viaNode=[pack.edgeFrom[fromEdge],pack.edgeTo[fromEdge]].find(n=>osmNode(n)===junctions[0]);
  return {type:"resolved",fromEdge,toEdge,viaNode,viaEdges,viaWayIds,evidence};
}

module.exports={repairRepeatedSource};
