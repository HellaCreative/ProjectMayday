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

test('waypoint arrival preserves node and via-way restrictions',()=>{
 const p=pack([[0,1],[1,2],[2,3],[4,1]],[{fromEdge:0,viaEdges:[1],toEdge:2,only:false}]);
 const g=createV4Graph(p);
 const state=g.seedArrival([{id:0,from:0,to:1},{id:1,from:1,to:2}]);
 assert.equal(state.allowed,true);assert.equal(g.transition(state.state,{id:2,from:2,to:3}).allowed,false);
 const other=g.seedArrival([{id:3,from:4,to:1},{id:1,from:1,to:2}]);
 assert.equal(g.transition(other.state,{id:2,from:2,to:3}).allowed,true);
 const truncated=g.seedArrival([{id:1,from:1,to:2}]);
 assert.equal(g.transition(truncated.state,{id:2,from:2,to:3}).allowed,false);
 const node=createV4Graph(pack([[0,1],[1,2]],[{fromEdge:0,toEdge:1,viaNode:1,only:false}]));
 assert.equal(node.transition(node.seedArrival([{id:0,from:0,to:1}]).state,{id:1,from:1,to:2}).allowed,false);
});

test('repeated only-turn approach with proved one-way direction enforces the unique exit',()=>{
 const p=pack([[0,1],[1,2],[1,3],[4,1]],[{osmRelationId:'16478624',fromEdge:0,viaEdges:[0],toEdge:1,viaNode:0,only:true}]);
 p.edgeAccess[1]=2;
 assert.equal(route(p,0,2).state,'found');assert.equal(route(p,0,3).state,'exhausted');
 assert.equal(route(p,4,3).state,'found');
 for(const codes of [[0,0],[0,1],[1,2],[0,5]]){
  p.edgeAccess.splice(0,2,...codes);assert.throws(()=>createV4Graph(p),/Ambiguous/);
 }
 p.edgeAccess.splice(0,2,0,2);p.restrictions[0].viaNode=1;
 assert.throws(()=>createV4Graph(p),/Ambiguous/);
});

test('repeated approach normalization refuses unproved attachment and leaves source unchanged',()=>{
 const restriction={osmRelationId:'16478624',fromEdge:0,viaEdges:[0],toEdge:1,viaNode:0,only:true,kind:4,vehicleMask:7};
 for(const edges of [[[0,0],[0,2]],[[0,1],[0,2]],[[0,1],[0,1]]]) {
  const p=pack(edges,[{...restriction}]);p.edgeAccess[1]=2;
  assert.throws(()=>createV4Graph(p),/Ambiguous/);
 }
 const p=pack([[0,1],[1,2]],[{...restriction,viaEdges:[0,0]}]);p.edgeAccess[1]=2;
 assert.throws(()=>createV4Graph(p),/Ambiguous/);
 p.restrictions=[restriction];const before=JSON.stringify(p.restrictions);createV4Graph(p);
 assert.equal(JSON.stringify(p.restrictions),before);
 const reverse=pack([[1,0],[1,2],[1,3]],[restriction]);reverse.edgeAccess.splice(0,2,2,0);
 const g=createV4Graph(reverse),arrival=g.seedArrival([{id:0,from:0,to:1}]);
 assert.equal(g.transition(arrival.state,{id:1,from:1,to:2}).allowed,true);
 assert.equal(g.transition(arrival.state,{id:2,from:1,to:3}).allowed,false);
});

test('distinct parallel via entry uses source-resolved contiguous path',()=>{
 const r={fromEdge:0,viaEdges:[1],toEdge:2,viaNode:1,only:false};
 const p=pack([[0,1],[0,1],[0,2]],[r]),g=createV4Graph(p);
 const arrival=g.seedArrival([{id:0,from:0,to:1},{id:1,from:1,to:0}]);
 assert.equal(g.transition(arrival.state,{id:2,from:0,to:2}).allowed,false);
 // Starting on the other directed arrival never begins this source sequence.
 const other=g.seedArrival([{id:0,from:1,to:0}]);
 assert.equal(g.transition(other.state,{id:2,from:0,to:2}).allowed,true);
 p.restrictions=[{...r,viaNode:0}];assert.throws(()=>createV4Graph(p),/Ambiguous/);
 p.restrictions=[{...r,viaNode:99}];assert.throws(()=>createV4Graph(p),/Ambiguous/);
});
