"use strict";
const fs=require('node:fs'),path=require('node:path');
const {auditRideShape}=require('../routing/lib/adventure/ride-shape-audit');
const {createBudget}=require('../routing/lib/adventure/budget');
const files=process.argv.slice(2);if(!files.length)throw Error('Pass saved probe JSON files');
const rows=files.map(file=>{
 const {result}=JSON.parse(fs.readFileSync(file));
 if(result.road?.state!=='complete')throw Error(`No complete road in ${file}`);
 const audit=auditRideShape({segments:result.road.segments,budget:createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:1000000})});
 return {file,knownDirtPercent:result.road.surface.knownDirtPercent,plannedStops:result.fuel.plannedRefills?.map(s=>({id:s.stationId,atMeters:s.atMeters}))||[],audit};
});
if(process.env.REBUILD_QUALITY_OUTPUT){fs.mkdirSync(path.dirname(process.env.REBUILD_QUALITY_OUTPUT),{recursive:true});fs.writeFileSync(process.env.REBUILD_QUALITY_OUTPUT,JSON.stringify(rows,null,2));}
console.log(JSON.stringify(rows.map(r=>({file:r.file,dirtPercent:r.knownDirtPercent,repeatedMeters:r.audit.repeatedRoadMeters,revisitedNodes:r.audit.revisitedNodes.length,runs:r.audit.dirtRuns.length,short:r.audit.shortDirtRunCounts})),null,2));
