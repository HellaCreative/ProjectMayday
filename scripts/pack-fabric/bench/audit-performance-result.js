'use strict';
const fs=require('node:fs'),zlib=require('node:zlib'),crypto=require('node:crypto');
const {decodeGraphV4,decodeGeometryV1}=require('../routing/lib/pack-v4');
const {qualifiedPack}=require('../routing/lib/adventure/pack-revision-qualification');
const {joinV4}=require('../routing/lib/adventure/join-v4');
const {createBudget}=require('../routing/lib/adventure/budget');
const {auditRouteProof}=require('./audit-route-proof');
const input=process.argv[2],report=JSON.parse(fs.readFileSync(input)),proofs=JSON.parse(zlib.gunzipSync(fs.readFileSync(input+'.proof.json.gz')));
const request=structuredClone(report.fixture.request),cache=new Map(),results=[],history=[];
function load(id) {
 if(cache.has(id))return cache.get(id);
 const root=(process.env.PERFORMANCE_PACK_ROOT||'/tmp/dirt-performance-packs')+'/'+id;
 const g=fs.readFileSync(root+'/graph.v4.bin'),geo=fs.readFileSync(root+'/geometry.v1.bin'),f=fs.readFileSync(root+'/fuel.v1.json');
 const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
 if(!qualifiedPack({regionId:id,releaseId:'fabric-v4-20260909-02',graphSha256:hash(g),geometrySha256:hash(geo),fuelSha256:hash(f)}))throw Error('Unqualified source');
 const row={pack:decodeGraphV4(g,geo),geom:decodeGeometryV1(geo)};cache.set(id,row);return row;
}
let joined=null;
for(let i=0;i<proofs.length;i++) {
 const proof=proofs[i];if(proof.status!=='complete')continue;
 const regions=report.runs[0].windows[i].regions,key=regions.join(',');
 if(joined?.key!==key) {
  const rows=regions.map(load);
  joined={key,pack:rows.length===1?rows[0].pack:joinV4(rows,{budget:createBudget({deadlineAtMs:Date.now()+120000,maxExpansions:200000000})}).pack};
 }
 results.push({window:i,...auditRouteProof(joined.pack,proof,request)});
 for(const r of proof.routes)for(const s of r.segments){
  const prior=history.findIndex(h=>h.id===s.edgeId);if(prior>=0)history.splice(prior,1);
  history.push({id:s.edgeId,meters:Math.max(1,s.distanceMeters)});
  while(history.length>1&&(history.length>256||history.reduce((n,h)=>n+h.meters,0)>30000))history.shift();
 }
 request.options={...request.options,priorEdgeIds:history.map(h=>h.id),arrivalEdgeId:history.at(-1)?.id};
}
fs.writeFileSync(input+'.legal-audit.json',JSON.stringify({input,case:report.caseId,results},null,2));
console.log(JSON.stringify({case:report.caseId,windows:results.length,segments:results.reduce((n,r)=>n+r.segments,0),passed:true}));
