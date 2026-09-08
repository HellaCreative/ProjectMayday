"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {searchResourcePath,buildLowerBounds}=require("./resource-search");
const {searchFuelRide}=require("./fuel-ride");
const {proveFuel}=require("./fuel-proof");
const {selectCandidate}=require("./select-candidate");
const {normalizeRequest}=require("./contracts");
const {createBudget}=require("./budget");
const budget=signal=>createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:10000,signal});
function graph(lengths,pumps=[]) {
  const arcs=lengths.map((distanceMeters,id)=>({id,from:id,to:id+1,distanceMeters}));
  return {outgoing:node=>arcs.filter(a=>a.from===node),stateKey:node=>String(node),
    transition:()=>({allowed:true,state:null}),stationAt:node=>pumps.includes(node)?{id:`pump-${node}`}:null};
}
const fuel={usableRangeMeters:.3,initialUsableMeters:.3},edgeCost=a=>a.distanceMeters;
test("exact decimal fuel boundary agrees between search and final proof",()=>{
  const lengths=[.1,.2],result=searchResourcePath({graph:graph(lengths),start:0,end:2,edgeCost,budget:budget(),fuel});
  const proof=proveFuel({...fuel,segments:lengths.map(distanceMeters=>({distanceMeters})),visits:[],
    destinationEscape:{state:"verified",stationId:"pump",distanceMeters:0},budget:budget()});
  assert.equal(proof.state,"verified");assert.equal(result.state,"found");assert.equal(result.remainingUsableMeters,0);
});
test("destination escape at the exact decimal fuel boundary remains reachable",()=>{
  const result=searchFuelRide({graph:graph([.1,.2],[2]),start:0,end:1,edgeCost,budget:budget(),fuel});
  assert.equal(result.fuel.state,"verified_on_supplied_station_access");
});
test("a real one-millimetre shortfall is not rounded away",()=>{
  const result=searchResourcePath({graph:graph([.1,.201]),start:0,end:2,edgeCost,budget:budget(),fuel});
  assert.equal(result.state,"exhausted");
  assert.equal(proveFuel({...fuel,segments:[{distanceMeters:.301}],visits:[],budget:budget()}).state,"gap_on_candidate");
});
test("cancelled disconnected search stays cancelled even when reverse bounds skip the start",()=>{
  const g=graph([]),lowerBounds=buildLowerBounds({graph:g,nodeCount:2,target:1,edgeCost,budget:budget()});
  const controller=new AbortController();controller.abort();
  const result=searchResourcePath({graph:g,start:0,end:1,edgeCost,lowerBounds,budget:budget(controller.signal)});
  assert.equal(result.state,"incomplete");assert.equal(result.reason,"cancelled");
});
test("zero starting fuel can refill at a supplied station, but cannot move to a nearby one",()=>{
  const options={start:0,end:1,edgeCost,fuel:{usableRangeMeters:10,initialUsableMeters:0}};
  assert.equal(searchResourcePath({...options,graph:graph([1],[0]),budget:budget()}).state,"found");
  assert.equal(searchResourcePath({...options,graph:graph([1],[1]),budget:budget()}).state,"exhausted");
});
test("candidate order cannot change Dirt, Balanced or Clean selection or mutate the pool",()=>{
  const candidates=[48,55,65,100,0].map(dirt=>({id:`ride-${dirt}`,legal:true,admissible:true,visits:[],
    segments:[{distanceMeters:dirt,surfaceLeaf:"gravel"},{distanceMeters:100-dirt,surfaceLeaf:"asphalt"}]}));
  const original=JSON.stringify(candidates);
  for(const [profile,expected] of [["dirt","ride-100"],["balanced","ride-48"],["clean","ride-0"]]) {
    for(let offset=0;offset<candidates.length;offset++) {
      const pool=candidates.slice(offset).concat(candidates.slice(0,offset));
      assert.equal(selectCandidate({profile,candidates:pool,budget:budget()}).road.candidate.id,expected);
    }
  }
  assert.equal(JSON.stringify(candidates),original);
});
test("primary-leg edits cannot alter another normalized leg or a fixed anchor",()=>{
  const input={mode:"plan",anchors:[{id:"a",lat:1,lon:1},{id:"b",lat:2,lon:2},{id:"c",lat:3,lon:3,stationId:"fuel-c"}],
    legs:[{from:"a",to:"b",profile:"dirt"},{from:"b",to:"c",profile:"clean"}]};
  const original=normalizeRequest(input);input.legs[0].profile="balanced";
  const edited=normalizeRequest(input);input.anchors[0].lat=8;
  assert.equal(original.legs[0].profile,"dirt");assert.equal(edited.legs[0].profile,"balanced");
  assert.deepEqual(original.legs[1],edited.legs[1]);assert.deepEqual(original.anchors,edited.anchors);
  assert.throws(()=>{edited.anchors[0].lat=9;},TypeError);
});
test("all eight loop bearings survive JSON storage with target and first-fuel intent",()=>{
  for(const direction of ["N","NE","E","SE","S","SW","W","NW"])for(const kind of ["distance","moving_time"]) {
    const request=normalizeRequest({mode:"loop",anchors:[{id:"home",lat:44,lon:-63}],profile:"dirt",generationId:"built-1",
      loop:{direction,target:{kind,value:100}},fuel:{fullRangeMeters:300000,reserveFraction:.1}});
    const stored=JSON.parse(JSON.stringify(request));
    assert.deepEqual(stored,request);assert.equal(stored.loop.firstStop,"fuel");
    assert.equal(stored.fuel.initialUsableMeters,null);assert.equal(stored.legs[0].from,stored.legs[0].to);
  }
});

test("cancellation at the last outgoing-road check cannot become a no-path result",()=>{
  const controller=new AbortController(),g=graph([]);
  g.outgoing=()=>{controller.abort();return [];};
  const result=searchResourcePath({graph:g,start:0,end:1,edgeCost,budget:budget(controller.signal)});
  assert.equal(result.state,"incomplete");assert.equal(result.reason,"cancelled");
});
