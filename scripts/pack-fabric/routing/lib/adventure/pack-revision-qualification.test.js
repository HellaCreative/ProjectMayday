"use strict";
const {test}=require("node:test"),assert=require("node:assert/strict");
const {qualifiedPack,nbSupplement}=require("./pack-revision-qualification");
const revisions=require("./verified-pack-revisions.json");
test("new revisions require exact graph, geometry and fuel identities",()=>{
  const identity={regionId:"nb",releaseId:"fabric-v4-20260909-01",...revisions["fabric-v4-20260909-01"].nb};
  assert(qualifiedPack(identity));
  for(const key of ["regionId","releaseId","graphSha256","geometrySha256","fuelSha256"])assert(!qualifiedPack({...identity,[key]:"wrong"}));
  assert(!qualifiedPack({releaseId:"fabric-v4-20260908-02"}));
});
test("accepted NB boxes are applied once for both source versions",()=>{
  const cores=[{name:"reviewed"}];
  assert.deepEqual(nbSupplement([{regionId:"nb",releaseId:"fabric-v4-20260908-02"}],cores),cores);
  assert.deepEqual(nbSupplement([{regionId:"nb",releaseId:"fabric-v4-20260909-01"}],cores),[]);
  assert.deepEqual(nbSupplement([{regionId:"ns",releaseId:"fabric-v4-20260908-02"}],cores),[]);
});

test("accepted older Atlantic revision also requires exact manifest identities",()=>{
 for(const regionId of ["ns","nb"]) {
  const identity={regionId,releaseId:"fabric-v4-20260908-02",...revisions["fabric-v4-20260908-02"][regionId]};
  assert(qualifiedPack(identity));
  for(const key of ["regionId","releaseId","graphSha256","geometrySha256","fuelSha256"]) {
   assert(!qualifiedPack({...identity,[key]:"wrong"}));
   const missing={...identity};delete missing[key];assert(!qualifiedPack(missing));
  }
 }
 assert(!qualifiedPack(null));assert(!qualifiedPack(undefined));
});
