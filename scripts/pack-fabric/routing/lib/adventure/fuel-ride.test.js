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
