"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {createPreparationCache}=require("./preparation-cache");
const {createBudget}=require("./budget");
const budget=(limit=1000,signal)=>createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:limit,signal});
function fixture(){let reads=0;return {pack:{edgeCount:1,edgeMeters:[100]},geom:{polyline(){reads++;return [[0,0],[.01,0]];}},revision:"graph-hash/geometry-hash",areas:[],reads:()=>reads};}
test("repeat requests reuse exact preparation without rescanning geometry",()=>{
  const cache=createPreparationCache(),f=fixture();
  const cold=cache.prepare({...f,budget:budget()});assert.equal(cold.cacheHit,false);
  const reads=f.reads(),work=budget(1),warm=cache.prepare({...f,budget:work});
  assert.equal(warm.cacheHit,true);assert.equal(warm.prepared,cold.prepared);
  assert.equal(f.reads(),reads);assert.equal(work.snapshot().expansions,0);
});
test("revision, graph instance, geometry instance and urban bounds invalidate reuse",()=>{
  for(const change of [f=>({revision:"new-hash"}),f=>({pack:{...f.pack}}),f=>({geom:{...f.geom}}),
    f=>({areas:[{minLon:0,maxLon:.005,minLat:-.001,maxLat:.001}]})]) {
    const cache=createPreparationCache(),f=fixture();cache.prepare({...f,budget:budget()});
    const next=cache.prepare({...f,...change(f),budget:budget()});
    assert.equal(next.cacheHit,false);assert.equal(next.state,"complete");
  }
});
test("incomplete preparation cannot poison later requests or evict completed data",()=>{
  const cache=createPreparationCache(),a=fixture(),b=fixture();
  cache.prepare({...a,budget:budget()});
  assert.equal(cache.prepare({...b,budget:budget(1)}).state,"incomplete");
  assert.equal(cache.prepare({...a,budget:budget()}).cacheHit,true);
  assert.equal(cache.prepare({...b,budget:budget()}).cacheHit,false);
});
test("bounded eviction and explicit unloading release cached references",()=>{
  const cache=createPreparationCache(),a=fixture(),b=fixture();
  cache.prepare({...a,budget:budget()});cache.prepare({...b,budget:budget()});
  assert.equal(cache.diagnostics().entries,1);
  assert.equal(cache.prepare({...a,budget:budget()}).cacheHit,false);
  cache.clear();assert.equal(cache.diagnostics().entries,0);
});
test("cancellation remains terminal even when prepared data is already cached",()=>{
  const cache=createPreparationCache(),f=fixture();cache.prepare({...f,budget:budget()});
  const controller=new AbortController();controller.abort();
  assert.equal(cache.prepare({...f,budget:budget(1,controller.signal)}).reason,"cancelled");
  assert.throws(()=>cache.prepare({...f,revision:"",budget:budget()}),/revision/);
});
