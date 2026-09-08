"use strict";
const fs=require("node:fs"),path=require("node:path"),assert=require("node:assert/strict"),crypto=require("node:crypto"),{spawnSync}=require("node:child_process");
if(!process.env.REBUILD_PACK_ROOT)throw new Error("REBUILD_PACK_ROOT required");
const output=path.resolve(process.env.REBUILD_FROM_HERE_MATRIX_OUTPUT||"scripts/pack-fabric/routing/candidates/rebuild-from-here-matrix");fs.mkdirSync(output,{recursive:true});
const ids=["southwest","southwest-short-range","nearby","station-removed","stations-empty","initial-unknown"],rows=[],failures=[];
for(let repeat=1;repeat<=3;repeat++) {
  const dir=path.join(output,`run-${repeat}`);fs.mkdirSync(dir,{recursive:true});
  for(const id of ids)fs.rmSync(path.join(dir,`${id}.json`),{force:true});
  const child=spawnSync(process.execPath,[path.join(__dirname,"run-from-here-probe.js")],{encoding:"utf8",timeout:150000,maxBuffer:4*1024*1024,
    env:{...process.env,REBUILD_FROM_HERE_CASE:"",REBUILD_FROM_HERE_OUTPUT:dir,REBUILD_PAVEMENT_WEIGHT:"10",REBUILD_MAX_WORK:"6000000"}});
  fs.writeFileSync(path.join(output,`run-${repeat}.log`),child.stdout+child.stderr);
  if(child.status!==0)failures.push({repeat,kind:"process",status:child.status,error:child.error?.message});
  for(const id of ids) {
    try {
      const row=JSON.parse(fs.readFileSync(path.join(dir,`${id}.json`))),r=row.result;
      assert.equal(r.road.state,"complete");assert.ok(r.road.geometry.length>1);
      assert.ok(r.road.geometry.every(p=>p.length===2&&p.every(Number.isFinite)));
      assert.ok(Math.abs(r.road.segments.reduce((sum,s)=>sum+s.distanceMeters,0)-r.road.distanceMeters)<1e-5);
      const expected=["stations-empty","initial-unknown"].includes(id)?"unverified":"provisional_station_access";
      assert.equal(r.fuel.state,expected);
      if(expected==="provisional_station_access") {
        let remaining=r.request.fuel.initialUsableMeters,at=0;
        for(const stop of r.fuel.plannedRefills) {
          assert.ok(stop.atMeters>=at);remaining-=stop.atMeters-at;assert.ok(remaining>=-1e-6);
          assert.equal(stop.accessEvidence,"legal_road_projection");assert.ok(stop.station.id===stop.stationId);
          remaining=r.request.fuel.usableRangeMeters;at=stop.atMeters;
        }
        remaining-=r.road.distanceMeters-at;assert.ok(remaining>=-1e-6);
        assert.ok(Math.abs(remaining-r.fuel.arrivalUsableMeters)<1e-5);
        assert.ok(remaining-r.fuel.destinationEscape.distanceMeters>=-1e-6);
        if(id==="station-removed")assert.ok(r.fuel.plannedRefills.every(s=>s.stationId!=="osm:n5296522350"));
        if(id==="nearby")assert.equal(r.fuel.plannedRefills.length,0);
      } else assert.equal(r.fuel.reason,id==="stations-empty"?"no_station_bindings":"initial_fuel_unknown");
      rows.push({id,repeat,timing:r.timing,fuel:r.fuel.state,reason:r.fuel.reason||null,distanceKm:r.road.distanceMeters/1000,
        dirtPercent:r.road.surface.knownDirtPercent,stops:r.fuel.plannedRefills?.length||0,peakRssMiB:Math.round(row.processPeakRssKiB/1024),
        fingerprint:crypto.createHash("sha256").update(JSON.stringify([r.road.geometry,r.fuel.plannedRefills?.map(s=>[s.stationId,s.atMeters])||[]])).digest("hex"),source:row.source});
    } catch(error) {failures.push({repeat,id,kind:"result_validation",error:error.message});}
  }
  console.log(JSON.stringify({repeat,validated:rows.filter(r=>r.repeat===repeat).length,failures:failures.length}));
}
const groups=ids.map(id=>{
  const set=rows.filter(r=>r.id===id),times=set.map(r=>r.timing.totalMs).sort((a,b)=>a-b);
  return {id,count:set.length,minMs:times[0],medianMs:times[1],maxMs:times.at(-1),stableGeometryAndStops:set.length===3&&new Set(set.map(r=>r.fingerprint)).size===1,
    distanceKm:set[0]?.distanceKm,dirtPercent:set[0]?.dirtPercent,stops:set[0]?.stops,fuel:set[0]?.fuel,maxProcessRssMiB:Math.max(...set.map(r=>r.peakRssMiB))};
});
if(groups.some(g=>!g.stableGeometryAndStops))failures.push({kind:"repeatability_or_missing_results"});
const result={limitations:["station access remains provisional","experimental fixed surface costs, not final Dirt quality","single region and no app/API integration","three fresh processes, six sequential requests each; OS cache not cleared; timings exclude pack loading","RSS is process high-water mark, not per-request allocation"],groups,rows,failures};
fs.writeFileSync(path.join(output,"summary.json"),JSON.stringify(result,null,2));console.log(JSON.stringify({groups,failures},null,2));
if(failures.length)process.exitCode=1;
