"use strict";
const fs=require("node:fs"),path=require("node:path"),crypto=require("node:crypto");
const {decodeGraphV4}=require("../routing/lib/pack-v4"),{decodeGeometryV1}=require("../routing/lib/pack-v2");
const {buildFromHere}=require("../routing/lib/adventure/from-here"),{createBudget}=require("../routing/lib/adventure/budget");
const {createReverseCostCache}=require("../routing/lib/adventure/reverse-cost-cache");
const {urbanAreasFromPack}=require("../routing/lib/adventure/urban-exposure");
const {createPreparationCache}=require("../routing/lib/adventure/preparation-cache"),{surfaceKind}=require("../routing/lib/adventure/surface");
if(!process.env.REBUILD_PACK_ROOT)throw new Error("REBUILD_PACK_ROOT required");
const output=path.resolve(process.env.REBUILD_FROM_HERE_OUTPUT||"scripts/pack-fabric/routing/candidates/rebuild-from-here");fs.mkdirSync(output,{recursive:true});
const directory=path.join(process.env.REBUILD_PACK_ROOT,process.env.REBUILD_REGION||"ns"),loadAt=performance.now();
const bytes=fs.readFileSync(path.join(directory,"graph.v4.bin")),geometry=fs.readFileSync(path.join(directory,"geometry.v1.bin")),fuelBytes=fs.readFileSync(path.join(directory,"fuel.v1.json"));
const pack=decodeGraphV4(bytes,geometry),geom=decodeGeometryV1(geometry),stations=JSON.parse(fuelBytes).stations;
const hash=x=>crypto.createHash("sha256").update(x).digest("hex");
const source={graphSha256:hash(bytes),geometrySha256:hash(geometry),fuelSha256:hash(fuelBytes)},revision=`${source.graphSha256}/${source.geometrySha256}`;
const loadMs=Math.round(performance.now()-loadAt),preparationCache=createPreparationCache(),reverseCostCache=createReverseCostCache();
const ratio=Number(process.env.REBUILD_PAVEMENT_WEIGHT||10),maxWork=Number(process.env.REBUILD_MAX_WORK||6000000);
const cases=[{id:"southwest",end:{lat:43.47454,lon:-65.60197},range:300000},
  {id:"southwest-short-range",end:{lat:43.47454,lon:-65.60197},range:180000},
  {id:"nearby",end:{lat:44.812,lon:-63.155},range:300000},
  {id:"station-removed",end:{lat:43.47454,lon:-65.60197},range:300000,removed:"osm:n5296522350"},
  {id:"stations-empty",end:{lat:43.47454,lon:-65.60197},range:300000,noStations:true,expectedFuel:"unverified"},
  {id:"initial-unknown",end:{lat:43.47454,lon:-65.60197},range:300000,unknownInitial:true,expectedFuel:"unverified"}];
const edgeCost=a=>a.distanceMeters*(surfaceKind(a.surfaceLeaf)==="dirt"?1:ratio);
if(process.env.REBUILD_PREWARM==="1") {
 const budget=createBudget({deadlineAtMs:Date.now()+30000,maxExpansions:50000000});
 const at=performance.now(),r=preparationCache.prepare({pack,geom,revision,areas:urbanAreasFromPack(pack).areas,budget});
 console.log(JSON.stringify({prewarm:r.state,ms:Math.round(performance.now()-at),work:budget.snapshot()}));
}
const repeats=Number(process.env.REBUILD_PROBE_REPEATS||1);
for(let repeat=1;repeat<=repeats;repeat++)for(const c of cases.filter(c=>!process.env.REBUILD_FROM_HERE_CASE||c.id===process.env.REBUILD_FROM_HERE_CASE)) {
  const start=process.env.REBUILD_START?JSON.parse(process.env.REBUILD_START):{lat:44.76484,lon:-63.34023};
  const end=process.env.REBUILD_END?JSON.parse(process.env.REBUILD_END):c.end;
  const request={mode:"from_here",anchors:[{id:"start",...start},{id:"destination",...end}],
    legs:[{from:"start",to:"destination",profile:"dirt",allowUnknown:false}],fuel:{fullRangeMeters:c.range,reserveFraction:.1,initialUsableMeters:c.unknownInitial?null:c.range*.9}};
  const at=performance.now();let result;
  try {result=buildFromHere({input:request,pack,geom,stations:c.noStations?[]:stations.filter(s=>s.id!==c.removed),revision,preparationCache,reverseCostCache,budget:createBudget({deadlineAtMs:Date.now()+20000,maxExpansions:maxWork}),
    objectiveId:`experimental-dirt-1-other-${ratio}`,edgeCost});}
  catch(error){result={state:"error",reason:error.message,stack:error.stack};process.exitCode=1;}
  const row={case:c.id,repeat,source,loadMs,maxWork,result,elapsedMs:Math.round(performance.now()-at),processPeakRssKiB:process.resourceUsage().maxRSS};
  fs.writeFileSync(path.join(output,`${c.id}${repeats>1?`-${repeat}`:""}.json`),JSON.stringify(row));
  console.log(JSON.stringify({case:c.id,road:result.road?.state,fuel:result.fuel?.state,reason:result.fuel?.reason||result.reason,
    timing:result.timing,stage:result.stage,surface:result.road?.surface,stops:result.fuel?.plannedRefills?.map(v=>({id:v.stationId,name:v.station?.name,atKm:v.atMeters/1000,offsetMeters:v.roadMatch?.distanceM})),
    peakRssMiB:Math.round(row.processPeakRssKiB/1024)}));
  if(result.road?.state!=="complete"||result.fuel?.state!==(c.expectedFuel||"provisional_station_access"))process.exitCode=1;
}
