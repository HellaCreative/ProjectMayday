"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {normalizeRequest}=require("./contracts");
const {proveFuel}=require("./fuel-proof");
const {searchFuelRide}=require("./fuel-ride");
const {selectCandidate}=require("./select-candidate");
const {summarizeSurface}=require("./surface");
const {createBudget}=require("./budget");
const budget=(maxExpansions=1000,signal)=>createBudget({deadlineAtMs:Date.now()+10000,maxExpansions,signal});
const input=()=>({mode:"from_here",anchors:[{id:"a",lat:44,lon:-63},{id:"b",lat:45,lon:-64}],legs:[{from:"a",to:"b",profile:"dirt"}]});
const candidate=id=>({id,legal:true,admissible:true,segments:[{distanceMeters:1,surfaceLeaf:"gravel"}],visits:[]});
const fuel={usableRangeMeters:10,initialUsableMeters:10};
function proof(initialUsableMeters){return proveFuel({...fuel,initialUsableMeters,segments:[],visits:[],budget:budget(),destinationEscape:{state:"verified",stationId:"pump",distanceMeters:0}});}
const graph={stateKey:node=>String(node),outgoing:()=>[],transition:()=>({allowed:true,state:null}),stationAt:()=>({id:"pump"})};
test("station and generation identities reject objects instead of storing mutable or invented IDs",()=>{
  const a=input();a.anchors[1].stationId={name:"pump"};assert.throws(()=>normalizeRequest(a),/station/i);
  const b=input();b.generationId={seed:1};assert.throws(()=>normalizeRequest(b),/generation/i);
});
test("holes and null entries cannot silently omit fixed waypoints or primary legs",()=>{
  for(const field of ["anchors","legs"])for(const hole of [false,true]) {
    const value=input();if(hole)delete value[field][0];else value[field][0]=null;
    assert.throws(()=>normalizeRequest(value),TypeError);
  }
});
test("malformed fuel settings are not silently treated as fuel not requested",()=>{
  for(const value of [false,0,"",[]])assert.throws(()=>normalizeRequest({...input(),fuel:value}),TypeError);
});
test("nonfinite or nonnumeric starting fuel is a data error rather than an unknown estimate",()=>{
  for(const value of [NaN,Infinity,-Infinity,"10",{},-1,11]) {
    assert.throws(()=>proof(value),TypeError);
    assert.throws(()=>searchFuelRide({graph,start:0,end:0,edgeCost:a=>a.distanceMeters,fuel:{...fuel,initialUsableMeters:value},budget:budget()}),TypeError);
  }
});
test("an absent starting estimate stays unknown and never turns into a full tank",()=>{
  for(const value of [null,undefined]) {
    assert.equal(proof(value).reason,"initial_fuel_unknown");
    assert.equal(searchFuelRide({graph,start:0,end:0,edgeCost:a=>a.distanceMeters,fuel:{...fuel,initialUsableMeters:value},budget:budget()}).fuel.reason,"initial_fuel_unknown");
  }
});
test("aggregate distance overflow is invalid data, not a fuel gap or NaN surface report",()=>{
  const segments=[{distanceMeters:Number.MAX_VALUE,surfaceLeaf:"gravel"},{distanceMeters:Number.MAX_VALUE,surfaceLeaf:"asphalt"}];
  assert.throws(()=>summarizeSurface(segments),/distance/i);
  assert.throws(()=>proveFuel({...fuel,segments,visits:[],budget:budget()}),/distance/i);
});
test("partial candidate evaluation retains a completed road and admits the search is unfinished",()=>{
  const result=selectCandidate({profile:"dirt",candidates:[candidate("ready"),candidate("not-evaluated")],budget:budget(2)});
  assert.equal(result.road.state,"complete");assert.equal(result.road.candidate.id,"ready");
  assert.equal(result.search.state,"incomplete");assert.equal(result.search.reason,"expansion_limit");
  assert.equal(result.evaluated.length,1);
});
test("interrupted fuel proof retains the completed road without claiming fuel verification",()=>{
  const result=selectCandidate({profile:"dirt",candidates:[candidate("road")],fuel,budget:budget(2)});
  assert.equal(result.road.state,"complete");assert.equal(result.fuel.state,"unverified");
  assert.equal(result.fuel.reason,"expansion_limit");
});
test("empty or unproved candidate pools do not claim geographic disconnection",()=>{
  for(const candidates of [[],[{...candidate("illegal"),legal:false}],[{...candidate("unqualified"),admissible:false}]]) {
    const result=selectCandidate({profile:"dirt",candidates,budget:budget()});
    assert.equal(result.road.state,"unverified");assert.equal(result.fuel.reason,"no_candidate");
    assert.equal(result.search.state,"candidate_pool_evaluated");
  }
});
test("cancelled selection does not start work or select an unexamined candidate",()=>{
  const controller=new AbortController();controller.abort();
  const result=selectCandidate({profile:"dirt",candidates:[candidate("unexamined")],budget:budget(100,controller.signal)});
  assert.equal(result.road.state,"unverified");assert.equal(result.search.reason,"cancelled");assert.equal(result.evaluated.length,0);
});

test("invalid fuel is rejected before road search or candidate evaluation starts",()=>{
  for(const value of [false,0,"",[],{usableRangeMeters:Infinity,initialUsableMeters:0},{usableRangeMeters:10,initialUsableMeters:NaN}]) {
    const work=budget();
    assert.throws(()=>searchFuelRide({graph,start:0,end:0,edgeCost:a=>a.distanceMeters,fuel:value,budget:work}),TypeError);
    assert.equal(work.snapshot().expansions,0);
    assert.throws(()=>selectCandidate({profile:"dirt",candidates:[],fuel:value,budget:work}),TypeError);
    assert.equal(work.snapshot().expansions,0);
  }
});
test("valid string and numeric station identities normalize without changing fixed coordinates",()=>{
  for(const id of ["osm-way-123",123]) {
    const value=input();value.anchors[1].stationId=id;value.generationId="generation-1";
    const result=normalizeRequest(value);
    assert.equal(result.anchors[1].stationId,String(id));assert.equal(result.generationId,"generation-1");
    assert.equal(result.anchors[1].lat,45);assert.equal(result.anchors[1].lon,-64);
  }
});
