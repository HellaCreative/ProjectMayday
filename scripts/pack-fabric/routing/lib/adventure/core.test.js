"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {createBudget}=require("./budget");
const {summarizeSurface,compareSurface}=require("./surface");
const {proveFuel}=require("./fuel-proof");
const {selectCandidate}=require("./select-candidate");
const {normalizeRequest}=require("./contracts");
const budget=()=>createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:10000});
const segments=(dirt,paved,unknown=0)=>[
  {distanceMeters:dirt,surfaceLeaf:"gravel"},{distanceMeters:paved,surfaceLeaf:"asphalt"},
  {distanceMeters:unknown,surfaceLeaf:null}];
const candidate=(id,dirt,paved,extra={})=>({id,legal:true,admissible:true,segments:segments(dirt,paved),visits:[],...extra});
const visit=(id,at,refuel=false)=>({id,atMeters:at,refuel,...(refuel?{stationId:id,legalStationVisit:true}:{})});
const escape=meters=>({state:"verified",stationId:"escape",distanceMeters:meters});
function prove(extra={}) {return proveFuel({segments:segments(200000,0),visits:[],usableRangeMeters:240000,
  initialUsableMeters:240000,destinationEscape:escape(20000),budget:budget(),...extra});}

test("R01/R02 one candidate pool makes Dirt seek more dirt while Balanced stays near half",()=>{
  const candidates=[candidate("balanced",48000,52000),candidate("more-dirt",65000,35000)];
  assert.equal(selectCandidate({profile:"dirt",candidates,budget:budget()}).road.candidate.id,"more-dirt");
  assert.equal(selectCandidate({profile:"balanced",candidates,budget:budget()}).road.candidate.id,"balanced");
});
test("unknown surface cannot inflate Dirt or satisfy Balanced's pavement half",()=>{
  const unknown=summarizeSurface(segments(50000,0,50000));
  assert.equal(unknown.knownDirtPercent,50);
  assert.equal(unknown.pavedPercent,0);
  assert.equal(unknown.unknownSurfacePercent,50);
  assert.ok(compareSurface("balanced",summarizeSurface(segments(50000,50000)),unknown)<0);
});
test("Balanced prefers the dirt side only at an equivalent miss",()=>{
  assert.ok(compareSurface("balanced",summarizeSurface(segments(55,45)),summarizeSurface(segments(45,55)))<0);
  assert.ok(compareSurface("balanced",summarizeSurface(segments(48,52)),summarizeSurface(segments(65,35)))<0);
});
test("surface stats conserve distance including access and unknown",()=>{
  const summary=summarizeSurface([{surfaceLeaf:"ground",distanceMeters:120},{surfaceLeaf:"compacted",distanceMeters:80},
    {surfaceLeaf:"asphalt",distanceMeters:200},{surfaceLeaf:"mystery",distanceMeters:100}]);
  assert.equal(summary.distanceMeters,500);
  assert.equal(summary.knownDirtMeters,200);
  assert.equal(summary.longestDirtRunMeters,200);
  assert.equal(summary.knownDirtPercent+summary.pavedPercent+summary.unknownSurfacePercent,100);
});
test("R10 early refill preserves a long dirt section without a 75% gate",()=>{
  const proof=prove({segments:segments(360000,0),visits:[visit("early",140000,true)]});
  assert.equal(proof.state,"verified");
  assert.equal(proof.arrivals[0].arrivalUsableMeters,100000);
  assert.equal(proof.arrivalUsableMeters,20000);
});
test("R11 nearby generated and fixed fuel stations both refill",()=>{
  const proof=prove({segments:segments(260000,0),visits:[visit("generated",230000,true),visit("rider-fuel",240000,true)]});
  assert.equal(proof.state,"verified");
  assert.deepEqual(proof.arrivals.map(v=>v.departureUsableMeters),[240000,240000]);
});
test("R12 ordinary campsite does not refill and actual escape distance is enforced",()=>{
  const proof=prove({visits:[visit("camp",200000)],destinationEscape:escape(50000)});
  assert.equal(proof.state,"gap_on_candidate");
  assert.equal(proof.reason,"destination_escape_unreachable");
  assert.equal(proof.shortfallMeters,10000);
});
test("missing escape or unproved station visit cannot claim fuel verification",()=>{
  assert.equal(prove({destinationEscape:null}).reason,"destination_escape_unproved");
  assert.equal(prove({visits:[{id:"map-pump",atMeters:100000,refuel:true,stationId:"map-pump"}]}).reason,"station_visit_unproved");
});
test("unknown initial fuel is explicit, not silently a full tank",()=>{
  assert.equal(prove({initialUsableMeters:null}).reason,"initial_fuel_unknown");
});
test("a refill just beyond range cannot cure an unreachable approach",()=>{
  const proof=prove({segments:segments(260000,0),visits:[visit("too-late",250000,true)]});
  assert.equal(proof.reason,"unreachable_visit");
  assert.equal(proof.shortfallMeters,10000);
});
test("zero-distance refill at destination supports a zero-distance escape",()=>{
  assert.equal(prove({visits:[visit("destination-pump",200000,true)],destinationEscape:escape(0)}).state,"verified");
});
test("R14 failed fuel proof retains the selected complete road route",()=>{
  const result=selectCandidate({profile:"dirt",candidates:[candidate("ride",300000,0,{destinationEscape:escape(0)})],
    fuel:{usableRangeMeters:240000,initialUsableMeters:240000},budget:budget()});
  assert.equal(result.road.state,"complete");
  assert.equal(result.fuel.state,"gap_on_candidate");
  assert.notEqual(result.fuel.state,"no_fuel_in_geography");
});
test("a verified candidate wins over an infeasible higher-dirt ride",()=>{
  const result=selectCandidate({profile:"dirt",candidates:[candidate("impossible",300000,0,{destinationEscape:escape(0)}),
    candidate("feasible",150000,50000,{destinationEscape:escape(10000)})],
    fuel:{usableRangeMeters:240000,initialUsableMeters:240000},budget:budget()});
  assert.equal(result.road.candidate.id,"feasible");
  assert.equal(result.fuel.state,"verified");
});
test("deadline is shared and terminal, never restarted by another phase",()=>{
  let now=0;
  const work=createBudget({deadlineAtMs:10,maxExpansions:5,now:()=>now});
  assert.equal(work.consume(),true);
  now=10;
  assert.equal(work.consume(),false);
  now=0;
  assert.equal(work.check(),false);
  assert.equal(work.snapshot().reason,"deadline");
});
test("fuel proof observes cancellation and resource exhaustion",()=>{
  const controller=new AbortController();controller.abort();
  assert.equal(prove({budget:createBudget({deadlineAtMs:Date.now()+1000,maxExpansions:100,signal:controller.signal})}).reason,"cancelled");
  assert.equal(prove({budget:createBudget({deadlineAtMs:Date.now()+1000,maxExpansions:1})}).reason,"expansion_limit");
});
test("ordered visits and valid distances are mandatory",()=>{
  assert.throws(()=>prove({visits:[visit("a",120000),visit("b",100000)]}),/Unordered/);
  assert.throws(()=>summarizeSurface([{distanceMeters:-1}]),/Invalid/);
});
test("contract preserves primary ownership and does not invent initial fuel",()=>{
  const request=normalizeRequest({mode:"plan",anchors:[{id:"a",lat:1,lon:1},{id:"b",lat:2,lon:2,stationId:"pump"}],
    legs:[{from:"a",to:"b",profile:"dirt"}],fuel:{fullRangeMeters:300000,reserveFraction:.1}});
  assert.equal(request.fuel.usableRangeMeters,270000);
  assert.equal(request.fuel.initialUsableMeters,null);
  assert.equal(request.anchors[1].stationId,"pump");
  assert.equal(Object.isFrozen(request.legs[0]),true);
});
test("Loop has original return anchor, approximate target and mandatory first fuel",()=>{
  const request=normalizeRequest({mode:"loop",anchors:[{id:"camp",lat:1,lon:1}],profile:"dirt",
    loop:{direction:"NE",target:{kind:"distance",value:200000}},fuel:{fullRangeMeters:300000,reserveFraction:.1}});
  assert.equal(request.legs[0].from,request.legs[0].to);
  assert.equal(request.loop.firstStop,"fuel");
  assert.equal(request.loop.target.approximate,true);
});
test("generated fuel cannot masquerade as a fixed rider anchor",()=>{
  assert.throws(()=>normalizeRequest({mode:"from_here",anchors:[{id:"a",lat:1,lon:1},{id:"f",kind:"fuel",lat:2,lon:2}],
    legs:[{from:"a",to:"f",profile:"dirt"}]}),/Generated fuel/);
});

test('optional refinement timeout preserves the parent budget and charges its work',()=>{
 const {createBudget,createRefinementBudget}=require('./budget');let now=0;
 const parent=createBudget({deadlineAtMs:1000,maxExpansions:3,now:()=>now});
 const child=createRefinementBudget(parent,{maxMilliseconds:100,now:()=>now});
 assert.equal(child.consume(),true);assert.equal(parent.snapshot().expansions,1);
 now=100;assert.equal(child.check(),false);assert.equal(child.snapshot().reason,'refinement_deadline');
 assert.equal(parent.check(),true);assert.equal(parent.consume(),true);assert.equal(parent.consume(),true);assert.equal(parent.consume(),false);
 assert.equal(parent.snapshot().reason,'expansion_limit');
});
