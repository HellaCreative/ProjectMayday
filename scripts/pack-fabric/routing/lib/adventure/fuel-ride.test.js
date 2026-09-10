"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {searchFuelRide}=require("./fuel-ride");
const {createBudget}=require("./budget");
function graph(rows,pumps=[],transition=()=>({allowed:true,state:null}),key=node=>String(node)) {
  const arcs=rows.map(([from,to,distanceMeters],id)=>({id,from,to,distanceMeters}));
  return {outgoing:node=>arcs.filter(a=>a.from===node),stationAt:node=>pumps.includes(node)?{id:`pump-${node}`}:null,
    transition,stateKey:key};
}
function ride(g,extra={}) {return searchFuelRide({graph:g,start:"A",end:"D",edgeCost:a=>a.distanceMeters,
  budget:createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:10000}),fuel:{usableRangeMeters:10,initialUsableMeters:7},...extra});}
test("camp arrival includes legal road escape, not merely enough fuel to get to camp",()=>{
  const g=graph([["A","D",6],["A","P",3],["P","D",4],["D","Q",4]],["P","Q"]);
  const result=ride(g);
  assert.equal(result.fuel.state,"verified_on_supplied_station_access");
  assert.deepEqual(result.road.arcs.map(a=>a.to),["P","D"]);
  assert.equal(result.fuel.arrivalUsableMeters,6);
  assert.equal(result.fuel.destinationEscape.distanceMeters,4);
  assert.equal(result.fuel.destinationEscape.stationId,"pump-Q");
});
test("road remains available when mapped fuel access cannot support the ride",()=>{
  const result=ride(graph([["A","D",12]]));
  assert.equal(result.road.state,"found");
  assert.equal(result.road.distanceMeters,12);
  assert.equal(result.fuel.state,"unverified");
  assert.equal(result.fuel.reason,"no_feasible_chain_in_matched_graph");
});
test("escape cannot ignore a turn restriction on arrival at the campsite",()=>{
  const g=graph([["A","D",1],["D","P",1]],["P"],(state,a)=>({allowed:!(state===0&&a.id===1),state:a.id}),(node,state)=>`${node}:${state}`);
  assert.equal(ride(g).fuel.state,"unverified");
});
test("a fuel destination supports zero-distance escape after a needed planned refill",()=>{
  const result=ride(graph([["A","D",6]],["D"]));
  assert.equal(result.fuel.state,"verified_on_supplied_station_access");
  assert.equal(result.fuel.destinationEscape.distanceMeters,0);
  assert.equal(result.fuel.arrivalUsableMeters,1);
  assert.equal(result.fuel.departureUsableMeters,10);
  assert.deepEqual(result.fuel.plannedRefills,[{stationId:"pump-D",atMeters:6}]);
});
test("fuel work exhaustion preserves the completed road without restarting its budget",()=>{
  const result=ride(graph([["A","D",6],["D","P",4]],["P"]),{
    budget:createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:3})});
  assert.equal(result.road.state,"found");
  assert.equal(result.fuel.state,"unverified");
  assert.equal(result.fuel.reason,"expansion_limit");
});
test("unknown starting fuel retains the road and does not claim a full tank",()=>{
  const result=ride(graph([["A","D",6]],["D"]),{fuel:{usableRangeMeters:10,initialUsableMeters:null}});
  assert.equal(result.road.state,"found");
  assert.equal(result.fuel.reason,"initial_fuel_unknown");
});

test("integrated fuel planning prefers rural pumps even when the urban pump is nearer",()=>{
  const g=graph([["A","U",1],["U","D",1],["A","R",3],["R","D",3],["D","Q",1]],["U","R","Q"]);
  const result=ride(g,{fuel:{usableRangeMeters:8,initialUsableMeters:3},avoidanceCost:a=>a.to==="U"?1:0});
  assert.equal(result.fuel.state,"verified_on_supplied_station_access");
  assert.deepEqual(result.road.arcs.map(a=>a.to),["R","D"]);
  assert.deepEqual(result.road.visits,[{stationId:"pump-R",atMeters:3}]);
});
test("necessary urban fuel access is allowed without erasing a legal complete ride",()=>{
  const g=graph([["A","U",2],["U","D",4],["A","R",4],["R","D",4],["D","Q",1]],["U","Q"]);
  const result=ride(g,{fuel:{usableRangeMeters:8,initialUsableMeters:3},avoidanceCost:a=>a.to==="U"?2:0});
  assert.equal(result.fuel.state,"verified_on_supplied_station_access");
  assert.deepEqual(result.road.arcs.map(a=>a.to),["U","D"]);
  assert.equal(result.road.avoidanceCost,2);
});

