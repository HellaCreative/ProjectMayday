"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {buildGraphFromOsm}=require("../legal-topology/osm-graph");
const {encodeFromOsmGraph,decodeGraphV4}=require("../pack-v4");
const {decodeGeometryV1}=require("../pack-v2");
const {legalSnapDetailed}=require("../legal-topology/snap");
const {buildEdgeIndex,matchStations}=require("./station-matching");
const {createBudget}=require("./budget");
function budget(n=10000){return createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:n});}
function fixture(){
  const osm={nodes:[{id:1,lon:-64,lat:45},{id:2,lon:-63.98,lat:45},{id:3,lon:-64,lat:45.01},{id:4,lon:-63.98,lat:45.01}],
    ways:[{id:10,nodeIds:[1,2],tags:{highway:"service",surface:"asphalt",access:"yes"}},
      {id:20,nodeIds:[3,4],tags:{highway:"service",surface:"asphalt",access:"private"}}]};
  const encoded=encodeFromOsmGraph(buildGraphFromOsm(osm),{regionId:"fixture",sourceEpoch:"fixed"});
  return {pack:decodeGraphV4(encoded.graphBuffer,encoded.geomBuffer),geom:decodeGeometryV1(encoded.geomBuffer)};
}
test("indexed station candidates equal full legal projection without OSM-node identity join",()=>{
  const {pack,geom}=fixture(),station={id:"osm:n999",lon:-63.99,lat:45.0001};
  const index=buildEdgeIndex(pack,geom,budget());
  const result=matchStations({pack,geom,index,stations:[station],maxMeters:50,budget:budget()});
  const full=legalSnapDetailed(pack,geom,station,{maxMeters:50});
  assert.equal(result.matches[0].state,"candidates");
  assert.deepEqual(result.matches[0].candidates,full.candidates);
  assert.equal(result.matches[0].stationId,"osm:n999");
});
test("missing or prohibited station access has an explicit reason, not a geographic gap",()=>{
  const {pack,geom}=fixture(),index=buildEdgeIndex(pack,geom,budget());
  const result=matchStations({pack,geom,index,stations:[{id:"private",lon:-63.99,lat:45.01},{id:"far",lon:-60,lat:45}],maxMeters:50,budget:budget()});
  assert.equal(result.matches.every(row=>row.state==="rejected"),true);
  assert.ok(Object.keys(result.matches[0].rejectionCounts).length>0);
  assert.equal(result.matches[1].searchedEdges,0);
});
test("an incomplete index cannot masquerade as zero reachable pumps",()=>{
  const {pack,geom}=fixture(),index=buildEdgeIndex(pack,geom,budget(1));
  assert.equal(index.state,"incomplete");
  assert.throws(()=>matchStations({pack,geom,index,stations:[],maxMeters:50,budget:budget()}),/index/);
});
test('station cache never publishes partial matches or bypasses cancellation',()=>{
 const {createStationMatchCache}=require('./station-match-cache');
 const {pack,geom}=fixture(),index=buildEdgeIndex(pack,geom,budget()),cache=createStationMatchCache();
 const args={pack,geom,index,revision:'one',stations:[{id:'pump',lon:-63.99,lat:45.0001}],maxMeters:50};
 const interrupted=cache.match({...args,budget:budget(1)});
 assert.equal(interrupted.state,'incomplete');assert.equal(cache.diagnostics().entries,0);
 assert.equal(cache.match({...args,budget:budget()}).cacheHit,false);
 const cancelled=cache.match({...args,budget:createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:10000,signal:{aborted:true}})});
 assert.equal(cancelled.reason,'cancelled');assert.deepEqual(cancelled.matches,[]);
 assert.equal(cache.match({...args,budget:budget()}).cacheHit,true);
 assert.equal(cache.match({...args,allowUnknown:true,budget:budget()}).cacheHit,false);
 const other=fixture();assert.equal(cache.match({...args,...other,index:buildEdgeIndex(other.pack,other.geom,budget()),budget:budget()}).cacheHit,false);
});

test('exact bounds reject distant cell neighbours while retaining full crossing geometry',()=>{
 const lines=[[[0,0],[.02,0]],[[.005,.008],[.015,.008]],[[.009,-.01],[.009,.01]]];
 const pack={edgeCount:3},geom={polyline:i=>lines[i]},index=buildEdgeIndex(pack,geom,budget());
 assert.deepEqual(index.query({lon:.01,lat:0},150).sort(),[0,2]);
 assert.deepEqual(index.query({lon:.01,lat:.008},150).sort(),[1,2]);
});

test('zero-copy decoded coordinate indexing equals polyline fallback',()=>{
 const {pack,geom}=fixture();
 const direct=buildEdgeIndex(pack,geom,budget());
 const fallback=buildEdgeIndex(pack,{polyline:geom.polyline},budget());
 for(const lat of [44.999,45,45.005,45.01])for(const lon of [-64,-63.99,-63.98])
  assert.deepEqual(direct.query({lat,lon},150),fallback.query({lat,lon},150));
});
