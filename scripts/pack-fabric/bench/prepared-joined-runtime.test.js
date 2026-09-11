'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),crypto=require('node:crypto');
const {buildGraphFromOsm}=require('../routing/lib/legal-topology/osm-graph');
const {encodeFromOsmGraph,decodeGraphV4,decodeGeometryV1}=require('../routing/lib/pack-v4');
const {joinV4}=require('../routing/lib/adventure/join-v4');
const {createBudget}=require('../routing/lib/adventure/budget');
const {createV4Graph}=require('../routing/lib/adventure/v4-graph');
const {writePreparedJoined,readPreparedJoined}=require('./prepared-joined-runtime');
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
test('prepared sidecar exactly preserves joined columns, geometry, aliases, leaves and seam restriction',t=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'dirt-prepared-test-'));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
 const nodes=[{id:1,lon:-64,lat:45},{id:2,lon:-63.99,lat:45},{id:3,lon:-63.98,lat:45},{id:4,lon:-63.97,lat:45}];
 const way=(id,a,b)=>({id,nodeIds:[a,b],tags:{highway:'unclassified',surface:'gravel',access:'yes'}});
 const parts=[{id:'ns',nodes:nodes.slice(0,3),ways:[way(10,1,2),way(20,2,3)]},{id:'nb',nodes:nodes.slice(1),ways:[way(20,2,3),way(30,3,4)]}];
 const geometryPaths={},identity=[],regions=parts.map(part=>{
  const e=encodeFromOsmGraph(buildGraphFromOsm(part),{regionId:part.id,sourceEpoch:'fixed'});
  geometryPaths[part.id]=path.join(root,part.id+'.geometry');fs.writeFileSync(geometryPaths[part.id],e.geomBuffer);
  identity.push({regionId:part.id,graphSha256:hash(e.graphBuffer),geometrySha256:hash(e.geomBuffer),fuelSha256:'test'});
  return {pack:decodeGraphV4(e.graphBuffer,e.geomBuffer),geom:decodeGeometryV1(e.geomBuffer)};
 });
 regions[1].pack.restrictions=[{fromEdge:0,toEdge:1,viaNode:regions[1].pack.edgeTo[0],viaEdges:[],only:false}];
 const joined=joinV4(regions,{compactNodes:true,budget:createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:10000})});
 const folder=path.join(root,'sidecar'),receipt=writePreparedJoined(folder,{joined,regions,identity});
 const options={expectedIdentity:identity,manifestSha256:receipt.manifestSha256,geometryPaths};
 const loaded=readPreparedJoined(folder,options),a=joined.pack,b=loaded.pack;
 for(const field of Object.keys(JSON.parse(fs.readFileSync(path.join(folder,'joined-runtime.experimental.json'))).sections))if(a[field])assert.deepEqual(a[field],b[field],field);
 assert.deepEqual(a.restrictions,b.restrictions);
 for(let e=0;e<a.edgeCount;e++){assert.equal(a.edgeId(e),b.edgeId(e));assert.deepEqual(a.edgeAliases(e),b.edgeAliases(e));assert.deepEqual(a.edgeLeaves(e),b.edgeLeaves(e));assert.deepEqual(joined.geom.polyline(e),loaded.geom.polyline(e));}
 const saved=b.edgeLeaves(0);b.edgeLeaves(0).layer=999;assert.deepEqual(b.edgeLeaves(0),saved);
 const g=createV4Graph(b),incoming=joined.edgeMaps[0][1],outgoing=joined.edgeMaps[1][1];
 const state=g.transition(0,{id:incoming,from:b.edgeFrom[incoming],to:b.edgeTo[incoming]});
 assert.equal(g.transition(state.state,{id:outgoing,from:b.edgeFrom[outgoing],to:b.edgeTo[outgoing]}).allowed,false);
 assert.throws(()=>readPreparedJoined(folder,{...options,expectedIdentity:[]}),/identity/);
 const file=path.join(folder,'edgeTargets.bin'),raw=fs.readFileSync(file);raw[0]^=1;fs.writeFileSync(file,raw);
 assert.throws(()=>readPreparedJoined(folder,options),/section identity/);
});