test('fuel refinement rebuilds an exit-and-rejoin route with the same fuel and escape constraints',()=>{
 const arcs=[{id:0,from:'A',to:'J',distanceMeters:2},{id:1,from:'J',to:'K',distanceMeters:10},
 {id:2,from:'K',to:'P',distanceMeters:1},{id:3,from:'P',to:'X',distanceMeters:.1},
 {id:4,from:'X',to:'K',distanceMeters:.1},{id:1,from:'K',to:'J',distanceMeters:10},
 {id:5,from:'J',to:'D',distanceMeters:18},{id:6,from:'A',to:'P',distanceMeters:8},
 {id:7,from:'D',to:'Q',distanceMeters:1}];
 const g={outgoing:n=>arcs.filter(a=>a.from===n),stateKey:n=>n,transition:()=>({allowed:true,state:null}),stationAt:n=>['P','Q'].includes(n)?{id:n}:null};
 const result=ride(g,{edgeCost:a=>a.distanceMeters*(a.id===6?8:1),fuel:{initialUsableMeters:19,usableRangeMeters:40},preferOnwardFuel:true,retainFuelApproach:true});
 assert.equal(result.fuel.state,'verified_on_supplied_station_access');
 assert.deepEqual(result.road.arcs.map(a=>a.to),['P','X','K','J','D']);
 assert.deepEqual(result.road.diagnostics.approachRefinement,{state:'found',reason:null,beforeMeters:10,afterMeters:0,accepted:true});
 assert.equal(result.fuel.destinationEscape.distanceMeters,1);
 assert.ok(result.fuel.arrivalUsableMeters>=1);
});
test('an onward fuel route does not pay for an unnecessary history refinement',()=>{
 const result=ride(graph([['A','P',3],['P','D',4],['D','Q',4]],['P','Q']),{preferOnwardFuel:true,retainFuelApproach:true});
 assert.equal(result.fuel.state,'verified_on_supplied_station_access');
 assert.equal(result.road.diagnostics.approachRefinement,undefined);
});

test('fuel-first continuation preserves the proved ride while avoiding a redundant road search',()=>{
 const g=graph([['A','P',3],['P','D',4],['D','Q',4]],['P','Q']);
 const baseline=ride(g),continuation=ride(g,{fuelFirst:true});
 assert.deepEqual(continuation.road.arcs,baseline.road.arcs);
 assert.deepEqual(continuation.fuel,baseline.fuel);
 assert.ok(continuation.search.expansions<baseline.search.expansions);
 const gap=ride(graph([['A','D',12]]),{fuelFirst:true});
 assert.equal(gap.road.state,'found');assert.equal(gap.fuel.state,'unverified');
});

test('opt-in zero-refill advisory matches feasible objective and proves directional escape',()=>{
 const g=graph([['A','D',4],['A','X',3],['X','D',3],['D','P',2]],['P']);
 const baseline=ride(g),fast=ride(g,{allowZeroRefillAdvisory:true});
 assert.deepEqual(fast.road.arcs,baseline.road.arcs);
 assert.deepEqual(fast.fuel,baseline.fuel);
 assert.equal(fast.road.diagnostics.zeroRefillAdvisory,true);
 const restricted=graph([['A','D',1],['D','P',1]],['P'],(state,a)=>({allowed:!(state===0&&a.id===1),state:a.id}),(n,s)=>`${n}:${s}`);
 assert.equal(ride(restricted,{allowZeroRefillAdvisory:true}).fuel.state,'unverified');
});
test('opt-in shortcut falls through when initial fuel cannot cover legal escape',()=>{
 const g=graph([['A','D',6],['A','P',3],['P','D',4],['D','Q',4]],['P','Q']);
 const baseline=ride(g),fast=ride(g,{allowZeroRefillAdvisory:true});
 assert.deepEqual(fast.road.arcs,baseline.road.arcs);assert.deepEqual(fast.fuel,baseline.fuel);
 assert.equal(fast.road.diagnostics.zeroRefillAdvisory,undefined);
});

