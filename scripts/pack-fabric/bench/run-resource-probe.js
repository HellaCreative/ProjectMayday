"use strict";

// Kernel experiment, NOT a rider-ready route or an equal-endpoint live replay.
// Uses explicit graph nodes near the previously recorded NS route and only
// stations whose OSM node identity is present in the graph. Unmatched pumps
// remain missing evidence, never proof of geographic fuel scarcity.
const fs=require("node:fs"),path=require("node:path");
const {decodeGraphV4}=require("../routing/lib/pack-v4");
const {decodeGeometryV1}=require("../routing/lib/pack-v2");
const {buildEdgeIndex,matchStations}=require("../routing/lib/adventure/station-matching");
const {createV4Graph}=require("../routing/lib/adventure/v4-graph");
const {searchResourcePath,buildLowerBounds}=require("../routing/lib/adventure/resource-search");
const {surfaceKind,summarizeSurface}=require("../routing/lib/adventure/surface");
const {createBudget}=require("../routing/lib/adventure/budget");
const dir=process.env.REBUILD_PACK_ROOT;
if(!dir)throw new Error("REBUILD_PACK_ROOT required");
const loadedAt=performance.now();
const pack=decodeGraphV4(fs.readFileSync(path.join(dir,"ns/graph.v4.bin")),fs.readFileSync(path.join(dir,"ns/geometry.v1.bin")));
const loadMs=performance.now()-loadedAt;
const stationsJSON=JSON.parse(fs.readFileSync(path.join(dir,"ns/fuel.v1.json")));
const nodeMap=new Map(Array.from(pack.osmNodeIds,(id,i)=>[String(id),i]));
const stations=new Map();
for(const station of stationsJSON.stations){const match=/^osm:n(\d+)$/.exec(station.id);if(match&&nodeMap.has(match[1]))stations.set(nodeMap.get(match[1]),station);}
const output=path.resolve(process.env.REBUILD_PROBE_OUTPUT || "scripts/pack-fabric/routing/candidates/rebuild-resource-probe.json");
fs.mkdirSync(path.dirname(output),{recursive:true});
const rows=[];
const matchBudget=createBudget({deadlineAtMs:Date.now()+15000,maxExpansions:10000000});
const geom=decodeGeometryV1(fs.readFileSync(path.join(dir,"ns/geometry.v1.bin")));
const indexAt=performance.now(),index=buildEdgeIndex(pack,geom,matchBudget),matchAt=performance.now();
const matches=index.state==="complete"?matchStations({pack,geom,index,stations:stationsJSON.stations,maxMeters:150,budget:matchBudget}):index;
fs.writeFileSync(output.replace(/\.json$/,"-stations.json"),JSON.stringify({indexMs:Math.round(matchAt-indexAt),
  matchMs:Math.round(performance.now()-matchAt),maxMeters:150,result:matches},null,2));
console.log(JSON.stringify({stationMatching:matches.state,indexMs:Math.round(matchAt-indexAt),matchingMs:Math.round(performance.now()-matchAt),
  candidates:matches.matches?.filter(row=>row.state==="candidates").length,total:stationsJSON.stations.length}));
for(const kind of ["distance","dirt-weighted","dirt-weighted-fuel","dirt-weighted-bounded"]) {
  const graph=createV4Graph(pack,{stations});
  const start=57916,end=30794;
  const budget=createBudget({deadlineAtMs:Date.now()+15000,maxExpansions:2000000});
  const startAt=performance.now();
  const edgeCost=arc=>arc.distanceMeters*(kind==="distance"||surfaceKind(arc.surfaceLeaf)==="dirt"?1:10);
  const lowerBounds=kind.endsWith("bounded")?buildLowerBounds({graph,nodeCount:pack.nodeCount,target:end,edgeCost,budget}):null;
  const boundsMs=performance.now()-startAt;
  const result=searchResourcePath({graph,start,end,budget,
    edgeCost,lowerBounds,
    fuel:kind.endsWith("-fuel")?{usableRangeMeters:234000,initialUsableMeters:234000}:null,
    destinationEscapeMeters:0});
  const row={kind,state:result.state,reason:result.reason,ms:Math.round(performance.now()-startAt),
    loadMs:Math.round(loadMs),boundsMs:Math.round(boundsMs),graphNodes:pack.nodeCount,graphEdges:pack.edgeCount,
    matchedExactStationNodes:stations.size,totalStations:stationsJSON.stations.length,
    start:{index:start,osmNodeId:String(pack.osmNodeIds[start])},end:{index:end,osmNodeId:String(pack.osmNodeIds[end])},
    limitations:["node endpoints, no projection","urban policy not yet applied","experimental positive weights, not final Dirt objective",
      "only exact OSM station nodes included","destination fuel escape not checked in this kernel probe"],
    surface:result.arcs?summarizeSurface(result.arcs):null,visits:result.visits,diagnostics:result.diagnostics,
    turnState:graph.diagnostics(),memory:process.memoryUsage()};
  rows.push(row);fs.writeFileSync(output,JSON.stringify(rows,null,2));
  console.log(JSON.stringify({kind:row.kind,state:row.state,reason:row.reason,ms:row.ms,surface:row.surface,stations:stations.size,diagnostics:row.diagnostics}));
}
