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
  assert.equal(search(g,{fuel:{usableRangeMeters:10,initialUsableMeters:1},preferOnwardFuel:true}).state,"exhausted");
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

test("fuel search does not schedule every passing pump when no refill is needed",()=>{
  const g=graph([["A","P",2],["P","Q",2],["Q","D",2]],["P","Q"]);
  const result=search(g,{fuel:{usableRangeMeters:10,initialUsableMeters:10}});
  assert.deepEqual(result.visits,[]);
});
test("equivalent road geometry uses only the necessary number of planned refills",()=>{
  const g=graph([["A","P",2],["P","Q",2],["Q","D",4]],["P","Q"]);
  const result=search(g,{fuel:{usableRangeMeters:6,initialUsableMeters:6}});
  assert.equal(result.visits.length,1);assert.ok(["pump-P","pump-Q"].includes(result.visits[0].stationId));
});

test("label memory guard returns incomplete with a bounded admitted label count",()=>{
  const result=search(graph([["A","B",1],["B","D",1]]),{maxLabels:1});
  assert.equal(result.state,"incomplete");assert.equal(result.reason,"label_limit");assert.equal(result.diagnostics.labels,1);
});
test('weighted candidate guidance preserves fuel feasibility and rural priority',()=>{
 const g=graph([[0,1,2],[1,3,4],[0,2,3],[2,3,4]],[2]),edgeCost=a=>a.distanceMeters;
 const lowerBounds=buildLowerBounds({graph:g,nodeCount:4,target:3,edgeCost,budget:budget()});
 const r=searchResourcePath({graph:g,start:0,end:3,edgeCost,budget:budget(),lowerBounds,heuristicWeight:2,fuel:{usableRangeMeters:5,initialUsableMeters:3}});
 assert.equal(r.state,'found');assert.deepEqual(r.arcs.map(a=>a.to),[2,3]);assert.equal(r.remainingUsableMeters,1);
 const rural=searchResourcePath({graph:g,start:0,end:3,edgeCost,budget:budget(),lowerBounds,heuristicWeight:2,avoidanceCost:a=>a.to===1?1:0});
 assert.deepEqual(rural.arcs.map(a=>a.to),[2,3]);
 assert.throws(()=>searchResourcePath({graph:g,start:0,end:3,edgeCost,budget:budget(),heuristicWeight:Infinity}),/Heuristic weight/);
});

test('fuel search prefers an onward connection when retraced dirt is priced as connecting travel',()=>{
 const rows=[['A','J',4,0,false],['J','P',2,1,false],['P','J',2,1,false],['J','D',4,2,false],['P','K',2,3,true],['K','D',2,4,false],['P','X',1,5,false],['X','P',1,5,false]];
 const arcs=rows.map(([from,to,distanceMeters,id,paved])=>({from,to,distanceMeters,id,paved}));
 const make=onward=>({outgoing:n=>arcs.filter(a=>a.from===n&&(onward||a.id!==3)),stationAt:n=>n==='P'?{id:'pump'}:null,transition:()=>({allowed:true,state:null}),stateKey:n=>n});
 const options={start:'A',end:'D',edgeCost:a=>a.distanceMeters*(a.paved?30:1),fuel:{usableRangeMeters:12,initialUsableMeters:6}};
 const before=searchResourcePath({...options,graph:make(true),budget:budget()});
 assert.deepEqual(before.arcs.map(a=>a.to),['J','P','J','D']);
 const after=searchResourcePath({...options,graph:make(true),preferOnwardFuel:true,budget:budget()});
 assert.equal(after.state,'found');assert.deepEqual(after.arcs.map(a=>a.to),['J','P','K','D']);
 assert.equal(after.remainingUsableMeters,8);assert.equal(after.visits.length,1);
 const necessary=searchResourcePath({...options,graph:make(false),preferOnwardFuel:true,budget:budget()});
 assert.equal(necessary.state,'found');assert.deepEqual(necessary.arcs.map(a=>a.to),['J','P','J','D']);
 assert.equal(necessary.remainingUsableMeters,6);
});

test("onward preference preserves incomplete search status when its label cap is reached",()=>{
 const g=graph([["A","B",1],["B","D",1]]);
 const result=search(g,{preferOnwardFuel:true,maxLabels:1});
 assert.equal(result.state,"incomplete");assert.equal(result.reason,"label_limit");
});