test('zero-refill proof preserves urban priority and surface objective with passing pumps',()=>{
 const g=graph([['A','D',2],['A','P',2],['P','X',1],['X','D',2],['D','Q',1]],['P','Q']);
 const args={fuel:{usableRangeMeters:20,initialUsableMeters:12},avoidanceCost:a=>a.id===0?2:0,edgeCost:a=>a.distanceMeters*(a.id===2?0.2:1),fuelFirst:true,preferOnwardFuel:true};
 const exact=ride(g,args),proved=ride(g,{...args,allowZeroRefillAdvisory:true});
 assert.deepEqual(proved.road.arcs,exact.road.arcs);
 assert.equal(proved.road.avoidanceCost,0);assert.equal(proved.road.cost,exact.road.cost);
 assert.deepEqual(proved.road.visits,[]);assert.equal(proved.fuel.arrivalUsableMeters,7);
 assert.equal(proved.road.diagnostics.zeroRefillProof,'minimum-objective-zero-retrace-with-legal-escape');
});

test('passing refill candidate proves multiple tanks without changing the road',()=>{
 const g=graph([['A','P',6],['P','R',8],['R','D',7],['D','Q',2]],['P','R','Q']);
 const result=ride(g,{fuelFirst:true,allowPassingRefillAdvisory:true});
 assert.equal(result.fuel.state,'verified_on_supplied_station_access');
 assert.deepEqual(result.road.arcs.map(a=>a.to),['P','R','D']);
 assert.deepEqual(result.road.visits.map(v=>[v.stationId,v.atMeters]),[['pump-P',6],['pump-R',14]]);
 assert.equal(result.fuel.arrivalUsableMeters,3);
 assert.equal(result.fuel.destinationEscape.distanceMeters,2);
 assert.equal(result.road.diagnostics.passingRefillAdvisory,true);
});
test('passing candidate skips unnecessary pumps and retains projected-access evidence',()=>{
 const g=graph([['A','P',2],['P','R',4],['R','D',4],['D','Q',2]],['P','R','Q']);
 g.stationAt=n=>['P','R','Q'].includes(n)?{id:n,accessEvidence:'legal_road_projection'}:null;
 const result=ride(g,{allowPassingRefillAdvisory:true});
 assert.deepEqual(result.road.visits,[{stationId:'R',atMeters:6,accessEvidence:'legal_road_projection'}]);
 assert.equal(result.fuel.state,'provisional_station_access');
});
test('passing candidate falls back to integrated search when a detour is required',()=>{
 const g=graph([['A','D',6],['A','P',3],['P','D',4],['D','Q',4]],['P','Q']);
 const result=ride(g,{allowPassingRefillAdvisory:true});
 assert.deepEqual(result.road.arcs.map(a=>a.to),['P','D']);
 assert.equal(result.road.diagnostics.passingRefillAdvisory,undefined);
 assert.equal(result.fuel.state,'verified_on_supplied_station_access');
});
test('passing candidate cannot spend reserve or bypass arrival turn restrictions',()=>{
 const g=graph([['A','P',7.01],['P','D',2],['D','Q',1]],['P','Q']);
 assert.equal(ride(g,{allowPassingRefillAdvisory:true}).fuel.state,'unverified');
 const restricted=graph([['A','P',3],['P','D',4],['D','Q',1]],['P','Q'],(s,a)=>({allowed:!(s===1&&a.id===2),state:a.id}),(n,s)=>`${n}:${s}`);
 assert.equal(ride(restricted,{allowPassingRefillAdvisory:true}).fuel.state,'unverified');
});
test('passing candidate supports an initially empty tank at a mapped starting pump',()=>{
 const g=graph([['A','D',6],['D','Q',2]],['A','Q']);
 const result=ride(g,{fuel:{usableRangeMeters:10,initialUsableMeters:0},allowPassingRefillAdvisory:true});
 assert.equal(result.fuel.state,'verified_on_supplied_station_access');
 assert.deepEqual(result.road.visits,[{stationId:'pump-A',atMeters:0}]);
});
