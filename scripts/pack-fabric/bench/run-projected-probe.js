"use strict";

const fs=require("node:fs"),path=require("node:path"),crypto=require("node:crypto");
const {decodeGraphV4}=require("../routing/lib/pack-v4");
const {decodeGeometryV1}=require("../routing/lib/pack-v2");
const {selectConnectedSnapPair}=require("../routing/lib/legal-topology/snap");
const {buildEdgeIndex,matchStations}=require("../routing/lib/adventure/station-matching");
const {createProjectedGraph}=require("../routing/lib/adventure/projected-graph");
const {pointFromMatch,materializeRoute}=require("../routing/lib/adventure/route-geometry");
const {createBudget}=require("../routing/lib/adventure/budget");
const {buildLowerBounds,searchResourcePath}=require("../routing/lib/adventure/resource-search");
const {urbanAreasFromPack,buildUrbanExposure}=require("../routing/lib/adventure/urban-exposure");
const {surfaceKind}=require("../routing/lib/adventure/surface");
const root=process.env.REBUILD_PACK_ROOT;
if(!root)throw new Error("REBUILD_PACK_ROOT required");
const output=path.resolve(process.env.REBUILD_PROBE_OUTPUT || "scripts/pack-fabric/routing/candidates/rebuild-projected-probe");
fs.mkdirSync(output,{recursive:true});
const probeCase=process.env.REBUILD_PROBE_CASE||"southwest";
const cases={"qc-urban-anchor":[{id:"start",lat:45.5019,lon:-73.5674},{id:"end",lat:45.398,lon:-72.725}],"nb-constricted":[{id:"start",lat:46.0878,lon:-64.7782},{id:"end",lat:46.22,lon:-64.54}],southwest:[{id:"start",lat:44.76484,lon:-63.34023},{id:"end",lat:43.47454,lon:-65.60197}],
  "urban-anchor":[{id:"start",lat:44.64862,lon:-63.58595},{id:"end",lat:44.76484,lon:-63.34023}]};
