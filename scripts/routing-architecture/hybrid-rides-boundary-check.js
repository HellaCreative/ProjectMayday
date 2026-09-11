'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {startHybridRides}=require('./hybrid-rides-service');
const root='/Users/richardsmith/.codex/experiments/routing-architecture-20260911';
const out=process.argv[2];assert(out&&!fs.existsSync(out),'Supply an unused output path');
(async()=>{
 const service=await startHybridRides({descriptor:path.join(root,'data/verified-nsnb/verified-input.json'),artifact:path.join(root,'data/gh-verified-nsnb-directed-v2-objective'),objectiveLandmarks:true});
 const q={start:[-63.340199,44.764804],end:[-65.244265,47.013162],profile:'dirt',fuel:{usableRangeMeters:180000,initialUsableMeters:90000}};
 const report={buildIdentity:service.buildIdentity};
 try{
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),20),started=performance.now();
  try{await assert.rejects(service.rides.route(q,{signal:controller.signal}),/cancelled/);}finally{clearTimeout(timer);}
  assert.equal(service.rides.cache,null);report.cancelSeconds=(performance.now()-started)/1000;
  const active=service.rides.route(q);await assert.rejects(service.rides.route({...q,profile:'clean',timeoutMillis:80000}),/bounded_selection_busy/);
  const recovered=await active;assert.equal(recovered.state,'fuel_provisional');assert(recovered.poolComplete);report.recoverySeconds=recovered.generationSeconds;
  const limited=await service.rides.route({...q,timeoutMillis:1});assert.equal(limited.poolComplete,false);report.deadlineReason=limited.incompleteReason;
  const cached=await service.rides.route({...q,profile:'balanced'});assert(cached.cacheHit);assert.equal(cached.selectedCandidateId,recovered.choices.balanced);
  report.cachedEditSeconds=cached.selectionSeconds;report.state='passed';
 }finally{await service.close();fs.writeFileSync(out,JSON.stringify(report,null,2));}
 console.log(JSON.stringify(report));
})().catch(error=>{console.error(error);process.exitCode=1;});
