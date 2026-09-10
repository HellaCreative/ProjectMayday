"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {buildGraphFromOsm}=require("./osm-graph"),{encodeFromOsmGraph,decodeGraphV4}=require("../pack-v4");
const way=(id,nodeIds)=>({id,nodeIds,tags:{highway:"residential",motorcycle:"yes",surface:"asphalt"}});
const node=(id,lon,lat=0)=>({id,lon,lat,tags:{}});
const relation=(to,kind="only_straight_on")=>({id:"99",tags:{type:"restriction",restriction:kind},members:[{type:"way",ref:"10",role:"from"},{type:"way",ref:"10",role:"via"},{type:"way",ref:to,role:"to"}]});
test("repeated entire approach way resolves at its final junction, not earlier splits",()=>{
 const graph=buildGraphFromOsm({nodes:[node("1",0),node("2",1),node("3",2),node("4",3),node("5",1,1)],ways:[way("10",["1","2","3"]),way("20",["3","4"]),way("30",["2","5"])],relations:[relation("20")]});
 assert.equal(graph.restrictions.length,1);const r=graph.restrictions[0];
 assert.equal(graph.nodes[r.viaNode].osmNodeId,"3");assert.deepEqual(r.viaEdges,[]);
 assert.equal(graph.nodes[graph.edges[r.fromEdge].from].osmNodeId,"2");
 const encoded=encodeFromOsmGraph(graph,{regionId:"test"});
 const decoded=decodeGraphV4(encoded.graphBuffer,encoded.geomBuffer);
 assert.equal(decoded.provenance.restrictionRepairs[0].relation.id,"99");
});
test("ambiguous all-role source quarantines only its own way and retains original evidence",()=>{
 const graph=buildGraphFromOsm({nodes:[node("1",0),node("2",1),node("3",2)],ways:[way("10",["1","2"]),way("20",["2","3"])],relations:[relation("10","no_u_turn")]});
 assert.equal(graph.restrictions.length,0);assert.equal(graph.restrictionRepairs[0].type,"quarantine");
 assert(graph.restrictionRepairs[0].originalRows.length>0);
 assert.deepEqual(graph.edges.filter(e=>e.osmWayId==="10").map(e=>[e.accessForward,e.accessReverse]),[[2,2]]);
 assert.deepEqual(graph.edges.filter(e=>e.osmWayId==="20").map(e=>[e.accessForward,e.accessReverse]),[[0,0]]);
});
test("left-turn normalization preserves opposite approach right turn",()=>{
 const graph=buildGraphFromOsm({nodes:[node("1",0),node("2",1),node("3",2),node("4",1,1)],ways:[way("10",["1","2","3"]),way("20",["2","4"])],relations:[relation("20","no_left_turn")]});
 assert.equal(graph.restrictions.length,1);const r=graph.restrictions[0];
 assert.equal(graph.nodes[graph.edges[r.fromEdge].from].osmNodeId,"1");
 assert.equal(graph.nodes[graph.edges[r.fromEdge].to].osmNodeId,"2");
});