test('legal station exit that rejoins an earlier junction cannot hide the fuel approach retrace',()=>{
 const arcs=[
  {id:0,from:'A',to:'J',distanceMeters:2},
  {id:1,from:'J',to:'K',distanceMeters:10},
  {id:2,from:'K',to:'P',distanceMeters:1},
  {id:3,from:'P',to:'X',distanceMeters:.1},
  {id:4,from:'X',to:'K',distanceMeters:.1},
  {id:1,from:'K',to:'J',distanceMeters:10},
  {id:5,from:'J',to:'D',distanceMeters:18},
  {id:6,from:'A',to:'P',distanceMeters:8}
 ];
 const g={outgoing:n=>arcs.filter(a=>a.from===n),stateKey:n=>n,transition:()=>({allowed:true,state:null}),stationAt:n=>n==='P'?{id:'pump'}:null};
 const r=search(g,{edgeCost:a=>a.distanceMeters*(a.id===6?8:1),fuel:{initialUsableMeters:19,usableRangeMeters:40},preferOnwardFuel:true,retainFuelApproach:true});
 assert.equal(r.state,'found');assert.deepEqual(r.arcs.map(a=>a.to),['P','X','K','J','D']);assert.equal(r.retraceMeters,0);assert.equal(r.visits.length,1);
 // If the direct approach does not exist, the legal fuel detour must remain
 // available. The preference must not turn necessary access into disconnection.
 const only={...g,outgoing:n=>g.outgoing(n).filter(a=>a.id!==6)};
 const necessary=search(only,{fuel:{initialUsableMeters:19,usableRangeMeters:40},preferOnwardFuel:true,retainFuelApproach:true});
 assert.equal(necessary.state,'found');assert.equal(necessary.retraceMeters,20);
});


test('station exit rejoining the approach in the same direction also counts repetition',()=>{
 const arcs=[{id:0,from:'A',to:'J',distanceMeters:2},{id:1,from:'J',to:'K',distanceMeters:10},
 {id:2,from:'K',to:'P',distanceMeters:1},{id:3,from:'P',to:'X',distanceMeters:.1},
 {id:4,from:'X',to:'J',distanceMeters:.1},{id:5,from:'K',to:'D',distanceMeters:18},
 {id:6,from:'A',to:'P',distanceMeters:8}];
 const g={outgoing:n=>arcs.filter(a=>a.from===n),stateKey:n=>n,transition:()=>({allowed:true,state:null}),stationAt:n=>n==='P'?{id:'pump'}:null};
 const r=search(g,{edgeCost:a=>a.distanceMeters*(a.id===6?8:1),fuel:{initialUsableMeters:19,usableRangeMeters:40},preferOnwardFuel:true,retainFuelApproach:true});
 assert.equal(r.state,'found');assert.deepEqual(r.arcs.map(a=>a.to),['P','X','J','K','D']);assert.equal(r.retraceMeters,0);
});
test('unavoidable urban arrival bounds prevent exhausting rural fuel labels',()=>{
 const rows=[[0,1,1],[1,2,1],[0,3,1]];
 for(let n=3;n<40;n++)rows.push([n,n+1,1]);
 const g=graph(rows,[0]),edgeCost=a=>a.distanceMeters,avoidanceCost=a=>a.to===2?10:0;
 const options={graph:g,start:0,end:2,edgeCost,avoidanceCost,fuel:{usableRangeMeters:1000,initialUsableMeters:1000}};
 const baseline=searchResourcePath({...options,budget:budget()});
 assert.equal(searchResourcePath({...options,budget:budget(),maxLabels:20}).reason,'label_limit');
 const bounds=buildLowerBounds({graph:g,nodeCount:41,target:2,edgeCost:avoidanceCost,budget:budget(),stopAt:0});
 const result=searchResourcePath({...options,budget:budget(),maxLabels:20,avoidanceLowerBounds:bounds});
 assert.equal(result.state,'found');
 assert.deepEqual(result.arcs,baseline.arcs);
 assert.equal(result.avoidanceCost,baseline.avoidanceCost);
 assert.throws(()=>searchResourcePath({...options,budget:budget(),avoidanceLowerBounds:{...bounds,target:1}}),/Avoidance bounds/);
});

test('rural endpoint beyond a required town also needs an urban bound',()=>{
 const rows=[[0,1,1],[1,2,1],[2,3,1],[3,2,1],[0,4,1]];
 for(let n=4;n<80;n++)rows.push([n,n+1,1]);
 const g=graph(rows,[0]),edgeCost=a=>a.distanceMeters,avoidanceCost=a=>a.to===1?10:0;
 assert.ok(g.outgoing(3).every(a=>avoidanceCost(a)===0));
 const options={graph:g,start:0,end:3,edgeCost,avoidanceCost,fuel:{usableRangeMeters:1000,initialUsableMeters:1000}};
 const baseline=searchResourcePath({...options,budget:budget()});
 assert.equal(searchResourcePath({...options,budget:budget(),maxLabels:20}).reason,'label_limit');
 const bounds=buildLowerBounds({graph:g,nodeCount:81,target:3,edgeCost:avoidanceCost,budget:budget(),stopAt:0});
 const result=searchResourcePath({...options,budget:budget(),maxLabels:20,avoidanceLowerBounds:bounds});
 assert.equal(result.state,'found');assert.deepEqual(result.arcs,baseline.arcs);
 assert.equal(result.avoidanceCost,baseline.avoidanceCost);
});
