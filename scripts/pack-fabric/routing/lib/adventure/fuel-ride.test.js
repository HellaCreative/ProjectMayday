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
