"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {v4TransitionState}=require("./find-path-v2");
const turn={transition:()=>99};
function attempt(code,{unknown=false,start=-1,end=-1,startKind=null,endKind=null}={}) {
  const pack={graphBinaryVersion:4,edgeFrom:[0],edgeTo:[1],edgeAccess:[code,2]};
  return v4TransitionState(pack,turn,0,0,0,1,start,end,startKind,endKind,unknown);
}
test("V4 directional unknown, denied and invalid codes never inherit aggregate permissive access",()=>{
  assert.equal(attempt(0),99);
  assert.equal(attempt(1),-1);
  assert.equal(attempt(1,{unknown:true}),99);
  for(const code of [2,5,6,255])assert.equal(attempt(code,{unknown:true,start:0,end:0,startKind:"customers",endKind:"customers"}),-1);
});
test("V4 endpoint/customer access remains scoped to the correct endpoint purpose",()=>{
  assert.equal(attempt(3),-1);
  assert.equal(attempt(3,{end:0}),99);
  assert.equal(attempt(3,{end:0,endKind:"customers"}),-1);
  assert.equal(attempt(4),-1);
  assert.equal(attempt(4,{end:0}),-1);
  assert.equal(attempt(4,{end:0,endKind:"customers"}),99);
  assert.equal(attempt(4,{start:0,startKind:"customers"}),99);
});
