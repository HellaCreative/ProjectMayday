"use strict";

// Each case gets a fresh process and then an immediate warm replay. Source
// overrides must be explicit: never silently substitute bundled legacy packs.
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const { spawnSync, execFileSync } = require("node:child_process");
const crypto = require("node:crypto");
const root = path.resolve(__dirname, "../../..");
const cases = [
  ...["dirt", "balanced", "cleanest"].map(profile => ({
    id: `ns-southwest-${profile}`, kind: "route", request: {
      profile,
      locations: [{lat:44.76484,lon:-63.34023},{lat:43.47454,lon:-65.60197}],
      accessPolicy:{motorizedPermissive:true,motorizedUnknown:false},
      options:{mapZoom:8}
    }
  })),
  {id:"montreal-fuel-handoff",kind:"fuel",request:{
    profile:"cleanest",locations:[{lat:44.76483,lon:-63.34026},{lat:45.36288,lon:-72.93782}],
    accessPolicy:{motorizedPermissive:true,motorizedUnknown:false},options:{mapZoom:7.2},
    fuel:{usableRangeMeters:333000,firstLegMaxMeters:333000,routeFirstPlan:true,
      forwardFeeler:true,allowPartialWindow:true,ensureDestinationFuelEscape:true,
      windowMaxStops:1,windowTimeBudgetMs:20000}
  }}
];

function configure() {
  const packRoot = process.env.REBUILD_PACK_ROOT;
  const remote = process.env.REBUILD_REGION_BASE;
  if (!packRoot || !remote) throw new Error("Set REBUILD_PACK_ROOT and REBUILD_REGION_BASE to the verified immutable release");
  const regions = ["ns","nb","pe","nl","qc"];
  const identities = regions.map(region => {
    const files = ["graph.v4.bin","geometry.v1.bin"].map(name => {
      const file = path.resolve(packRoot,region,name);
      const bytes = fs.readFileSync(file);
      return {file,bytes:bytes.length,sha256:crypto.createHash("sha256").update(bytes).digest("hex")};
    });
    return {region,files};
  });
  Object.assign(process.env,{
    DIRT_V4_REGIONS:regions.join(","),ROUTING_USE_REGIONAL:"1",ROUTING_PACKS_V2:"1",
    ROUTING_CHAIN_CACHE:"1",R2_REGION_BASE_OVERRIDES:JSON.stringify(Object.fromEntries(regions.map(id=>[id,remote]))),
    ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES:JSON.stringify(Object.fromEntries(regions.map(id=>[id,path.resolve(packRoot,id,"graph.v4.bin")])) )
  });
  delete process.env.DIRT_V4_CONNECTION_REVISION;
  return identities;
}

async function worker(id) {
  configure();
  const job=cases.find(row=>row.id===id);
  if (!job) throw new Error(`Unknown case ${id}`);
  const {routeRequest}=require("../routing/lib/router");
  const {fuelChainRequest}=require("../routing/lib/fuel-chain");
  for (const condition of ["cold-process","warm-process"]) {
    const request=structuredClone(job.request);
    request.options.deadlineAtMs=Date.now()+20000;
    const started=performance.now();
    const result=await (job.kind==="fuel"?fuelChainRequest(request):routeRequest(request));
    const debug=result.debug || {};
    const row={id,condition,request:job.request,elapsedMs:Math.round(performance.now()-started),
      status:result.status,error:result.error,message:result.message,distanceMeters:result.distanceMeters,
      stats:result.stats,quality:result.quality || debug.journeyQuality,
      diagnostics:result.diagnostics || debug.diagnostics,searchMeta:debug.searchMeta,
      stops:result.stops,packIdentity:debug.packIdentity,memory:process.memoryUsage(),
      maxRSS:process.resourceUsage().maxRSS};
    process.stdout.write(JSON.stringify(row)+"\n");
  }
}

function main() {
  const identities=configure();
  const output=path.resolve(process.env.REBUILD_BASELINE_OUTPUT || path.join(root,"scripts/pack-fabric/routing/candidates/rebuild-baseline"));
  fs.mkdirSync(output,{recursive:true});
  const manifest={createdAt:new Date().toISOString(),sourceRevision:execFileSync("git",["rev-parse","HEAD"],{cwd:root,encoding:"utf8"}).trim(),
    node:process.version,platform:process.platform,arch:process.arch,cpu:os.cpus()[0].model,
    processIsolation:"one process per case, two sequential requests; OS file cache not cleared",
    packIdentity:identities,remoteBase:process.env.REBUILD_REGION_BASE,cases};
  fs.writeFileSync(path.join(output,"manifest.json"),JSON.stringify(manifest,null,2));
  const rows=[];
  for (const job of cases) {
    const run=spawnSync(process.execPath,[__filename,"--worker",job.id],{
      cwd:root,env:process.env,encoding:"utf8",timeout:55000,maxBuffer:16*1024*1024});
    fs.writeFileSync(path.join(output,job.id+".jsonl"),run.stdout || "");
    if(run.stderr) fs.writeFileSync(path.join(output,job.id+".stderr"),run.stderr);
    for (const line of (run.stdout || "").split("\n").filter(Boolean)) {
      try { const row=JSON.parse(line); if(row.id===job.id) rows.push(row); } catch {}
    }
    if (run.status!==0) rows.push({id:job.id,status:"runner_failure",signal:run.signal,error:run.error?.message,exitCode:run.status});
    fs.writeFileSync(path.join(output,"results.json"),JSON.stringify(rows,null,2));
    console.log(JSON.stringify({id:job.id,rows:rows.filter(row=>row.id===job.id).map(row=>({condition:row.condition,status:row.status,error:row.error,ms:row.elapsedMs,knownDirtPercent:row.quality?.knownDirtPercent}))}));
  }
}
if(require.main===module) {
  if(process.argv[2]==="--worker") worker(process.argv[3]).catch(error=>{console.error(error);process.exitCode=1;});
  else main();
}
module.exports={cases};