const locations=cases[probeCase];
if(!locations)throw new Error("Unknown projected probe case");
const region=probeCase.startsWith("qc-")?"qc":probeCase.startsWith("nb-")?"nb":"ns";
const loadAt=performance.now();
const bytes=fs.readFileSync(path.join(root,region,"graph.v4.bin")),geometryBytes=fs.readFileSync(path.join(root,region,"geometry.v1.bin"));
const pack=decodeGraphV4(bytes,geometryBytes),geom=decodeGeometryV1(geometryBytes);
const loadMs=Math.round(performance.now()-loadAt);
const urbanEnabled=process.env.REBUILD_URBAN==="1";
const maxWork=Number(process.env.REBUILD_MAX_WORK||6000000);
const rows=[];
for(const reversed of [false,true]) {
  const totalAt=performance.now(),budget=createBudget({deadlineAtMs:Date.now()+15000,maxExpansions:maxWork});
  let stage="road_index";
  function requireComplete(value) {
    if(value?.state!=="complete")throw Object.assign(new Error(`${stage}: ${value?.reason||"not_complete"}`),
      {resultState:value?.state==="incomplete"?"incomplete":"failed",reason:value?.reason||"not_complete"});
  }
  try {
  const index=buildEdgeIndex(pack,geom,budget);
  requireComplete(index);
  stage="endpoint_matching";
  const matched=matchStations({pack,geom,index,stations:locations,maxMeters:2000,budget});
  requireComplete(matched);
  const picked=selectConnectedSnapPair(pack,matched.matches[reversed?1:0].candidates,matched.matches[reversed?0:1].candidates,{allowUnknown:false});
  if(!picked.ok)throw new Error(`Endpoint matching ${picked.reason}`);
  stage="projected_graph";
  const points=[pointFromMatch("start",picked.start,geom,budget),pointFromMatch("end",picked.end,geom,budget)];
  const graph=createProjectedGraph(pack,{points,budget,endpointEdges:points.map(p=>p.edgeIndex)});
  requireComplete(graph);
  const edgeCost=arc=>arc.distanceMeters*(surfaceKind(arc.surfaceLeaf)==="dirt"?1:10);
  const matchingMs=performance.now()-totalAt,urbanAt=performance.now();
  stage="urban_index";
  const classification=urbanEnabled?urbanAreasFromPack(pack):null;
  const urban=urbanEnabled?buildUrbanExposure({pack,geom,areas:classification.areas,budget,index}):null;
  if(urban)requireComplete(urban);
  const urbanMs=performance.now()-urbanAt,boundsAt=performance.now();
  stage="reverse_bounds";
  const lowerBounds=buildLowerBounds({graph,nodeCount:graph.nodeCount,target:graph.pointNodes.get("end"),edgeCost,budget});
  requireComplete(lowerBounds);
  stage="search";
  const searchAt=performance.now();
  const result=searchResourcePath({graph,start:graph.pointNodes.get("start"),end:graph.pointNodes.get("end"),edgeCost,budget,lowerBounds,avoidanceCost:urban?.urbanMeters});
  const materializeAt=performance.now();
  stage="geometry";
  const route=materializeRoute({pack,geom,result,budget});
  const row={probeCase,region,maxWork,graphSize:{nodes:pack.nodeCount,edges:pack.edgeCount},reversed,loadMs,processPeakRssKiB:process.resourceUsage().maxRSS,request:{locations:reversed?locations.slice().reverse():locations},
    limitations:["experimental dirt weights, not final profile objective",urbanEnabled?"embedded major cores only; large-town classification and berth unqualified":"urban avoidance not applied","fuel not requested/proved", "one connected endpoint pair, no alternate-pair retry"],
    graphSha256:crypto.createHash("sha256").update(bytes).digest("hex"),geometrySha256:crypto.createHash("sha256").update(geometryBytes).digest("hex"),
    urban:urban?{...urban.diagnostics,...classification.evidence,routeUrbanMeters:result.avoidanceCost}:null,
    timing:{urbanMs:Math.round(urbanMs),matchingMs:Math.round(matchingMs),boundsMs:Math.round(searchAt-boundsAt),searchMs:Math.round(materializeAt-searchAt),
      materializeMs:Math.round(performance.now()-materializeAt),totalMs:Math.round(performance.now()-totalAt)},
    routeFingerprint:crypto.createHash("sha256").update(JSON.stringify(result.arcs?.map(a=>[a.id,a.from,a.to,a.fromFraction,a.toFraction])||[])).digest("hex"),
    endpointMatches:{start:picked.start,end:picked.end},route,diagnostics:result.diagnostics};
  if(route.state!=="complete")process.exitCode=1;
  rows.push(row);fs.writeFileSync(path.join(output,`${reversed?"reverse":"forward"}.json`),JSON.stringify(row));
  console.log(JSON.stringify({reversed,state:route.state,timing:row.timing,urban:row.urban,surface:route.surface}));
  } catch(error) {
    const row={probeCase,region,maxWork,reversed,stage,state:error.resultState||"error",reason:error.reason||error.message,errorCode:error.code||null,errorDetails:error.details||null,
      graphSize:{nodes:pack.nodeCount,edges:pack.edgeCount},loadMs,totalMs:Math.round(performance.now()-totalAt),
      processPeakRssKiB:process.resourceUsage().maxRSS,budget:budget.snapshot(),
      graphSha256:crypto.createHash("sha256").update(bytes).digest("hex"),
      geometrySha256:crypto.createHash("sha256").update(geometryBytes).digest("hex")};
    fs.writeFileSync(path.join(output,`${reversed?"reverse":"forward"}.json`),JSON.stringify(row,null,2));
    console.log(JSON.stringify(row));process.exitCode=1;
  }
}
