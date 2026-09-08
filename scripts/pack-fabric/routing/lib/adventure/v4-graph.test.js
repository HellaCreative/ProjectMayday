"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {createV4Graph}=require("./v4-graph");
const {searchResourcePath}=require("./resource-search");
const {createBudget}=require("./budget");
function pack(edges,restrictions=[]) {
  const n=1+Math.max(...edges.flatMap(e=>e.slice(0,2))),offsets=[0],targets=[],indexes=[];
  for(let node=0;node<n;node++){edges.forEach(([from,to],id)=>{if(from===node){targets.push(to);indexes.push(id);}});offsets.push(targets.length);}
  return {graphBinaryVersion:4,nodeCount:n,edgeFrom:edges.map(e=>e[0]),edgeTo:edges.map(e=>e[1]),
    edgeMeters:edges.map(e=>e[2]||1),edgeAccess:edges.flatMap(e=>[e[3]||0,5]),
    edgeSurfaceLeaf:edges.map(()=>1),enums:{surfaceLeafNames:["","gravel"]},
    nodeOffsets:offsets,edgeTargets:targets,edgeUndirectedIndex:indexes,restrictions};
}
function route(p,start,end,opts={}) {
  return searchResourcePath({graph:createV4Graph(p,opts),start,end,edgeCost:a=>a.distanceMeters,
    budget:createBudget({deadlineAtMs:Date.now()+1000,maxExpansions:10000})});
}
test("node turn restriction preserves alternate arrival state",()=>{
  const p=pack([[0,1],[1,3],[0,2],[2,1]],[{fromEdge:0,toEdge:1,viaNode:1,only:false}]);
  assert.deepEqual(route(p,0,3).arcs.map(a=>a.id),[2,3,1]);
});
test("via-way no restriction depends on the full incoming sequence",()=>{
  const p=pack([[0,1],[1,2],[2,3],[4,1]], [{fromEdge:0,viaEdges:[1],toEdge:2,only:false}]);
  assert.equal(route(p,0,3).state,"exhausted");
  assert.equal(route(p,4,3).state,"found");
});
test("multi-edge only restriction rejects an early departure and allows its exit",()=>{
  const p=pack([[0,1],[1,2],[2,3],[3,4],[2,5]], [{fromEdge:0,viaEdges:[1,2],toEdge:3,only:true}]);
  assert.equal(route(p,0,4).state,"found");
  assert.equal(route(p,0,5).state,"exhausted");
});
test("multiple permitted only-turn destinations form alternatives",()=>{
  const p=pack([[0,1],[1,2],[1,3]], [{fromEdge:0,toEdge:1,viaNode:1,only:true},{fromEdge:0,toEdge:2,viaNode:1,only:true}]);
  assert.equal(route(p,0,2).state,"found");assert.equal(route(p,0,3).state,"found");
});
test("unknown permission differs from prohibited travel",()=>{
  assert.equal(route(pack([[0,1,1,1]]),0,1).state,"exhausted");
  assert.equal(route(pack([[0,1,1,1]]),0,1,{allowUnknown:true}).state,"found");
  assert.equal(route(pack([[0,1,1,2]]),0,1,{allowUnknown:true}).state,"exhausted");
});
test("destination-only access is scoped to explicit endpoint edges",()=>{
  const p=pack([[0,1,1,3]]);
  assert.equal(route(p,0,1).state,"exhausted");
  assert.equal(route(p,0,1,{endpointEdges:[0]}).state,"found");
});

test("Quebec repeated approach/via edge is an actionable restriction error, never silently dropped",()=>{
  const p=pack([[0,1],[1,2]],[{osmRelationId:"7111448",fromEdge:0,viaEdges:[0],toEdge:1,viaNode:0,only:true}]);
  assert.throws(()=>createV4Graph(p),error=>{
    assert.equal(error.code,"ambiguous_via_way_entry");
    assert.deepEqual(error.details,{relationId:"7111448",fromEdge:0,viaEdge:0,sharedNodes:[0,1]});
    return true;
  });
});
