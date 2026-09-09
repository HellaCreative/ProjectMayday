"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {buildGraphFromOsm}=require("../legal-topology/osm-graph");
const {encodeFromOsmGraph,decodeGraphV4}=require("../pack-v4");
const {decodeGeometryV1}=require("../pack-v2");
const {buildFromHere}=require("./from-here");
const {createBudget}=require("./budget");
const {createPreparationCache}=require("./preparation-cache");
const {proveFuel}=require("./fuel-proof");
const {createProjectedGraph}=require("./projected-graph");
const budget=(maxExpansions=100000,signal)=>createBudget({deadlineAtMs:Date.now()+10000,maxExpansions,signal});
function fixture({oneway=false}={}) {
  const nodes=Array.from({length:5},(_,i)=>({id:i+1,lon:i*.01,lat:0}));
  const ways=Array.from({length:4},(_,i)=>({id:10+i,nodeIds:[i+1,i+2],tags:{highway:"unclassified",surface:"gravel",access:"yes",...(oneway?{oneway:"yes"}:{})}}));
  const encoded=encodeFromOsmGraph(buildGraphFromOsm({nodes,ways}),{regionId:"fixture",sourceEpoch:"fixed"});
  return {pack:decodeGraphV4(encoded.graphBuffer,encoded.geomBuffer),geom:decodeGeometryV1(encoded.geomBuffer),revision:"fixture-1",
    stations:[{id:"middle",lat:0,lon:.015,name:"Midpoint Fuel"},{id:"escape",lat:0,lon:.04,name:"Exit Fuel"}],
    edgeCost:a=>a.distanceMeters,objectiveId:"test-distance",input:{mode:"from_here",anchors:[{id:"a",lat:0,lon:0},{id:"b",lat:0,lon:.03}],
      legs:[{from:"a",to:"b",profile:"dirt"}],fuel:{fullRangeMeters:3000,reserveFraction:0,initialUsableMeters:2500}}};
}
const build=(f,extra={})=>buildFromHere({...f,budget:budget(),...extra});
test("complete encoded-map pipeline includes a supplied catalog stop and exact onward fuel proof",()=>{
  const f=fixture(),r=build(f);
  assert.equal(r.road.state,"complete");assert.equal(r.fuel.state,"provisional_station_access");
  assert.equal(r.qualityAudit.state,"complete");assert.equal(r.qualityAudit.distanceMeters,r.road.distanceMeters);
  assert.equal(r.fuel.plannedRefills.length,1);assert.equal(r.fuel.plannedRefills[0].station.id,"middle");
  assert.equal(r.fuel.plannedRefills[0].movable,true);assert.deepEqual(r.fuel.plannedRefills[0].riderAnchorIds,[]);
  assert.ok(r.fuel.escapeUsableMeters>=0);assert.ok(r.fuel.destinationEscape.distanceMeters>0);
  assert.deepEqual(r.road.geometry[0],[0,0]);assert.deepEqual(r.road.geometry.at(-1),[.03,0]);
  assert.deepEqual(r.request.anchors.map(a=>[a.lon,a.lat]),[[0,0],[.03,0]]);
});
test("no station records retains a complete road without claiming geographic scarcity",()=>{
  const r=build(fixture(),{stations:[]});assert.equal(r.road.state,"complete");
  assert.equal(r.fuel.state,"unverified");assert.equal(r.fuel.reason,"no_station_bindings");
  assert.equal(r.stationDiagnostics.sourceCount,0);
});
test("unknown initial range retains a road and does not create a full-tank fuel plan",()=>{
  const f=fixture();f.input.fuel.initialUsableMeters=null;const r=build(f);
  assert.equal(r.road.state,"complete");assert.equal(r.fuel.reason,"initial_fuel_unknown");
});
test("station source removal invalidates fuel planning even when road preparation is reused",()=>{
  const f=fixture(),preparationCache=createPreparationCache();const a=build(f,{preparationCache});
  const b=build(f,{preparationCache,stations:f.stations.filter(s=>s.id!=="middle")});
  assert.equal(a.fuel.state,"provisional_station_access");assert.equal(b.provenance.preparationCacheHit,true);
  assert.equal(b.road.state,"complete");assert.equal(b.fuel.state,"unverified");
});
test("coincident station records remain diagnostic alternatives instead of breaking graph creation",()=>{
  const f=fixture();f.stations.splice(1,0,{...f.stations[0],id:"other-record"});const r=build(f);
  assert.equal(r.road.state,"complete");assert.equal(r.stationDiagnostics.coincidentAlternatives.length,1);
  assert.equal(r.fuel.plannedRefills.length,1);
});
test("fixed fuel destination is preserved and explicitly refilled",()=>{
  const f=fixture();f.input.anchors[1]={id:"b",lat:0,lon:.04,stationId:"escape"};const r=build(f);
  assert.equal(r.road.state,"complete");assert.equal(r.fuel.plannedRefills.at(-1).stationId,"escape");
  assert.equal(r.fuel.plannedRefills.at(-1).movable,false);assert.deepEqual(r.fuel.plannedRefills.at(-1).riderAnchorIds,["b"]);
  assert.equal(r.fuel.departureUsableMeters,3000);assert.ok(Math.abs(r.road.geometry.at(-1)[0]-.04)<1e-8);assert.equal(r.request.anchors[1].lon,.04);
});
test("provisional projection is opt-in and can never masquerade as verified station access",()=>{
  const f=fixture(),point={id:"pump",edgeIndex:0,fraction:.5,station:{id:"pump",accessEvidence:"legal_road_projection"}};
  assert.throws(()=>createProjectedGraph(f.pack,{points:[point],budget:budget()}),/Station access/);
  assert.throws(()=>createProjectedGraph(f.pack,{points:[point],budget:budget(),allowProvisionalStations:"false"}),/Station access/);
  const options={usableRangeMeters:10,initialUsableMeters:1,segments:[{distanceMeters:1}],
    visits:[{id:"p",stationId:"pump",atMeters:1,refuel:true,legalStationVisit:true,accessEvidence:"legal_road_projection"}],
    destinationEscape:{state:"verified",stationId:"pump",distanceMeters:0}};
  assert.equal(proveFuel({...options,budget:budget()}).state,"unverified");
  assert.equal(proveFuel({...options,allowProvisionalStations:true,budget:budget()}).state,"provisional_station_access");
  assert.equal(proveFuel({...options,visits:[],destinationEscape:{...options.destinationEscape,accessEvidence:"legal_road_projection"},budget:budget()}).state,"unverified");
});
test("one-way reverse request cannot become legal through station projections",()=>{
  const f=fixture({oneway:true});f.input.anchors.reverse();f.input.legs=[{from:"b",to:"a",profile:"dirt"}];const r=build(f);
  assert.equal(r.road.state,"unverified");assert.equal(r.fuel.state,"unverified");
});
test("cancelled or undersized requests report incomplete preparation honestly",()=>{
  const f=fixture(),controller=new AbortController();controller.abort();
  assert.equal(build(f,{budget:budget(100,controller.signal)}).fuel.reason,"cancelled");
  assert.equal(build(f,{budget:budget(1)}).fuel.reason,"expansion_limit");
});
test("station identity cannot move a rider anchor to a distant pump",()=>{
  const f=fixture();f.input.anchors[1].stationId="escape";
  assert.throws(()=>build(f),/Fixed station anchor/);
});

