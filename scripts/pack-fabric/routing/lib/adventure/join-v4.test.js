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
