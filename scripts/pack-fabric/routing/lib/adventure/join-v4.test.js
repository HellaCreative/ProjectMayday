"use strict";
const test=require('node:test'),assert=require('node:assert/strict');
const {buildGraphFromOsm}=require('../legal-topology/osm-graph'),{encodeFromOsmGraph,decodeGraphV4}=require('../pack-v4'),{decodeGeometryV1}=require('../pack-v2');
const {joinV4}=require('./join-v4'),{createBudget}=require('./budget'),{createV4Graph}=require('./v4-graph');
function region(id,nodes,ways){const e=encodeFromOsmGraph(buildGraphFromOsm({nodes,ways}),{regionId:id,sourceEpoch:'shared'});return {pack:decodeGraphV4(e.graphBuffer,e.geomBuffer),geom:decodeGeometryV1(e.geomBuffer)};}
const nodes=[{id:1,lon:-64,lat:46},{id:2,lon:-63.99,lat:46},{id:3,lon:-63.98,lat:46},{id:4,lon:-63.97,lat:46}];
const way=(id,a,b)=>({id,nodeIds:[a,b],tags:{highway:'unclassified',surface:'gravel',access:'yes'}});
const budget=()=>createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:100000});
function fixtures(){return [region('ns',nodes.slice(0,3),[way(10,1,2),way(20,2,3)]),region('nb',nodes.slice(1),[way(20,2,3),way(30,3,4)])];}
test('join collapses exact overlapping roads and retains shared source geometry',()=>{
 const parts=fixtures(),r=joinV4(parts,{budget:budget()});assert.equal(r.pack.nodeCount,4);assert.equal(r.pack.edgeCount,3);assert.equal(r.diagnostics.sharedNodes,2);assert.equal(r.diagnostics.duplicateEdges,1);
 assert.equal(r.edgeMaps[0][1],r.edgeMaps[1][0]);assert.deepEqual(r.geom.polyline(r.edgeMaps[1][1]),parts[1].geom.polyline(1));
});
test('turn restriction from first pack remains enforced onto second pack road',()=>{
 const parts=fixtures();parts[1].pack.restrictions=[{fromEdge:0,toEdge:1,viaNode:parts[1].pack.edgeTo[0],only:false,viaEdges:[]}];
 const r=joinV4(parts,{budget:budget()}),g=createV4Graph(r.pack);
 const incoming=r.edgeMaps[0][1],outgoing=r.edgeMaps[1][1],a=r.pack.edgeFrom[incoming],b=r.pack.edgeTo[incoming],c=r.pack.edgeTo[outgoing];
 const turn=g.transition(0,{id:incoming,from:a,to:b});assert.equal(turn.allowed,true);assert.equal(g.transition(turn.state,{id:outgoing,from:b,to:c}).allowed,false);
});
test('same coordinates with different OSM IDs do not connect packs',()=>{
 const parts=fixtures();const shifted=nodes.slice(1).map(n=>({...n,id:n.id+100}));parts[1]=region('nb',shifted,[way(20,102,103),way(30,103,104)]);
 assert.throws(()=>joinV4(parts,{budget:budget()}),/no shared source nodes/);
});
test('source mismatch and conflicting shared-node coordinates are rejected',()=>{
 let parts=fixtures();parts[1].pack.provenance.sourceEpoch='other';assert.throws(()=>joinV4(parts,{budget:budget()}),/incompatible/);
 parts=fixtures();parts[1].pack.nodeCoords[0]+=.01;assert.throws(()=>joinV4(parts,{budget:budget()}),/coordinate mismatch/);
});
test('join honours work cancellation',()=>{assert.throws(()=>joinV4(fixtures(),{budget:createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:1})}),/V4 join/);});
test('cross-region search carries fuel without refilling at the boundary',()=>{
 const {searchResourcePath}=require('./resource-search');const parts=fixtures(),r=joinV4(parts,{budget:budget()}),g=createV4Graph(r.pack);
 const start=r.pack.osmNodeIds.indexOf('1'),end=r.pack.osmNodeIds.indexOf('4'),distance=[...r.pack.edgeMeters].reduce((a,b)=>a+b,0);
 const options={graph:g,start,end,edgeCost:a=>a.distanceMeters};
 const result=searchResourcePath({...options,budget:budget(),fuel:{usableRangeMeters:distance,initialUsableMeters:distance/2}});
 assert.notEqual(result.state,'found');
 const complete=searchResourcePath({...options,budget:budget(),fuel:{usableRangeMeters:distance+1,initialUsableMeters:distance+1}});
 assert.equal(complete.state,'found');assert.ok(Math.abs(complete.distanceMeters-distance)<1e-6);
});