test("insufficient starting fuel changes the searched road path to include a reachable pump",()=>{
  const nodes=[{id:1,lon:0,lat:0},{id:2,lon:.03,lat:0},{id:3,lon:.005,lat:.01}];
  const ways=[[1,2],[1,3],[3,2]].map((nodeIds,i)=>({id:100+i,nodeIds,tags:{highway:"unclassified",surface:"gravel",access:"yes"}}));
  const encoded=encodeFromOsmGraph(buildGraphFromOsm({nodes,ways}),{regionId:"fixture",sourceEpoch:"fixed"});
  const f=fixture();f.pack=decodeGraphV4(encoded.graphBuffer,encoded.geomBuffer);f.geom=decodeGeometryV1(encoded.geomBuffer);
  f.stations=[{id:"branch",lat:.01,lon:.005},{id:"destination",lat:0,lon:.03}];f.input.anchors[1].stationId="destination";
  f.input.fuel={fullRangeMeters:6000,reserveFraction:0,initialUsableMeters:6000};const full=build(f);
  f.input.fuel={fullRangeMeters:3000,reserveFraction:0,initialUsableMeters:2500};const low=build(f);
  assert.equal(full.fuel.state,"provisional_station_access");assert.equal(low.fuel.state,"provisional_station_access");
  assert.deepEqual(full.fuel.plannedRefills.map(v=>v.stationId),["destination"]);
  assert.deepEqual(low.fuel.plannedRefills.map(v=>v.stationId),["branch","destination"]);
  assert.ok(low.road.distanceMeters>full.road.distanceMeters);
});

