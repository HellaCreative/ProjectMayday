'use strict';
const fs=require('fs'),zlib=require('zlib');
const {readPreparedJoined}=require('../pack-fabric/bench/prepared-joined-runtime');const {createV4Graph}=require('../pack-fabric/routing/lib/adventure/v4-graph');const {surfaceKind}=require('../pack-fabric/routing/lib/adventure/surface');
const root=process.argv[2],receipt=JSON.parse(fs.readFileSync(root+'.receipt.json'));const {pack}=readPreparedJoined(root,{expectedIdentity:receipt.identity,manifestSha256:receipt.manifestSha256,geometryPaths:Object.fromEntries(receipt.identity.map(x=>[x.regionId,`/tmp/dirt-performance-packs/${x.regionId}/geometry.v1.bin`]))});
const records=JSON.parse(zlib.gunzipSync(fs.readFileSync(process.argv[3])));const reports=[];
for(const record of records){const p=record.result,errors=[],arcs=[];let meters=0;const surface={paved:0,dirt:0,unknown:0};
 for(const edge of p.edges||[]){const key=edge.sourceKey,e=key>>1,reverse=key%2;meters+=edge.meters;const expected=surfaceKind(pack.enums.surfaceLeafNames[pack.edgeSurfaceLeaf[e]]);surface[expected]+=edge.meters;if(edge.surfaceKind!==({paved:0,dirt:1,unknown:2}[expected]))errors.push('surface mismatch');
  if(arcs.at(-1)?.key===key)arcs.at(-1).distanceMeters+=edge.meters;else arcs.push({key,id:e,from:reverse?pack.edgeTo[e]:pack.edgeFrom[e],to:reverse?pack.edgeFrom[e]:pack.edgeTo[e],distanceMeters:edge.meters});
 }
 const g=createV4Graph(pack,{allowUnknown:record.query.allowUnknown});let state=0;
 for(let i=0;i<arcs.length;i++){const arc=arcs[i];if(i&&arcs[i-1].to!==arc.from)errors.push('disconnected source edges at '+i);if(arc.distanceMeters>pack.edgeMeters[arc.id]+2)errors.push('source geometry distance exceeds edge');let eligible=false;g.forEachOutgoing(arc.from,a=>{if(a.id===arc.id&&a.to===arc.to)eligible=true;});if(!eligible)errors.push('illegal access at '+i);const t=g.transition(state,arc);if(!t.allowed){errors.push('illegal turn at '+i);break;}state=t.state;}
 if(Math.abs(meters-p.distance)>0.01)errors.push('distance accounting mismatch');if(!arcs.length)errors.push('missing source walk');reports.push({run:record.run,profile:record.query.profile,edges:arcs.length,meters,surface,errors});
}
console.log(JSON.stringify(reports,null,2));if(reports.some(r=>r.errors.length))process.exitCode=1;
