"use strict";

// Test-only oracle. Reads committed fixture packs and executes the reference JS.
// Never used by the native application; never downloads or publishes anything.
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const root = path.resolve(__dirname,"..");
const lib = path.join(root,"scripts/pack-fabric/routing/lib");
const {decodeGraphV4} = require(path.join(lib,"pack-v4"));
const {decodeGeometryV1} = require(path.join(lib,"pack-v2"));
const {findPathV2} = require(path.join(lib,"find-path-v2"));
const {compileRestrictionIndex,advanceRestrictionState} = require(path.join(lib,"legal-topology/restrictions"));
const {crossTrackMeters} = require(path.join(lib,"profile-costs"));
const names = ["legal-topology-canary","legal-topology-forecourt","legal-topology-forecourt-blocked","legal-topology-restrictions"];
const output = path.join(root,"Packages/DirtRoutingEngine/Tests/DirtRoutingEngineTests/Fixtures");
const sha = b => crypto.createHash("sha256").update(b).digest("hex");
function meters(a,b) {
  const rad = Math.PI/180, x = (b[1]-a[1])*rad, y = (b[0]-a[0])*rad;
  return 12742000*Math.asin(Math.min(1,Math.sqrt(Math.sin(x/2)**2+Math.cos(a[1]*rad)*Math.cos(b[1]*rad)*Math.sin(y/2)**2)));
}
for (const name of names) {
  const graph = fs.readFileSync(path.join(root,"DirtTests/Fixtures",name+".graph.v4.bin"));
  const geometry = fs.readFileSync(path.join(root,"DirtTests/Fixtures",name+".geometry.v1.bin"));
  const pack = decodeGraphV4(graph,geometry), geom = decodeGeometryV1(geometry);
  const runtime = {pack,geom,enums:pack.enums};
  const edges = Array.from({length:pack.undirectedEdgeCount},(_,i)=>({
    id:pack.edgeId(i),from:pack.edgeFrom[i],to:pack.edgeTo[i],meters:pack.edgeMeters[i],
    forward:pack.edgeAccess[i*2],reverse:pack.edgeAccess[i*2+1],way:String(pack.osmWayIds[i]),leaves:pack.edgeLeaves(i)
  }));
  const restrictionIndex=compileRestrictionIndex(pack.restrictions),turns=[];
  for(let node=0;node<pack.nodeCount;node++) for(let from=0;from<pack.undirectedEdgeCount;from++) {
    for(let arc=pack.nodeOffsets[node];arc<pack.nodeOffsets[node+1];arc++) {
      const to=pack.edgeUndirectedIndex[arc],result=advanceRestrictionState(restrictionIndex,[],from,to,node);
      turns.push({node,from,to,...result});
    }
  }
  const matches = edges.map((e,i)=>{
    const line=geom.polyline(i),segmentIndex=0, a=line[0],b=line[1];
    const coord=[(a[0]+b[0])/2,(a[1]+b[1])/2];
    let edgeMeters=0;for(let j=1;j<line.length;j++)edgeMeters+=meters(line[j-1],line[j]);
    return {edgeIndex:i,coord,segmentIndex,distanceAlongM:meters(a,coord),edgeMeters,distanceM:0};
  });
  const routes=[];
  for(const start of matches) for(const end of matches) {
    if(start.edgeIndex===end.edgeIndex)continue;
    for(const customer of [false,true]) for(const [style,objective] of [["balanced","distance"],["dirt","pavement"],["cleanest","profile"],["balanced","profile"]]) {
      const options={costMode:objective,variety:false,cityWall:false,settlementFallback:false,hardCorridor:false,
        avoidMotorways:false,preferBackRoads:false,startEndpointKind:customer?"customers":null,endEndpointKind:customer?"customers":null};
      const result=findPathV2(runtime,start,end,style,{motorizedUnknown:false,motorizedPermissive:true},new Set(),1,options);
      routes.push({start,end,customer,style,objective,distance:result?.distanceMeters??null,
        edgeIDs:result?(result.segments||[]).filter(s=>s.distanceMeters>0.01).map(s=>s.edgeId):[]});
    }
  }
  fs.mkdirSync(output,{recursive:true});
  fs.writeFileSync(path.join(output,name+".graph.v4.bin"),graph);
  fs.writeFileSync(path.join(output,name+".geometry.v1.bin"),geometry);
  fs.writeFileSync(path.join(output,name+".json"),JSON.stringify({
    nodeCount:pack.nodeCount,edgeCount:pack.undirectedEdgeCount,arcCount:pack.directedArcCount,
    graphHash:sha(graph),geometryHash:sha(geometry),edges,turns,routes
  },null,2)+"\n");
  console.log(`${name}: ${turns.length} turns; ${routes.length} actual JS searches`);
}