test("fuel label cap preserves already materialized advisory geometry without a no-fuel claim",()=>{
  const r=build(fixture(),{maxFuelLabels:1});
  assert.equal(r.road.state,"complete");assert.ok(r.road.geometry.length>1);
  assert.equal(r.fuel.state,"unverified");assert.equal(r.fuel.reason,"label_limit");
});

test("invalid fixed station coordinates cannot produce a provisional refill",()=>{
  const f=fixture();f.input.anchors[1].stationId="escape";f.stations[1].lat=NaN;
  assert.throws(()=>build(f),/Fixed station anchor/);
});

test('reverse preparation is reused without carrying fuel state or stale stations',()=>{
 const {createReverseCostCache}=require('./reverse-cost-cache');
 const f=fixture(),reverseCostCache=createReverseCostCache(),preparationCache=createPreparationCache();
 const options={reverseCostCache,preparationCache};
 const first=build(f,options),second=build(f,options);
 assert.equal(first.provenance.reversePreparationCacheHit,false);assert.equal(second.provenance.reversePreparationCacheHit,true);
 assert.deepEqual(first.road.geometry,second.road.geometry);assert.deepEqual(first.fuel,second.fuel);
 const removed=build(f,{...options,stations:f.stations.filter(s=>s.id!=='middle')});
 assert.equal(removed.provenance.reversePreparationCacheHit,false);assert.equal(removed.fuel.state,'unverified');
 assert.equal(build(f,options).provenance.reversePreparationCacheHit,false);
 assert.equal(build(f,{...options,revision:'changed'}).provenance.reversePreparationCacheHit,false);
 assert.equal(build(f,{...options,edgeCost:a=>a.distanceMeters*2}).provenance.reversePreparationCacheHit,false);
 reverseCostCache.clear();assert.equal(reverseCostCache.diagnostics().residentBytes,0);
});
test('reverse cache capacity cannot turn incomplete preparation into no route',()=>{
 const {createReverseCostCache}=require('./reverse-cost-cache');
 const reverseCostCache=createReverseCostCache({maxBytes:1});
 const r=build(fixture(),{reverseCostCache});
 assert.equal(r.fuel.reason,'reverse_storage_limit');assert.equal(r.road.state,'unverified');
 assert.equal(reverseCostCache.diagnostics().entries,0);
});
test('moved pins and unknown-road settings invalidate reverse topology; cancellation cannot use a warm result',()=>{
 const {createReverseCostCache}=require('./reverse-cost-cache');
 const f=fixture(),reverseCostCache=createReverseCostCache(),options={reverseCostCache};
 build(f,options);
 const moved=structuredClone(f.input);moved.anchors[1].lon=.025;
 const result=build(f,{...options,input:moved});assert.equal(result.provenance.reversePreparationCacheHit,false);
 assert.equal(result.road.geometry.at(-1)[0],.025);
 assert.equal(build(f,{...options,input:moved}).provenance.reversePreparationCacheHit,true);
 moved.legs[0].allowUnknown=true;
 assert.equal(build(f,{...options,input:moved}).provenance.reversePreparationCacheHit,false);
 const cancelled=build(f,{...options,input:moved,budget:budget(100000,{aborted:true})});
 assert.equal(cancelled.fuel.reason,'cancelled');assert.equal(cancelled.road.state,'unverified');
});
test('station matching reuse preserves current metadata and rejects evidence mutation',()=>{
 const {createStationMatchCache}=require('./station-match-cache');
 const f=fixture(),stationMatchCache=createStationMatchCache(),options={stationMatchCache};
 const first=build(f,options);assert.equal(first.provenance.stationMatchingCacheHit,false);
 const renamed=f.stations.map(s=>({...s,name:'Current '+s.name}));
 const second=build(f,{...options,stations:renamed});assert.equal(second.provenance.stationMatchingCacheHit,true);
 assert.match(second.fuel.plannedRefills[0].station.name,/^Current /);
 assert.throws(()=>{second.stationDiagnostics.records[0].candidates[0].distanceM=999;},TypeError);
 assert.deepEqual(first.road.geometry,second.road.geometry);
 for(const extra of [
  {stations:f.stations.filter(s=>s.id!=='middle')},
  {stations:f.stations.map(s=>({...s,lon:s.lon+.001}))},
  {stations:[...f.stations].reverse()},
  {revision:'updated-source'},
  {stationRadiusMeters:100}
 ]){build(f,options);assert.equal(build(f,{...options,...extra}).provenance.stationMatchingCacheHit,false);}
 stationMatchCache.clear();assert.equal(stationMatchCache.diagnostics().entries,0);
});
test('station cache capacity bypasses caching without dropping stations',()=>{
 const {createStationMatchCache}=require('./station-match-cache');
 const f=fixture(),stationMatchCache=createStationMatchCache({maxStations:1});
 for(let i=0;i<2;i++){const r=build(f,{stationMatchCache});assert.equal(r.fuel.state,'provisional_station_access');assert.equal(r.provenance.stationMatchingCacheHit,false);assert.equal(r.stationDiagnostics.records.length,2);}
 assert.equal(stationMatchCache.diagnostics().entries,0);
});
test('explicit cold-preparation work allowance shares the request deadline and reports its work',()=>{
 const f=fixture(),deadlineAtMs=Date.now()+10000;
 const preparationBudget=createBudget({deadlineAtMs,maxExpansions:100000});
 const requestBudget=createBudget({deadlineAtMs,maxExpansions:100000});
 const r=build(f,{preparationBudget,budget:requestBudget});
 assert.equal(r.road.state,'complete');assert.equal(r.provenance.preparationWork.separateAllowance,true);
 assert.ok(r.provenance.preparationWork.expansions>0);
 assert.throws(()=>build(f,{preparationBudget:createBudget({deadlineAtMs:deadlineAtMs+1,maxExpansions:100000}),budget:requestBudget}),/outlive/);
 const failed=build(f,{preparationBudget:createBudget({deadlineAtMs,maxExpansions:1}),budget:createBudget({deadlineAtMs,maxExpansions:100000})});
 assert.equal(failed.stage,'preparation');assert.equal(failed.fuel.reason,'expansion_limit');assert.equal(failed.search.expansions,0);
});