test('three-region chain retains intermediate graph and boundary restrictions',()=>{
 const n=[...nodes,{id:5,lon:-63.96,lat:46}];
 const parts=[region('a',n.slice(0,2),[way(10,1,2)]),region('b',n.slice(1,4),[way(20,2,3),way(30,3,4)]),region('c',n.slice(3),[way(40,4,5)])];
 parts[1].pack.restrictions=[{fromEdge:0,toEdge:1,viaNode:parts[1].pack.edgeTo[0],only:false,viaEdges:[]}];
 const r=joinV4(parts,{budget:budget()}),g=createV4Graph(r.pack);
 assert.equal(r.pack.nodeCount,5);assert.equal(r.pack.edgeCount,4);
 const incoming=r.edgeMaps[1][0],outgoing=r.edgeMaps[1][1];
 const turn=g.transition(0,{id:incoming,from:r.pack.edgeFrom[incoming],to:r.pack.edgeTo[incoming]});
 assert.equal(turn.allowed,true);
 assert.equal(g.transition(turn.state,{id:outgoing,from:r.pack.edgeFrom[outgoing],to:r.pack.edgeTo[outgoing]}).allowed,false);
 assert.equal(r.pack.regionIds.length,3);
});
test('repeated region cannot be joined twice',()=>{
 const parts=fixtures();assert.throws(()=>joinV4([parts[0],parts[0]],{budget:budget()}),/Duplicate source region/);
});

test('lazy identities retain canonical names and every overlapping source alias',()=>{
 const parts=fixtures(),r=joinV4(parts,{budget:budget()});
 for(let regionIndex=0;regionIndex<parts.length;regionIndex++){
  const source=parts[regionIndex].pack;
  for(let edge=0;edge<source.edgeCount;edge++){
   const joined=r.edgeMaps[regionIndex][edge];
   assert.ok(r.pack.edgeAliases(joined).includes(source.edgeId(edge)));
   const a=r.pack.osmNodeIds[r.pack.edgeFrom[joined]],b=r.pack.osmNodeIds[r.pack.edgeTo[joined]];
   assert.equal(r.pack.edgeId(joined),`${source.osmWayIds[edge]}:${a}:${b}#${joined}`);
  }
 }
});

test('compact joined geometry index matches materialized source geometry at a seam',()=>{
 const joined=joinV4(fixtures(),{budget:budget()});
 const {buildEdgeIndex}=require('./station-matching');
 const compact=buildEdgeIndex(joined.pack,joined.geom,budget());
 const materialized=buildEdgeIndex(joined.pack,{polyline:e=>joined.geom.polyline(e)},budget());
 for(const point of [{lat:46,lon:-63.99},{lat:46,lon:-63.98},{lat:46.1,lon:-63.98}])
  assert.deepEqual(compact.query(point,500),materialized.query(point,500));
 for(let e=0;e<joined.pack.edgeCount;e++){
  const range=joined.geom.coordinateRange(e);
  assert.deepEqual(Array.from(range.coords.subarray(range.start,range.end)),joined.geom.polyline(e).flat());
 }
});

for(const highIds of [false,true])test('packed joined node identities preserve topology, aliases and restrictions; high IDs '+highIds,()=>{
 const parts=fixtures();
 if(highIds)for(const row of parts)row.pack.osmNodeIds=Array.from({length:row.pack.nodeCount},(_,i)=>String(9007199254740990n+BigInt(row.pack.osmNodeIds[i])));
 parts[1].pack.restrictions=[{fromEdge:0,toEdge:1,viaNode:parts[1].pack.edgeTo[0],only:false,viaEdges:[]}];
 const a=joinV4(parts,{budget:budget()}),b=joinV4(parts,{budget:budget(),compactNodes:true});
 for(const field of ['nodeCoords','nodeOffsets','edgeTargets','edgeUndirectedIndex','edgeFrom','edgeTo','edgeMeters','edgeAccess','edgeSurfaceLeaf','edgeRoadClassLeaf'])assert.deepEqual(a.pack[field],b.pack[field],field);
 assert.deepEqual(a.pack.restrictions,b.pack.restrictions);assert.deepEqual(a.nodeMaps,b.nodeMaps);assert.deepEqual(a.edgeMaps,b.edgeMaps);
 assert.deepEqual(Array.from({length:b.pack.nodeCount},(_,i)=>b.pack.osmNodeIds[i]),a.pack.osmNodeIds);
 for(let e=0;e<a.pack.edgeCount;e++){assert.equal(a.pack.edgeId(e),b.pack.edgeId(e));assert.deepEqual(a.pack.edgeAliases(e),b.pack.edgeAliases(e));}
 const g=createV4Graph(b.pack),incoming=b.edgeMaps[0][1],outgoing=b.edgeMaps[1][1];
 const turn=g.transition(0,{id:incoming,from:b.pack.edgeFrom[incoming],to:b.pack.edgeTo[incoming]});
 assert.equal(g.transition(turn.state,{id:outgoing,from:b.pack.edgeFrom[outgoing],to:b.pack.edgeTo[outgoing]}).allowed,false);
 assert.throws(()=>joinV4(parts,{compactNodes:true,budget:createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:1})}),/V4 join/);
});
