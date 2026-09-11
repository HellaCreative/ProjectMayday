'use strict';
// Independent replay of returned segments against the baseline legal graph.
const assert=require('node:assert/strict');
const {createProjectedGraph}=require('../routing/lib/adventure/projected-graph');
const {createBudget}=require('../routing/lib/adventure/budget');
const {resolveHistory,directedArrival}=require('../routing/lib/adventure/arrival-history');
function auditRouteProof(pack,proof,request) {
 const segments=proof.routes.flatMap(r=>r.segments),points=[],positions=new Map();
 if(!segments.length)throw Error('No proved road to audit');
 const fraction=(s,start)=>s[start?'fromFraction':'toFraction']??(s[start?'fromNode':'toNode']===pack.edgeFrom[s.edgeIndex]?0:1);
 const point=(edge,f)=>{
  const key=`${edge}:${f}`;let id=positions.get(key);
  if(id===undefined){id='audit-'+points.length;points.push({id,edgeIndex:edge,fraction:f});positions.set(key,id);}return id;
 };
 for(const s of segments) {
  assert.equal(pack.edgeId(s.edgeIndex),s.edgeId,'Canonical source identity');
  for(const start of [true,false]){const f=fraction(s,start);if(f>0&&f<1)point(s.edgeIndex,f);}
 }
 const first=segments[0],last=segments.at(-1),startId=point(first.edgeIndex,fraction(first,true));
 const budget=createBudget({deadlineAtMs:Date.now()+120000,maxExpansions:100000000});
 const graph=createProjectedGraph(pack,{points,allowUnknown:request.profile!=='cleanest'&&request.accessPolicy?.motorizedUnknown===true,endpointEdges:[first.edgeIndex,last.edgeIndex],budget});
 assert.equal(graph.state,'complete');let state=0;
 if(request.options?.priorEdgeIds?.length) {
  const history=resolveHistory(pack,request.options.priorEdgeIds,request.options.arrivalEdgeId,budget);assert.equal(history.state,'complete');
  const incoming=history.edges.at(-1),startFraction=fraction(first,true);
  let arrivalFraction=startFraction;
  if(incoming!==first.edgeIndex) {
   assert.ok(startFraction===0||startFraction===1,'Different arrival road requires exact junction');
   const junction=startFraction===0?pack.edgeFrom[first.edgeIndex]:pack.edgeTo[first.edgeIndex];
   assert.ok(junction===pack.edgeFrom[incoming]||junction===pack.edgeTo[incoming],'Arrival road meets exact junction');
   arrivalFraction=junction===pack.edgeFrom[incoming]?0:1;
  }
  const arrival=directedArrival(pack,history.edges,{edgeIndex:incoming,fraction:arrivalFraction});assert.equal(arrival.state,'complete',arrival.reason);
  const seed=graph.seedArrival(arrival.arcs,startId);assert.equal(seed.allowed,true);state=seed.state;
 }
 const node=(e,f)=>f===0?pack.edgeFrom[e]:f===1?pack.edgeTo[e]:graph.pointNodes.get(positions.get(`${e}:${f}`));
 let previous=null;
 for(const s of segments) {
  const a=fraction(s,true),b=fraction(s,false),from=node(s.edgeIndex,a),to=node(s.edgeIndex,b);
  if(previous!==null)assert.equal(from,previous,'Exact topological continuity');
  let found;
  graph.forEachOutgoing(from,arc=>{
   if(arc.id===s.edgeIndex&&arc.to===to&&Math.abs(arc.distanceMeters-s.distanceMeters)<.01) {
    if(arc.fromFraction!=null&&(arc.fromFraction!==a||arc.toFraction!==b))return;
    found=arc;
   }
  });
  assert.ok(found,'Existing legal directed source arc '+s.edgeId);
  const next=graph.transition(state,found);assert.equal(next.allowed,true,'Node/via-way restriction '+s.edgeId);
  state=next.state;previous=to;
 }
 return {segments:segments.length,legalDirections:true,turnRestrictions:true,exactNodeContinuity:true,arrivalHistory:true};
}
module.exports={auditRouteProof};
