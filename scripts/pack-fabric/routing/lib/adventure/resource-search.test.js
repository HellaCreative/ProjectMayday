"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {searchResourcePath,buildLowerBounds}=require("./resource-search");
const {createBudget}=require("./budget");
const budget=(limit=10000)=>createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:limit});
function graph(rows,stations=[],transition=()=>({allowed:true,state:null}),stateKey=node=>String(node)){
  const arcs=rows.map(([from,to,distanceMeters],id)=>({from,to,distanceMeters,id}));
  return {outgoing:node=>arcs.filter(a=>a.from===node),transition,stateKey,
    stationAt:node=>stations.includes(node)?{id:`pump-${node}`}:null};
}
function search(g,extra={}){return searchResourcePath({graph:g,start:"A",end:"D",edgeCost:a=>a.distanceMeters,budget:budget(),...extra});}
test("fuel participates in search: early refill permits a path that shortest arrival cannot",()=>{
  const g=graph([["A","B",4],["A","P",3],["P","B",3],["B","D",4]],["P"]);
  const result=search(g,{fuel:{usableRangeMeters:8,initialUsableMeters:5}});
  assert.equal(result.state,"found");
  assert.deepEqual(result.arcs.map(a=>a.to),["P","B","D"]);
  assert.deepEqual(result.visits,[{stationId:"pump-P",atMeters:3}]);
  assert.equal(result.remainingUsableMeters,1);
});
test("cheaper low-fuel arrival does not dominate a feasible higher-fuel arrival",()=>{
  const g=graph([["A","B",2],["A","P",2],["P","B",2],["B","D",4]],["P"]);
  assert.equal(search(g,{fuel:{usableRangeMeters:8,initialUsableMeters:4}}).state,"found");
});
test("necessary fuel access may return along the same stem",()=>{
  const g=graph([["A","J",3],["J","P",1],["P","J",1],["J","D",5]],["P"]);
  const result=search(g,{fuel:{usableRangeMeters:8,initialUsableMeters:5}});
  assert.equal(result.state,"found");
  assert.deepEqual(result.arcs.map(a=>a.to),["J","P","J","D"]);
});
test("nonnegative search doesn't add gratuitous cycles when fuel isn't needed",()=>{
  const g=graph([["A","J",1],["J","C",1],["C","J",1],["J","D",1]]);
  assert.deepEqual(search(g).arcs.map(a=>a.to),["J","D"]);
});
test("destination escape can force an extra refill before arrival",()=>{
  const g=graph([["A","D",6],["A","P",4],["P","D",4]],["P"]);
  const result=search(g,{fuel:{usableRangeMeters:10,initialUsableMeters:8},destinationEscapeMeters:4});
  assert.deepEqual(result.arcs.map(a=>a.to),["P","D"]);
  assert.equal(result.remainingUsableMeters,6);
});
test("fuel refill preserves incoming turn state",()=>{
  const g=graph([["A","P",1],["P","D",1]],["P"],(state,arc)=>({allowed:!(state===0&&arc.id===1),state:arc.id}),(node,state)=>`${node}:${state}`);
  assert.equal(search(g,{fuel:{usableRangeMeters:10,initialUsableMeters:1}}).state,"exhausted");
});
test("resource exhaustion is incomplete, never disconnected or fuel gap",()=>{
  const g=graph([["A","B",1],["B","D",1]]);
  assert.equal(search(g,{budget:budget(1)}).state,"incomplete");
});
test("directed arcs cannot be traversed in reverse",()=>{
  assert.equal(search(graph([["D","A",1]])).state,"exhausted");
});
test("negative reward for dirt cannot enter the additive search",()=>{
  assert.throws(()=>search(graph([["A","D",1]]),{edgeCost:()=>-1}),/nonnegative/);
});
test("reverse bound preserves fuel-aware route and avoids irrelevant branches",()=>{
  const g=graph([[0,1,2],[0,2,2],[2,1,2],[1,3,4],[0,4,1],[4,5,1]],[2]);
  const edgeCost=a=>a.distanceMeters,work=budget();
  const bounds=buildLowerBounds({graph:g,nodeCount:6,target:3,edgeCost,budget:work});
  assert.equal(bounds.state,"complete");
  assert.equal(bounds.distances[0],6);
  const options={graph:g,start:0,end:3,edgeCost,fuel:{usableRangeMeters:8,initialUsableMeters:4}};
  const plain=searchResourcePath({...options,budget:budget()});
  const guided=searchResourcePath({...options,budget:work,lowerBounds:bounds});
  assert.equal(guided.cost,plain.cost);
  assert.deepEqual(guided.arcs.map(a=>a.to),[2,1,3]);
  assert.ok(guided.diagnostics.expanded<plain.diagnostics.expanded);
});
test("partial or mismatched lower bounds cannot turn unknown reachability into no-path",()=>{
  const g=graph([[0,1,2]]),edgeCost=a=>a.distanceMeters;
  const incomplete=buildLowerBounds({graph:g,nodeCount:2,target:1,edgeCost,budget:budget(1)});
  assert.equal(incomplete.state,"incomplete");
  assert.throws(()=>searchResourcePath({graph:g,start:0,end:1,edgeCost,budget:budget(),lowerBounds:incomplete}),/Lower bounds/);
  const complete=buildLowerBounds({graph:g,nodeCount:2,target:1,edgeCost,budget:budget()});
  assert.throws(()=>searchResourcePath({graph:g,start:0,end:1,edgeCost:a=>a.distanceMeters*2,budget:budget(),lowerBounds:complete}),/Lower bounds/);
});

