'use strict';
const fs=require('fs'),path=require('path'),crypto=require('crypto');
const {decodeGraphV4}=require('../routing/lib/pack-v4');
const {decodeGeometryV1}=require('../routing/lib/pack-v2');
const {adventureCanaryRequest}=require('../routing/lib/adventure/live-canary');
const {joinV4}=require('../routing/lib/adventure/join-v4');
const {createBudget}=require('../routing/lib/adventure/budget');
const [root,requestPath,output]=process.argv.slice(2);
if(!root||!requestPath||!output)throw Error('pack root, request JSON, output required');
const body=JSON.parse(fs.readFileSync(requestPath));
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
(async()=>{
 const started=Date.now();let loaded=[];
 const result=await adventureCanaryRequest(body,body.fuel?'fuel':'route',{environment:{DIRT_ADVENTURE_CANARY:'national-v1'},load:async resolution=>{
  const rows=resolution.regionIds.map(id=>{
   const at=Date.now(),folder=path.join(root,id),graph=fs.readFileSync(path.join(folder,'graph.v4.bin')),geometry=fs.readFileSync(path.join(folder,'geometry.v1.bin')),fuel=fs.readFileSync(path.join(folder,'fuel.v1.json'));
   const row={pack:decodeGraphV4(graph,geometry),geom:decodeGeometryV1(geometry),stations:JSON.parse(fuel).stations,identity:[{regionId:id,releaseId:'fabric-v4-20260909-01',graphSha256:sha(graph),geometrySha256:sha(geometry),fuelSha256:sha(fuel)}]};
   loaded.push({id,ms:Date.now()-at,nodes:row.pack.nodeCount,edges:row.pack.edgeCount});return row;
  });
  if(rows.length===1)return rows[0];
  const joined=joinV4(rows,{budget:createBudget({deadlineAtMs:Date.now()+20000,maxExpansions:30000000})});
  return {...joined,stations:[...new Map(rows.flatMap(r=>r.stations).map(s=>[s.id,s])).values()],identity:rows.flatMap(r=>r.identity)};
 }});
 const summary={status:result?.status,error:result?.error,ms:Date.now()-started,loaded,maxRSSKiB:process.resourceUsage().maxRSS,meters:result?.distanceMeters??result?.routes?.reduce((n,r)=>n+r.distanceMeters,0),diagnostics:result?.diagnostics||result?.debug};
 fs.writeFileSync(output,JSON.stringify({body,summary,result}));console.log(JSON.stringify(summary));
 if(result?.status!=='complete')process.exitCode=1;
})().catch(e=>{console.error(e);process.exitCode=1;});
