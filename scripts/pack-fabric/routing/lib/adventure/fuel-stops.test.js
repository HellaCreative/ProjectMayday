"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {searchFuelRide}=require("./fuel-ride");
const {proveFuel}=require("./fuel-proof");
const {createBudget}=require("./budget");
const budget=()=>createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:10000});
function graph(rows,pumps=[],transition=()=>({allowed:true,state:null}),stateKey=node=>String(node)) {
  const arcs=rows.map(([from,to,distanceMeters],id)=>({id,from,to,distanceMeters}));
  return {outgoing:node=>arcs.filter(a=>a.from===node),stationAt:node=>pumps.includes(node)?{id:`pump-${node}`}:null,transition,stateKey};
}
const fuel={usableRangeMeters:10,initialUsableMeters:10},edgeCost=a=>a.distanceMeters;
const ride=(g,start,end,extra={})=>searchFuelRide({graph:g,start,end,edgeCost,fuel,budget:budget(),...extra});
function proofOf(ride,extra={}) {
  return proveFuel({...fuel,segments:ride.road.arcs,visits:ride.road.visits.map((v,i)=>({...v,id:`fuel-${i}`,refuel:true,legalStationVisit:true})),
    destinationEscape:{state:"verified",...ride.fuel.destinationEscape},budget:budget(),...extra});
}
test("fixed fuel destination reports arrival fuel separately from the planned full departure",()=>{
  const result=ride(graph([[0,1,6]],[1]),0,1),proof=proofOf(result);
  assert.equal(result.fuel.arrivalUsableMeters,4);
  assert.equal(proof.arrivalUsableMeters,result.fuel.arrivalUsableMeters);
  assert.equal(proof.departureUsableMeters,result.fuel.departureUsableMeters);
  assert.equal(proof.escapeUsableMeters,10);
});
test("a necessary generated pump shortly before a fixed fuel destination keeps both refills",()=>{
  const g=graph([[0,1,9],[1,2,2]],[1,2]),result=ride(g,0,2);
  assert.equal(result.fuel.state,"verified_on_supplied_station_access");
  assert.deepEqual(result.road.visits,[{stationId:"pump-1",atMeters:9},{stationId:"pump-2",atMeters:11}]);
  const proof=proofOf(result);assert.equal(proof.state,"verified");
  assert.deepEqual(proof.arrivals.map(a=>a.arrivalUsableMeters),[1,8]);
});
test("an ordinary waypoint carries fuel into the following search without a phantom refill",()=>{
  const g=graph([[0,1,4],[1,2,2],[2,3,4],[1,3,5],[3,4,2]],[2,4]);
  const first=ride(g,0,1,{fuel:{...fuel,initialUsableMeters:7}});
  assert.equal(first.fuel.departureUsableMeters,3);assert.deepEqual(first.road.visits,[]);
  const second=ride(g,1,3,{initialTurnState:first.road.endTurnState,fuel:{...fuel,initialUsableMeters:first.fuel.departureUsableMeters}});
  assert.deepEqual(second.road.arcs.map(a=>a.to),[2,3]);
  assert.deepEqual(second.road.visits,[{stationId:"pump-2",atMeters:2}]);
});
test("a fixed station waypoint supplies a full planned tank to the following search",()=>{
  const g=graph([[0,1,8],[1,2,6],[2,3,2]],[1,3]);
  const first=ride(g,0,1);
  assert.equal(first.fuel.arrivalUsableMeters,2);assert.equal(first.fuel.departureUsableMeters,10);
  const second=ride(g,1,2,{initialTurnState:first.road.endTurnState,fuel:{...fuel,initialUsableMeters:first.fuel.departureUsableMeters}});
  assert.equal(second.fuel.state,"verified_on_supplied_station_access");
});
test("passing a station marker without a planned visit cannot refill final proof",()=>{
  const result=proveFuel({...fuel,segments:[{distanceMeters:12}],visits:[{id:"passed",atMeters:4,stationId:"pump",legalStationVisit:true,refuel:false}],
    destinationEscape:{state:"verified",stationId:"next",distanceMeters:0},budget:budget()});
  assert.equal(result.state,"gap_on_candidate");assert.equal(result.reason,"destination_unreachable");
  assert.equal(result.arrivals[0].departureUsableMeters,6);
});
test("zero-distance station destination preserves the actual starting estimate on arrival",()=>{
  const result=ride(graph([],[0]),0,0,{fuel:{...fuel,initialUsableMeters:3}});
  assert.equal(result.fuel.arrivalUsableMeters,3);assert.equal(result.fuel.departureUsableMeters,10);
  assert.equal(result.road.visits.length,1);
  const proof=proofOf(result,{initialUsableMeters:3});
  assert.equal(proof.arrivalUsableMeters,3);assert.equal(proof.departureUsableMeters,10);
});
test("a full tank at a fuel destination still has one explicit planned refill",()=>{
  const result=ride(graph([],[0]),0,0);
  assert.deepEqual(result.road.visits,[{stationId:"pump-0",atMeters:0}]);
  assert.equal(result.fuel.arrivalUsableMeters,10);assert.equal(result.fuel.departureUsableMeters,10);
});
test("turn history survives an ordinary waypoint between separate searches",()=>{
  const g=graph([[0,1,2],[1,2,2],[1,3,1]],[3],(state,a)=>({allowed:!(state===0&&a.id===1),state:a.id}),(node,state)=>`${node}:${state}`);
  const first=ride(g,0,1);assert.equal(first.fuel.state,"verified_on_supplied_station_access");
  const second=ride(g,1,2,{initialTurnState:first.road.endTurnState,fuel:{...fuel,initialUsableMeters:first.fuel.departureUsableMeters}});
  assert.equal(second.road.state,"exhausted");
});

test("unverified onward escape still distinguishes arrival from planned departure fuel",()=>{
  const result=ride(graph([[0,1,6]],[1]),0,1);
  const proof=proofOf(result,{destinationEscape:null});
  assert.equal(proof.state,"unverified");assert.equal(proof.reason,"destination_escape_unproved");
  assert.equal(proof.arrivalUsableMeters,4);assert.equal(proof.departureUsableMeters,10);
});
test("even a destination refill cannot prove an exit beyond full usable range",()=>{
  const result=ride(graph([[0,1,6]],[1]),0,1);
  const proof=proofOf(result,{destinationEscape:{state:"verified",stationId:"next",distanceMeters:11}});
  assert.equal(proof.state,"gap_on_candidate");assert.equal(proof.shortfallMeters,1);
  assert.equal(proof.arrivalUsableMeters,4);assert.equal(proof.departureUsableMeters,10);
});
