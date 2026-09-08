"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {customerEndpointEdges,validCustomerRuns}=require("./customer-endpoint-access");
const fs=require("node:fs"),path=require("node:path");
const {decodeGraphV4}=require("./pack-v4");
const {decodeGeometryV1}=require("./pack-v2");
const {legalSnapDetailed}=require("./legal-topology/snap");
const {findPathV2}=require("./find-path-v2");

for (const profile of ["cleanest","balanced"]) {
 test(`${profile}: real customer arrival, separate exit, and no public through shortcut`,()=>{
  const run=(from,to,startKind,endKind,blocked=false)=>{
   const base=path.join(__dirname,"../fixtures/legal-topology/legal-topology-forecourt"+(blocked?"-blocked":""));
   const pack=decodeGraphV4(fs.readFileSync(base+".graph.v4.bin"));
   const geom=decodeGeometryV1(fs.readFileSync(base+".geometry.v1.bin")); pack.geometry=geom;
   const snap=(p,kind)=>{const c=legalSnapDetailed(pack,geom,{lon:p[0],lat:p[1]},{maxMeters:80,endpointKind:kind,intentBearingDeg:270}).candidates[0];return c && {...c,ok:true,coord:[c.lon,c.lat],edgeMeters:pack.edgeMeters[c.edgeIndex]};};
   const a=snap(from,startKind),b=snap(to,endKind); assert.ok(a&&b,"exact packed endpoint snaps");
   return findPathV2({pack,geom,enums:pack.enums},a,b,profile,
    {motorizedUnknown:false,motorizedPermissive:true},new Set(),undefined,
    {costMode:"profile",pavedOnly:profile==="cleanest",variety:false,sessionSeed:0,
     startEndpointKind:startKind,endEndpointKind:endKind,boundedSearch:false});
  };
  const a=[-64.004,45],pump=[-63.99965,45.0001375],b=[-63.996,45];
  const ways=r=>[...new Set(r.segments.filter(s=>s.distanceMeters>0.5).map(s=>Number(/^w(\d+):/.exec(s.edgeId)?.[1])))];
  assert.deepEqual(ways(run(a,pump,null,"customers")),[10,20,21]);
  assert.deepEqual(ways(run(pump,b,"customers",null)),[21,22,11]);
  assert.deepEqual(ways(run(a,b,null,null)),[10,12,11]);
  assert.equal(run(a,pump,null,"customers",true),null,"restriction remains active entering the final virtual edge");
 });
}
// Public -> entrance -> pump -> rear exit, with a denied branch and a long branch.
const pack={graphBinaryVersion:4,nodeCount:6,nodeOffsets:[0,1,3,5,5,5,5],
 edgeTargets:[1,2,4,3,5],edgeUndirectedIndex:[0,1,3,2,4],
 edgeFrom:[0,1,2,1,2],edgeTo:[1,2,3,4,5],edgeMeters:[30,25,15,10,201],
 edgeAccess:[0,2,4,2,4,2,2,2,4,2]};
test("multi-edge customer entrance respects directed access and the road-distance bound",()=>{
 assert.deepEqual([...customerEndpointEdges(pack,2,[{node:2,meters:5}],true)].sort(),[1,2]);
 assert.deepEqual([...customerEndpointEdges(pack,1,[{node:2,meters:5}],false)].sort(),[1,2]);
 assert.equal(customerEndpointEdges(pack,0,[{node:1,meters:0}],false).size,0);
});
test("actual customer geometry cannot become a through shortcut or exceed 200 metres",()=>{
 const c=new Set(['c']),r=(edgeId,meters)=>({edgeId,meters});
 assert.equal(validCustomerRuns([r('road',100),r('c',25)],c,false,true),true);
 assert.equal(validCustomerRuns([r('c',25),r('road',100)],c,true,false),true);
 assert.equal(validCustomerRuns([r('road',100),r('c',25),r('road',100)],c,true,true),false);
 assert.equal(validCustomerRuns([r('road',100),r('c',201)],c,false,true),false);
 assert.equal(validCustomerRuns([r('road',100),r('c',25)],c,false,false),false);
});
