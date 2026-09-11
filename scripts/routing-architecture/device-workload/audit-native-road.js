'use strict';
// Independent V4 oracle used by the hybrid experiment, applied to native walks.
// Explicit endpoint approach lines are reported separately, never legal roads.
const fs=require('node:fs'),path=require('node:path');
const {decodeGraphV4}=require('../../pack-fabric/routing/lib/pack-v4');
const {createV4Graph}=require('../../pack-fabric/routing/lib/adventure/v4-graph');
const [packRoot,rawPath]=process.argv.slice(2);
const pack=decodeGraphV4(fs.readFileSync(path.join(packRoot,'graph.v4.bin')),fs.readFileSync(path.join(packRoot,'geometry.v1.bin')));
const byId=new Map();for(let e=0;e<pack.edgeMeters.length;e++){const id=pack.edgeId(e);if(byId.has(id))throw new Error('Ambiguous source ID');byId.set(id,e);}
const reports=[];
for(const line of fs.readFileSync(rawPath,'utf8').trim().split('\n')){
 let row;try{row=JSON.parse(line);}catch{continue;}if(!row.legs)continue;
 const errors=[],steps=[],approaches=[];let total=0;
 for(let i=0;i<row.legs.length;i++){
  const leg=row.legs[i];total+=leg.meters;
  if(leg.edgeId.startsWith('soft-stitch')){
   if(i!==0&&i!==row.legs.length-1)errors.push('Interior non-source connection');
   approaches.push({id:leg.edgeId,meters:leg.meters});continue;
  }
  const e=leg.edgeIndex??byId.get(leg.edgeId);
  if(!Number.isInteger(e)||pack.edgeId(e)!==leg.edgeId){errors.push('Missing source identity');continue;}
  const a=pack.edgeFrom[e],b=pack.edgeTo[e];let from=leg.fromNode,to=leg.toNode;
  if(from==null||to==null){
   // Native partial endpoint legs retain source IDs but omit node IDs.
   // Resolve only an unambiguous adjoining full leg; do not guess by proximity.
   const previous=steps.at(-1),next=row.legs[i+1];
   if(previous&&(previous.to===a||previous.to===b)){from=previous.to;to=from===a?b:a;}
   else if(next&&(next.fromNode===a||next.fromNode===b)){to=next.fromNode;from=to===a?b:a;}
   else {errors.push('Ambiguous endpoint direction');continue;}
  }
  if(!((from===a&&to===b)||(from===b&&to===a)))errors.push('Direction mismatches source edge');
  if(!Number.isFinite(leg.meters)||leg.meters<0||leg.meters>pack.edgeMeters[e]+2)errors.push('Source distance exceeds edge');
  steps.push({id:e,key:e*2+(from===a?0:1),from,to,distanceMeters:leg.meters});
 }
 if(Math.abs(total-row.distanceMeters)>.01)errors.push('Distance accounting');
 const graph=createV4Graph(pack,{allowUnknown:row.query.allowUnknown,endpointEdges:[steps[0]?.id,steps.at(-1)?.id]});let state=0;
 for(let i=0;i<steps.length;i++){
  const arc=steps[i];if(i&&steps[i-1].to!==arc.from)errors.push('Disconnected source walk at '+i);
  let eligible=false;graph.forEachOutgoing(arc.from,a=>{if(a.id===arc.id&&a.to===arc.to)eligible=true;});
  if(!eligible)errors.push('Illegal access at '+i);
  const t=graph.transition(state,arc);if(!t.allowed){errors.push('Illegal turn at '+i);break;}state=t.state;
 }
 if(!steps.length)errors.push('Empty source walk');
 reports.push({query:row.query,nativeSeconds:row.searchSeconds,distanceMeters:row.distanceMeters,knownDirtPercent:row.knownDirtPercent,
  sourceSteps:steps.length,endpointApproaches:approaches,errors});
}
console.log(JSON.stringify({passed:reports.length>0&&reports.every(x=>!x.errors.length),scope:'Source direction/access/continuous turn history and distance accounting. Endpoint approach lines are explicit unverified off-road approaches. No fuel proof, physical station entrance, optimality or device-capacity qualification.',reports},null,2));
if(!reports.length||reports.some(x=>x.errors.length))process.exitCode=1;
