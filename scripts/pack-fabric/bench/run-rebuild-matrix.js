"use strict";
const fs=require("node:fs"),path=require("node:path"),{spawnSync}=require("node:child_process");
if(!process.env.REBUILD_PACK_ROOT)throw new Error("REBUILD_PACK_ROOT required");
const output=path.resolve(process.env.REBUILD_MATRIX_OUTPUT||"scripts/pack-fabric/routing/candidates/rebuild-test-matrix");
fs.mkdirSync(output,{recursive:true});
const rows=[],failures=[];
for(const probeCase of ["southwest","urban-anchor","nb-constricted"])for(let repeat=1;repeat<=3;repeat++) {
  const destination=path.join(output,`${probeCase}-${repeat}`);
  fs.mkdirSync(destination,{recursive:true});
  for(const file of ["forward.json","reverse.json"])fs.rmSync(path.join(destination,file),{force:true});
  const child=spawnSync(process.execPath,[path.join(__dirname,"run-projected-probe.js")],{
    env:{...process.env,REBUILD_PROBE_CASE:probeCase,REBUILD_URBAN:"1",REBUILD_PROBE_OUTPUT:destination},
    encoding:"utf8",timeout:45000,maxBuffer:4*1024*1024});
  fs.writeFileSync(path.join(output,`${probeCase}-${repeat}.log`),child.stdout+child.stderr);
  if(child.status!==0)failures.push({probeCase,repeat,status:child.status,error:child.error?.message||null});
  for(const direction of ["forward","reverse"]) {
    const file=path.join(destination,`${direction}.json`);
    if(!fs.existsSync(file))continue;
    const r=JSON.parse(fs.readFileSync(file));
    rows.push({probeCase,repeat,direction,state:r.route?.state||r.state,reason:r.route?.reason||r.reason||null,stage:r.stage||null,
      timing:r.timing||{totalMs:r.totalMs},loadMs:r.loadMs,
      processPeakRssKiB:r.processPeakRssKiB,preparationCacheHit:r.preparationCacheHit??false,routeFingerprint:r.routeFingerprint,urban:r.urban,surface:r.route?.surface||null,
      graphSha256:r.graphSha256,geometrySha256:r.geometrySha256,diagnostics:r.diagnostics});
  }
  console.log(JSON.stringify({probeCase,repeat,exit:child.status}));
}
const groups=[];
for(const probeCase of ["southwest","urban-anchor","nb-constricted"])for(const direction of ["forward","reverse"]) {
  const set=rows.filter(r=>r.probeCase===probeCase&&r.direction===direction),times=set.map(r=>r.timing.totalMs).sort((a,b)=>a-b);
  groups.push({probeCase,direction,completed:set.filter(r=>r.state==="complete").length,samples:set.length,
    urbanAreasPresent:set.length>0&&set.every(r=>r.urban?.areaCount>0),
    urbanClassificationQualified:set.length>0&&set.every(r=>r.urban?.classificationComplete===true),
    minMs:times[0]??null,medianMs:times[1]??null,maxMs:times.at(-1)??null,
    stableGeometry:set.every(r=>r.state==="complete"&&r.routeFingerprint)&&new Set(set.map(r=>r.routeFingerprint)).size===1&&set.length===3,
    maxProcessRssMiB:set.length?Math.round(Math.max(...set.map(r=>r.processPeakRssKiB))/1024):null});
}
const result={limitations:["three fresh processes per case; OS cache not cleared","forward and reverse share a process; RSS is process high-water mark, not per-search memory","timings exclude pack loading, include rebuilding matching/urban indexes","real fuel access and final ride objectives are not integrated"],rows,groups,failures};
fs.writeFileSync(path.join(output,"summary.json"),JSON.stringify(result,null,2));
console.log(JSON.stringify({groups,failures},null,2));
if(failures.length||rows.length!==18||groups.some(g=>g.completed!==3||!g.stableGeometry))process.exitCode=1;