test('a coarse off-road waypoint expands to the connected road without widening pump access',()=>{
 const f=fixture();f.input.anchors[1].lat=.04;
 const narrow=build(f);assert.notEqual(narrow.road.state,'complete');
 const wide=build(f,{endpointRadiusMeters:6000});
 assert.equal(wide.road.state,'complete');assert.equal(wide.fuel.state,'provisional_station_access');
 assert.ok(wide.provenance.waypointSnap.attempts>1);
 assert.ok(wide.provenance.waypointSnap.endDistanceMeters>4000);
 assert.deepEqual(wide.road.geometry.at(-1),[.03,0]);
 assert.equal(wide.fuel.plannedRefills[0].station.lat,0);
 // A distant fuel POI must not acquire a synthetic entrance from this change.
 f.stations[0].lat=.04;
 const noPump=build(f,{endpointRadiusMeters:6000});assert.equal(noPump.fuel.state,'unverified');
});

test('wider allowed radius preserves an already successful waypoint projection',()=>{
 const f=fixture(),a=build(f),b=build(f,{endpointRadiusMeters:20000});
 assert.deepEqual(b.road.geometry,a.road.geometry);assert.deepEqual(b.fuel.plannedRefills,a.fuel.plannedRefills);
 assert.equal(b.provenance.waypointSnap.attempts,1);
});

test('rider waypoint at a mapped fuel POI is not broadened into an area destination',()=>{
 const f=fixture();f.input.anchors[1].lat=.04;
 assert.equal(build(f,{endpointRadiusMeters:6000}).road.state,'complete');
 f.stations.push({id:'fixed-poi',lat:.04,lon:.03});
 const r=build(f,{endpointRadiusMeters:6000});
 assert.notEqual(r.road.state,'complete');
 assert.equal(r.provenance.waypointSnap.attempts,1);
});
