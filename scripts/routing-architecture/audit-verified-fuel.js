'use strict';
// Independently check resource accounting and carry the entire road+escape walk
// through the V4 oracle, without restarting its turn state at fuel stops.
const fs=require('fs'),zlib=require('zlib'),cp=require('child_process'),path=require('path');
const [joined,raw,stationFile]=process.argv.slice(2);
const records=JSON.parse(zlib.gunzipSync(fs.readFileSync(raw)));
const dataset=JSON.parse(fs.readFileSync(stationFile)),reports=[],walks=[];
function endpoint(step,last){const coords=step.geometry.match(/\((.*)\)/)[1].split(',').map(x=>x.trim().split(/\s+/).map(Number));return coords[last?coords.length-1:0];}
for(const record of records){
 const q=record.query,r=record.result,errors=[];
 if(r.state!=='found'){reports.push({profile:q.profile,errors:['incomplete fuel result: '+r.reason]});continue;}
 const stations=new Map(dataset.policies[String(q.allowUnknown)].filter(x=>!x.rejected).map(x=>[x.id,x]));
 let remaining=q.fuel.initialUsableMeters,meters=0;
 for(let i=0;i<r.steps.length;i++){
  const step=r.steps[i];
  if(step.refill){
   const station=stations.get(step.refill);if(!station||(q.excludedStationIds||[]).includes(step.refill))errors.push('unknown or excluded refill');
   if(step.from!==step.to||step.meters!==0)errors.push('refill moved rider');
   const before=r.steps.slice(0,i).findLast(x=>x.geometry),after=r.steps.slice(i+1).find(x=>x.geometry);
   const point=before?endpoint(before,true):after?endpoint(after,false):null;
   if(station&&(!point||Math.hypot(point[0]-station.position[0],point[1]-station.position[1])>0.00001))errors.push('refill projection mismatch');
   remaining=q.fuel.usableRangeMeters;
  }else{remaining-=step.meters;meters+=step.meters;if(remaining < -1e-5)errors.push('fuel exhausted before refill');}
 }
 if(Math.abs(remaining-r.remainingUsableMeters)>0.01)errors.push('remaining fuel mismatch');
 if(Math.abs(meters-r.distance)>0.01)errors.push('route meter mismatch');
 for(const step of r.escape){remaining-=step.meters;if(remaining < -1e-5)errors.push('destination escape exceeds fuel');}
 const escapeStation=stations.get(r.escapeStation),last=r.escape.findLast(x=>x.geometry)||r.steps.findLast(x=>x.geometry);
 if(!escapeStation||!last||Math.hypot(...endpoint(last,true).map((v,i)=>v-escapeStation.position[i]))>0.00001)errors.push('escape station projection mismatch');
 const edges=[...r.steps,...r.escape].filter(x=>!x.refill);
 walks.push({...record,result:{edges:edges.map(x=>({...x,surfaceKind:undefined})),distance:edges.reduce((a,x)=>a+x.meters,0)}});
 reports.push({profile:q.profile,meters,refills:r.steps.filter(x=>x.refill).map(x=>x.refill),errors});
}
// The existing road oracle derives surface from immutable source data. Fuel steps
// do not encode surfaceKind, so remove only that optional comparison in the oracle.
const derived=raw+'.fuel-walks.gz';fs.writeFileSync(derived,zlib.gzipSync(JSON.stringify(walks)));
const audit=cp.spawnSync(process.execPath,[path.join(__dirname,'audit-verified-routes.js'),joined,derived],{encoding:'utf8'});
console.log(JSON.stringify({fuel:reports,sourceWalks:audit.stdout?JSON.parse(audit.stdout):[],oracleStderr:audit.stderr},null,2));
if(audit.status!==0||reports.some(x=>x.errors.length))process.exitCode=1;
