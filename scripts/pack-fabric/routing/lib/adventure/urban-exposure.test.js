"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {urbanAreasFromPack,buildUrbanExposure}=require("./urban-exposure");
const {createBudget}=require("./budget");
const budget=(maxExpansions=1000)=>createBudget({deadlineAtMs:Date.now()+10000,maxExpansions});
const box={minLon:1,maxLon:2,minLat:-1,maxLat:1};
function exposure(coords,areas=[box],work=budget()) {
  return buildUrbanExposure({pack:{edgeCount:1,edgeMeters:[300]},geom:{polyline:()=>coords},areas,budget:work});
}
test("rural settlements are not silently classified as major cores",()=>{
  const core={...box,name:"Metro"};const result=urbanAreasFromPack({meta:{urbanCores:[core],settlements:[{...box,name:"Village"}]}});
  assert.deepEqual(result.areas,[core]);assert.equal(result.evidence.unclassifiedSettlementCount,1);
  assert.equal(result.evidence.classificationComplete,false);
});
test("full road geometry detects a city crossing with both endpoints outside",()=>{
  const result=exposure([[0,0],[3,0]]);
  assert.equal(result.state,"complete");
  assert.ok(Math.abs(result.urbanMeters({id:0,distanceMeters:300})-100)<1e-8);
});
test("overlapping city boxes count each road metre once",()=>{
  const result=exposure([[0,0],[3,0]],[box,{...box,minLon:1.5,maxLon:2.5}]);
  assert.ok(Math.abs(result.urbanMeters({id:0,distanceMeters:300})-150)<1e-8);
});
test("partial forward and reverse traversal count only traversed urban geometry",()=>{
  const result=exposure([[0,0],[3,0]]);
  for(const [fromFraction,toFraction] of [[0,.5],[.5,0]])assert.ok(Math.abs(result.urbanMeters({id:0,distanceMeters:150,fromFraction,toFraction})-50)<1e-8);
  assert.equal(result.urbanMeters({id:0,distanceMeters:30,fromFraction:0,toFraction:.1}),0);
});
test("curved rural road does not inherit its endpoint chord's city crossing",()=>{
  const result=exposure([[0,0],[0,2],[3,2],[3,0]]);
  assert.equal(result.urbanMeters({id:0,distanceMeters:300}),0);
});
test("incomplete indexing cannot be used as complete urban evidence",()=>{
  assert.equal(exposure([[0,0],[3,0]],[box],budget(1)).state,"incomplete");
});
test("missing urban data remains explicitly unqualified",()=>{
  assert.equal(urbanAreasFromPack({}).evidence.classificationComplete,false);
  assert.throws(()=>exposure([[0,0],[3,0]],[{...box,minLon:NaN}]),/bounds/);
});

test("reused spatial index matches full geometry classification including curved crossings",()=>{
  const {buildEdgeIndex}=require("./station-matching");
  const pack={edgeCount:3,edgeMeters:[300,300,300]},lines=[[[0,0],[3,0]],[[0,0],[0,2],[3,2],[3,0]],[[5,0],[6,0]]];
  const geom={polyline:edge=>lines[edge]},work=budget(10000),index=buildEdgeIndex(pack,geom,work);
  const options={pack,geom,areas:[box]};
  const all=buildUrbanExposure({...options,budget:budget(10000)});
  const indexed=buildUrbanExposure({...options,index,budget:budget(10000)});
  for(let id=0;id<3;id++)assert.equal(indexed.urbanMeters({id,distanceMeters:300}),all.urbanMeters({id,distanceMeters:300}));
  assert.throws(()=>buildUrbanExposure({...options,pack:{...pack},index,budget:budget()}),/different graph/);
  assert.equal(buildUrbanExposure({...options,index,budget:budget(1)}).state,"incomplete");
});

test('per-edge core candidates preserve overlapping and distant core measurements',()=>{
 const {buildEdgeIndex}=require('./station-matching');
 const lines=[[[0,0],[3,0]],[[10,0],[13,0]],[[0,2],[3,2]]];
 const pack={edgeCount:3,edgeMeters:[300,300,300]},geom={polyline:i=>lines[i]};
 const areas=[box,{...box,minLon:1.5,maxLon:2.5},{...box,minLon:11,maxLon:12}];
 const index=buildEdgeIndex(pack,geom,budget(20000));
 const full=buildUrbanExposure({pack,geom,areas,budget:budget(20000)});
 const narrowed=buildUrbanExposure({pack,geom,areas,index,budget:budget(20000)});
 for(let id=0;id<3;id++)for(const [fromFraction,toFraction] of [[0,1],[.2,.8],[.8,.2]]){
  const arc={id,distanceMeters:300*Math.abs(toFraction-fromFraction),fromFraction,toFraction};
  assert.equal(narrowed.urbanMeters(arc),full.urbanMeters(arc));
 }
});
