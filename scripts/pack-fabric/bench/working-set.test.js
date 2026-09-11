'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),v8=require('node:v8');
const {encodeGeometry,decodeGeometryV1}=require('../routing/lib/pack-v4');
const {createBudget}=require('../routing/lib/adventure/budget');
const {buildEdgeIndex}=require('../routing/lib/adventure/station-matching');
const {buildIndexData,restoreIndex}=require('./working-set/spatial-index');
const {openGeometry}=require('./working-set/geometry');
const work=()=>createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:1000000});
function file(t,coords) {
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'dirt-working-set-'));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
 const bytes=encodeGeometry(coords.map(coords=>({coords}))),name=path.join(root,'geometry.v1.bin');fs.writeFileSync(name,bytes);return {name,bytes};
}
test('evicted geometry is reloaded exactly, including a road larger than byte cap',t=>{
 const coords=[[[0,0],[.01,0]],[[1,1],[2,2]],Array.from({length:40},(_,i)=>[i/100,i/100])];
 const {name,bytes}=file(t,coords),full=decodeGeometryV1(bytes),paged=openGeometry(name,1,32);t.after(()=>paged.close());
 for(const e of [0,1,0,2,1,2,0])assert.deepEqual(paged.polyline(e),full.polyline(e));
 assert.ok(paged.stats.peakResidentEdges<=1);assert.ok(paged.stats.peakResidentBytes<=32);
 assert.ok(paged.stats.peakReadPlusResidentBytes>=320);assert.throws(()=>paged.polyline(3),/Invalid/);
});
test('truncated, corrupt, or missing geometry throws instead of looking like no road',t=>{
 const {name,bytes}=file(t,[[[0,0],[1,1]]]);
 fs.truncateSync(name,bytes.length-1);assert.throws(()=>openGeometry(name,1),/length/);
 fs.writeFileSync(name,bytes);const paged=openGeometry(name,1);t.after(()=>paged.close());
 fs.truncateSync(name,20);assert.throws(()=>paged.polyline(0),/Truncated/);
 assert.throws(()=>openGeometry(name+'.missing',1),/ENOENT/);
});
test('persisted spatial index retains crossing roads, broad edges, poles and query order',t=>{
 const coords=[[[0,0],[.02,0]],[[.005,.008],[.015,.008]],[[.009,-.01],[.009,.01]],
   [[-179,80],[179,80]],[[0,89.99],[.01,89.99]],[[.01,0],[.01,.02]]];
 const {name,bytes}=file(t,coords),full=decodeGeometryV1(bytes),paged=openGeometry(name,1);t.after(()=>paged.close());
 const pack={edgeCount:coords.length},oracle=buildEdgeIndex(pack,full,work());
 const data=v8.deserialize(v8.serialize(buildIndexData(pack,full,work()))),index=restoreIndex(data,pack,paged);
 for(const p of [{lon:.01,lat:0},{lon:.01,lat:.008},{lon:0,lat:89.99},{lon:179.999,lat:80},{lon:-179.999,lat:80}])
   for(const r of [150,2000])assert.deepEqual(index.query(p,r),oracle.query(p,r));
 for(const box of [{minLon:0,maxLon:.03,minLat:-.01,maxLat:.02},{minLon:178,maxLon:180,minLat:79,maxLat:81}])
   assert.deepEqual(index.queryBox(box,work()),oracle.queryBox(box,work()));
 const cancelled=createBudget({deadlineAtMs:Date.now()+1000,maxExpansions:100,signal:{aborted:true}});
 assert.equal(index.queryBox({minLon:0,maxLon:1,minLat:0,maxLat:1},cancelled),null);
});
const {encodeFromOsmGraph,decodeGraphV4}=require('../routing/lib/pack-v4');
const {openGraph}=require('./working-set/demand-graph');
const {createV4Graph}=require('../routing/lib/adventure/v4-graph');
test('disk topology matches all decoded columns, exact IDs, access and turns after eviction',t=>{
 const root=fs.mkdtempSync(path.join(os.tmpdir(),'dirt-demand-'));t.after(()=>fs.rmSync(root,{recursive:true,force:true}));
 const nodes=Array.from({length:602},(_,i)=>({osmNodeId:String(9007199254740993n+BigInt(i)),lon:-64+i*.001,lat:45}));
 const edges=Array.from({length:601},(_,i)=>({from:i,to:i+1,osmWayId:String(9007199254840993n+BigInt(i)),meters:100+i,
  coords:[[nodes[i].lon,45],[nodes[i+1].lon,45]],accessForward:0,accessReverse:i%2?2:0,surfaceLeaf:'gravel',roadClassLeaf:'unclassified'}));
 const encoded=encodeFromOsmGraph({nodes,edges,restrictions:[{osmRelationId:'33',fromEdge:0,toEdge:1,viaNode:1,viaEdges:[],viaWayIds:[],only:false}],barriers:[]},{regionId:'fixture',sourceEpoch:'fixed'});
 const file=path.join(root,'graph.v4.bin');fs.writeFileSync(file,encoded.graphBuffer);
 const full=decodeGraphV4(encoded.graphBuffer,encoded.geomBuffer),disk=openGraph(file,8192);t.after(()=>disk.close());
 for(const field of ['nodeOffsets','edgeTargets','edgeUndirectedIndex','edgeFrom','edgeTo','edgeMeters','nodeCoords','edgeAccess','edgeAttrs','edgeSurfaceLeaf','edgeRoadClassLeaf','edgeGrade','edgeLayer','edgeStructureLeaf','edgeAccessLeaf','edgeFlags','edgeCrossingSeconds'])
  assert.deepEqual(Array.from(disk.pack[field]),Array.from(full[field]),field);
 assert.deepEqual(disk.pack.restrictions,full.restrictions);assert.deepEqual(disk.pack.barriers,full.barriers);
 for(const e of [0,600,1,599,20]) {assert.equal(disk.pack.edgeId(e),full.edgeId(e));assert.deepEqual(disk.pack.edgeLeaves(e),full.edgeLeaves(e));}
 for(const n of [0,601,1,400])assert.equal(disk.pack.osmNodeIds[n],full.osmNodeIds[n]);
 const a=createV4Graph(full),b=createV4Graph(disk.pack);
 for(const node of [0,1,2,599])assert.deepEqual([...b.outgoing(node)],[...a.outgoing(node)]);
 const arrival=b.transition(0,{id:0,from:0,to:1});assert.equal(arrival.allowed,true);
 assert.equal(b.transition(arrival.state,{id:1,from:1,to:2}).allowed,false);
 assert.ok(disk.stats.peakResidentBytes<=8192);assert.ok(disk.stats.misses>disk.stats.uniquePages);
 assert.throws(()=>openGraph(file,8192,'00'.repeat(32)),/mismatch/);
});
