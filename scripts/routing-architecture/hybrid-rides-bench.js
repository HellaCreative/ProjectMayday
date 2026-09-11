'use strict';
const fs=require('node:fs'),path=require('node:path'),zlib=require('node:zlib'),assert=require('node:assert/strict');
const {startHybridRides}=require('./hybrid-rides-service');
const {values}=require('node:util').parseArgs({options:{dataset:{type:'string'},out:{type:'string'}}});
const root='/Users/richardsmith/.codex/experiments/routing-architecture-20260911';
const dataset=values.dataset??'nsnb',out=values.out;
assert(out&&!fs.existsSync(out),'Use an unused output filename');
assert(['nsnb','wv','strict-wv','wv-objective'].includes(dataset));
const fixtures=JSON.parse(fs.readFileSync(path.join(__dirname,'../../docs/experiments/routing-performance-2026-09-10/matrix-inputs.json')));
const settings=dataset==='nsnb'||dataset==='wv-objective'?
 [{id:'ns-short-balanced-road'}, {id:'ns-long-dirt-road',fuel:{usableRangeMeters:193121.28,initialUsableMeters:193121.28}},
  {id:'nsnb-balanced-road',fuel:{usableRangeMeters:180000,initialUsableMeters:90000}},
  {id:'nsnb-balanced-road',fuel:{usableRangeMeters:193121.28,initialUsableMeters:193121.28}}]:
 [{id:dataset==='wv'?'qc-long-dirt-road':'wv-road',fuel:{usableRangeMeters:193121.28,initialUsableMeters:193121.28}}];
if(dataset==='wv-objective')settings.push(...['qc-long-dirt-road','wv-road'].map(id=>({id,fuel:{usableRangeMeters:193121.28,initialUsableMeters:193121.28}})));
const raw=[],auditFuel=[],auditRoad=[],report={dataset,scope:'Shared candidate selection; provisional station access and additive generation, not full product qualification.',runs:[]};
(async()=>{
 const strict=dataset==='strict-wv',region=dataset==='nsnb'?'nsnb':'wv',objective=dataset==='wv-objective';
 const log=fs.createWriteStream(out+'.log');let service;
 try{
  const start=performance.now();
  service=await startHybridRides({descriptor:path.join(root,`data/verified-${region}/verified-input.json`),
   artifact:path.join(root,strict?'data/gh-verified-wv-strict-lm-km-v2':region==='nsnb'?'data/gh-verified-nsnb-directed-v2-objective':objective?'data/gh-verified-wv-objective-lm-km-v1':'data/gh-verified-wv-directed-v2'),
   objectiveLandmarks:region==='nsnb'||objective,objectiveKilometers:objective,strictMask:strict?path.join(root,'unified-stress/blocked-source-edges.bin'):null,onLog:line=>log.write(line+'\n')});
  report.initializationSeconds=(performance.now()-start)/1000;report.buildIdentity=service.buildIdentity;report.command=service.command;
  for(const item of settings){
   const locations=fixtures.find(f=>f.id===item.id).request.locations;
   const q={start:[locations[0].lon,locations[0].lat],end:[locations.at(-1).lon,locations.at(-1).lat],profile:'dirt',allowUnknown:false,...(item.fuel?{fuel:item.fuel}:{})};
   const result=await service.rides.route(q);raw.push({case:item.id,query:q,result});
   assert(result.selectedCandidateId,result);assert(result.state=== (q.fuel?'fuel_provisional':'road_only'),result.state);
   const choices=Object.fromEntries(Object.entries(result.choices).map(([style,id])=>{const c=result.candidates.find(x=>x.id===id);return [style,{id,surface:c.surface,fuel:c.fuel.state}];}));
   assert(choices.dirt.surface.knownDirtPercent>=choices.balanced.surface.knownDirtPercent,'Dirt missed richer Balanced candidate');
   const row={case:item.id,query:q,poolComplete:result.poolComplete,incompleteReason:result.incompleteReason,generationSeconds:result.generationSeconds,selectionSeconds:result.selectionSeconds,choices,cachedEdits:[]};
   if(result.poolComplete)for(const profile of ['balanced','clean','dirt']){
    const edited=await service.rides.route({...q,profile});assert(edited.cacheHit);assert.equal(edited.selectedCandidateId,result.choices[profile]);
    assert.equal(JSON.stringify(edited.candidates),JSON.stringify(result.candidates));row.cachedEdits.push({profile,seconds:edited.selectionSeconds});
   }
   for(const c of result.candidates){
    const entry={query:{...q,profile:c.id},result:c.route};(q.fuel&&c.eligible?auditFuel:!q.fuel?auditRoad:[]).push(entry);
   }
   report.runs.push(row);console.log(JSON.stringify(row));
  }
 }catch(error){report.failure=String(error);throw error;}
 finally{
  if(service)await service.close();log.end();
  fs.writeFileSync(out,JSON.stringify(report,null,2));
  for(const [suffix,rows] of [['responses',raw],['fuel-audit-input',auditFuel],['road-audit-input',auditRoad]])fs.writeFileSync(out+'.'+suffix+'.json.gz',zlib.gzipSync(JSON.stringify(rows)));
 }
})().catch(error=>{console.error(error);process.exitCode=1;});
