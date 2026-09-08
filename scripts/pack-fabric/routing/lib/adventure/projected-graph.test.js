"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {buildGraphFromOsm}=require("../legal-topology/osm-graph");
const {encodeFromOsmGraph,decodeGraphV4}=require("../pack-v4");
const {createProjectedGraph}=require("./projected-graph");
const {searchResourcePath}=require("./resource-search");
const {createBudget}=require("./budget");
const budget=()=>createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:10000});
function pack(oneway=false){
  const encoded=encodeFromOsmGraph(buildGraphFromOsm({nodes:[{id:1,lon:0,lat:0},{id:2,lon:.01,lat:0}],
    ways:[{id:10,nodeIds:[1,2],tags:{highway:"service",surface:"gravel",access:"yes",...(oneway?{oneway:"yes"}:{})}}]}),{regionId:"fixture",sourceEpoch:"fixed"});
  return decodeGraphV4(encoded.graphBuffer,encoded.geomBuffer);
}
function route(graph,start="a",end="b",extra={}){
  return searchResourcePath({graph,start:graph.pointNodes.get(start),end:graph.pointNodes.get(end),
    edgeCost:a=>a.distanceMeters,budget:budget(),...extra});
}
test("same-edge projections use only the distance between the selected points",()=>{
  const p=pack(),graph=createProjectedGraph(p,{points:[{id:"a",edgeIndex:0,fraction:.2},{id:"b",edgeIndex:0,fraction:.7}],budget:budget()});
  const result=route(graph);
  assert.equal(result.state,"found");
  assert.ok(Math.abs(result.distanceMeters-p.edgeMeters[0]*.5)<1e-8);
  assert.equal(result.arcs.length,1);
});
test("one-way road cannot be reversed by inserting endpoint projections",()=>{
  const graph=createProjectedGraph(pack(true),{points:[{id:"a",edgeIndex:0,fraction:.7},{id:"b",edgeIndex:0,fraction:.2}],budget:budget()});
  assert.equal(route(graph).state,"exhausted");
});
test("a projected station can refuel without leaving or resetting road direction",()=>{
  const p=pack(),graph=createProjectedGraph(p,{points:[{id:"a",edgeIndex:0,fraction:.1},
    {id:"pump",edgeIndex:0,fraction:.4,station:{id:"real-pump",accessEvidence:"verified"}},
    {id:"b",edgeIndex:0,fraction:.9}],budget:budget()});
  const result=route(graph,"a","b",{fuel:{usableRangeMeters:p.edgeMeters[0]*.6,initialUsableMeters:p.edgeMeters[0]*.4}});
  assert.equal(result.state,"found");
  assert.equal(result.visits[0].stationId,"real-pump");
  assert.ok(Math.abs(result.distanceMeters-p.edgeMeters[0]*.8)<1e-8);
});
test("projection cannot create a turnaround halfway through a road",()=>{
  const graph=createProjectedGraph(pack(),{points:[{id:"a",edgeIndex:0,fraction:.2},{id:"pump",edgeIndex:0,fraction:.4},{id:"b",edgeIndex:0,fraction:.7}],budget:budget()});
  const start=graph.pointNodes.get("a"),pump=graph.pointNodes.get("pump");
  const into=[...graph.outgoing(start)].find(arc=>arc.to===pump);
  const state=graph.transition(null,into);
  const reverse=[...graph.outgoing(pump)].find(arc=>arc.to===start);
  assert.equal(graph.transition(state.state,reverse).allowed,false);
});
test("unverified nearby pump cannot become a fuel reset",()=>{
  assert.throws(()=>createProjectedGraph(pack(),{points:[{id:"pump",edgeIndex:0,fraction:.4,station:{id:"poi"}}],budget:budget()}),/evidence/);
});
test("identical positions share the road node, never connect different edges",()=>{
  const graph=createProjectedGraph(pack(),{points:[{id:"a",edgeIndex:0,fraction:.2},{id:"b",edgeIndex:0,fraction:.2}],budget:budget()});
  assert.equal(graph.pointNodes.get("a"),graph.pointNodes.get("b"));
  assert.equal(route(graph).distanceMeters,0);
});
test("split pieces preserve the restriction at the real next junction",()=>{
  const p=pack();
  // A prohibited reversal at the far endpoint must survive traversing a
  // midpoint projection. Use the actual pack edge and a resolved restriction.
  p.restrictions=[{fromEdge:0,toEdge:0,viaNode:p.edgeTo[0],only:false}];
  const graph=createProjectedGraph(p,{points:[{id:"a",edgeIndex:0,fraction:.2},{id:"middle",edgeIndex:0,fraction:.6}],budget:budget()});
  let node=graph.pointNodes.get("a"),state=null;
  while(node!==p.edgeTo[0]) {
    const arc=[...graph.outgoing(node)].find(arc=>arc.toFraction>arc.fromFraction);
    const result=graph.transition(state,arc);assert.equal(result.allowed,true);state=result.state;node=arc.to;
  }
  const back=[...graph.outgoing(node)][0];
  assert.equal(graph.transition(state,back).allowed,false);
});
test("coincident projected coordinates do not join disconnected roads",()=>{
  const encoded=encodeFromOsmGraph(buildGraphFromOsm({
    nodes:[{id:1,lon:0,lat:0},{id:2,lon:.01,lat:0},{id:3,lon:.005,lat:-.005},{id:4,lon:.005,lat:.005}],
    ways:[{id:10,nodeIds:[1,2],tags:{highway:"service",access:"yes"}},{id:20,nodeIds:[3,4],tags:{highway:"service",access:"yes"}}]
  }),{regionId:"fixture",sourceEpoch:"fixed"});
  const p=decodeGraphV4(encoded.graphBuffer,encoded.geomBuffer);
  const graph=createProjectedGraph(p,{points:[{id:"a",edgeIndex:0,fraction:.5},{id:"b",edgeIndex:1,fraction:.5}],budget:budget()});
  assert.notEqual(graph.pointNodes.get("a"),graph.pointNodes.get("b"));
  assert.equal(route(graph).state,"exhausted");
});
test("splitting a via-way preserves path history but does not invent history at an interior start",()=>{
  const encoded=encodeFromOsmGraph(buildGraphFromOsm({
    nodes:[{id:1,lon:0,lat:0},{id:2,lon:.01,lat:0},{id:3,lon:.02,lat:0},{id:4,lon:.03,lat:0}],
    ways:[{id:10,nodeIds:[1,2],tags:{highway:"service",access:"yes",oneway:"yes"}},
      {id:20,nodeIds:[2,3],tags:{highway:"service",access:"yes",oneway:"yes"}},
      {id:30,nodeIds:[3,4],tags:{highway:"service",access:"yes",oneway:"yes"}}]
  }),{regionId:"fixture",sourceEpoch:"fixed"});
  const p=decodeGraphV4(encoded.graphBuffer,encoded.geomBuffer);
  p.restrictions=[{fromEdge:0,viaEdges:[1],toEdge:2,only:false}];
  const graph=createProjectedGraph(p,{points:[{id:"a",edgeIndex:0,fraction:.2},{id:"middle",edgeIndex:1,fraction:.5},
    {id:"b",edgeIndex:2,fraction:.8}],budget:budget()});
  assert.equal(route(graph).state,"exhausted");
  assert.equal(route(graph,"middle","b").state,"found");
});
