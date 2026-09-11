'use strict';
// Independent transition oracle: existing DIRT V4 graph, not OSRM's restriction machinery.
const fs=require('fs'),assert=require('node:assert/strict');
const {buildGraphFromOsm}=require('../../pack-fabric/routing/lib/legal-topology/osm-graph');
const {encodeFromOsmGraph,decodeGraphV4}=require('../../pack-fabric/routing/lib/pack-v4');
const {createV4Graph}=require('../../pack-fabric/routing/lib/adventure/v4-graph');
const root=process.argv[2],input=JSON.parse(fs.readFileSync(root+'/fixture-data.json'));
const nodes=Object.entries(input.nodes).map(([id,[lon,lat]])=>({id:+id,lon,lat}));
const ways=input.ways.map(([id,nodeIds,surface,forward,backward])=>({id,nodeIds,tags:{highway:'unclassified',surface:surface==='dirt'?'gravel':'asphalt',access:'yes',oneway:backward===2&&forward===0?'yes':'no'}}));
const b=encodeFromOsmGraph(buildGraphFromOsm({nodes,ways}),{regionId:'ns',sourceEpoch:'osrm-private-synthetic'}),pack=decodeGraphV4(b.graphBuffer,b.geomBuffer);
const edgeForWay=id=>Array.from(pack.osmWayIds).findIndex(w=>Number(w)===id);
pack.restrictions=[{fromEdge:edgeForWay(111),viaEdges:[edgeForWay(112)],toEdge:edgeForWay(113),viaNode:pack.edgeTo[edgeForWay(111)],only:false}];
for(let e=0;e<pack.edgeCount;e++) {const source=input.ways.find(w=>w[0]===Number(pack.osmWayIds[e]));pack.edgeAccess[e*2]=source[3];pack.edgeAccess[e*2+1]=source[4];}
function auditNodes(ids,allowUnknown=true){
 const graph=createV4Graph(pack,{allowUnknown});let state=0,walk=[],legal=true;
 let previousKey=null;
 for(let i=1;i<ids.length;i++){
  const source=input.ways.find(w=>w[1].some((n,j)=>j+1<w[1].length&&((n===ids[i-1]&&w[1][j+1]===ids[i])||(n===ids[i]&&w[1][j+1]===ids[i-1]))));
  assert.ok(source,'Source adjacency missing '+ids[i-1]+','+ids[i]);
  const edge=edgeForWay(source[0]),forward=source[1].indexOf(ids[i-1])<source[1].indexOf(ids[i]),key=edge*2+(forward?0:1);
  if(key===previousKey)continue;previousKey=key;
  const from=forward?pack.edgeFrom[edge]:pack.edgeTo[edge];let arc;
  graph.forEachOutgoing(from,a=>{if(a.id===edge)arc=a;});
  if(!arc){legal=false;break;}const t=graph.transition(state,arc);walk.push(arc.id);if(!t.allowed){legal=false;break;}state=t.state;
 }return {legal,walk};
}
const rows=JSON.parse(fs.readFileSync(root+'/results.json')).results,report=[];
for(const row of rows.filter(r=>r.case.startsWith('via'))){
 const legs=row.response.routes?.[0]?.legs;if(!legs)continue;
 const ids=[];for(const l of legs){const part=l.annotation.nodes;let overlap=Math.min(ids.length,part.length);while(overlap&&!ids.slice(-overlap).every((n,i)=>n===part[i]))overlap--;ids.push(...part.slice(overlap));}
 const audit=auditNodes(ids);report.push({metric:row.metric,case:row.case,nodes:ids,...audit});
 if(row.case==='via-whole')assert.equal(audit.legal,true);
}
// A direct forbidden walk is rejected; a legal detour is accepted by the same oracle.
assert.equal(auditNodes([11,12,13,14]).legal,false);
assert.equal(auditNodes([11,12,13,15,14]).legal,true);
for(const metric of [...new Set(rows.map(r=>r.metric))]){const arrival=rows.find(r=>r.metric===metric&&r.case==='via-arrive').response.routes[0].legs[0].annotation.nodes;const departure=rows.find(r=>r.metric===metric&&r.case==='via-resume').response.routes[0].legs[0].annotation.nodes;let overlap=Math.min(arrival.length,departure.length);while(overlap&&!arrival.slice(-overlap).every((n,i)=>n===departure[i]))overlap--;const ids=[...arrival,...departure.slice(overlap)];const audit=auditNodes(ids);assert.equal(audit.legal,false);report.push({metric,case:'separate-call-concatenation',nodes:ids,...audit});}
fs.writeFileSync(root+'/v4-audit.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