test("urban shortcut never beats a feasible rural route through a finite penalty",()=>{
  const g=graph([["A","C",1],["C","D",1],["A","R",1000000],["R","D",1000000]]);
  const result=search(g,{avoidanceCost:a=>a.to==="C"?1:0});
  assert.deepEqual(result.arcs.map(a=>a.to),["R","D"]);assert.equal(result.avoidanceCost,0);
});
test("unavoidable urban passage completes and minimizes urban exposure first",()=>{
  const g=graph([["A","C",1],["C","D",1],["A","R",10],["R","D",10]]);
  const result=search(g,{avoidanceCost:a=>a.to==="C"?5:a.to==="R"?2:0});
  assert.deepEqual(result.arcs.map(a=>a.to),["R","D"]);assert.equal(result.avoidanceCost,2);
});
test("rural low-fuel arrival cannot erase an urban arrival needed for onward fuel",()=>{
  const g=graph([["A","J",3],["A","P",2],["P","J",2],["J","D",4]],["P"]);
  const result=search(g,{avoidanceCost:a=>a.to==="P"?2:0,fuel:{usableRangeMeters:8,initialUsableMeters:4}});
  assert.equal(result.state,"found");assert.deepEqual(result.arcs.map(a=>a.to),["P","J","D"]);
  assert.equal(result.avoidanceCost,2);
});
test("reverse ride-cost bound cannot make an urban shortcut win",()=>{
  const g=graph([[0,1,1],[1,3,1],[0,2,100],[2,3,100]]),edgeCost=a=>a.distanceMeters;
  const work=budget(),lowerBounds=buildLowerBounds({graph:g,nodeCount:4,target:3,edgeCost,budget:work});
  const result=searchResourcePath({graph:g,start:0,end:3,edgeCost,budget:work,lowerBounds,avoidanceCost:a=>a.to===1?1:0});
  assert.deepEqual(result.arcs.map(a=>a.to),[2,3]);
});
test("negative urban rewards and unfinished rural searches cannot claim necessary passage",()=>{
  const g=graph([["A","D",1]]);
  assert.throws(()=>search(g,{avoidanceCost:()=>-1}),/nonnegative/);
  assert.equal(search(g,{avoidanceCost:()=>1,budget:budget(1)}).state,"incomplete");
});
