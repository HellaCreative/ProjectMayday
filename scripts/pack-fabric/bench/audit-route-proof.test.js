'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {buildGraphFromOsm}=require('../routing/lib/legal-topology/osm-graph');
const {encodeFromOsmGraph,decodeGraphV4}=require('../routing/lib/pack-v4');
const {auditRouteProof}=require('./audit-route-proof');
function fixture() {
 const osm={nodes:[{id:1,lon:-64,lat:45},{id:2,lon:-63.99,lat:45},{id:3,lon:-63.98,lat:45}],ways:[{id:10,nodeIds:[1,2],tags:{highway:'unclassified',access:'yes'}},{id:20,nodeIds:[2,3],tags:{highway:'unclassified',access:'yes'}}]};
 const b=encodeFromOsmGraph(buildGraphFromOsm(osm),{regionId:'ns',sourceEpoch:'test'}),pack=decodeGraphV4(b.graphBuffer,b.geomBuffer);
 const segment=(e,a,b)=>({edgeIndex:e,edgeId:pack.edgeId(e),fromFraction:a,toFraction:b,distanceMeters:pack.edgeMeters[e]*Math.abs(a-b)});
 return {pack,proof:{routes:[{segments:[segment(0,0,.4),segment(0,.4,1),segment(1,0,1)]}]},request:{profile:'balanced',accessPolicy:{motorizedUnknown:false}}};
}
test('independent legal replay preserves through travel at a split fuel projection',()=>{
 const f=fixture();assert.equal(auditRouteProof(f.pack,f.proof,f.request).turnRestrictions,true);
 const bad=structuredClone(f.proof);bad.routes[0].segments[1].toFraction=0;
 assert.throws(()=>auditRouteProof(f.pack,bad,f.request));
});
test('independent replay detects an illegal node turn and a false source identity',()=>{
 const f=fixture();f.pack.restrictions=[{fromEdge:0,toEdge:1,viaNode:f.pack.edgeTo[0],viaEdges:[],only:false}];
 assert.throws(()=>auditRouteProof(f.pack,f.proof,f.request),/restriction/);
 f.pack.restrictions=[];f.proof.routes[0].segments[0].edgeId='invented';
 assert.throws(()=>auditRouteProof(f.pack,f.proof,f.request),/identity/);
});
test('junction continuation seeds the incoming road and still rejects a prohibited turn',()=>{
 const f=fixture();f.proof.routes[0].segments=f.proof.routes[0].segments.slice(2);
 f.request.options={priorEdgeIds:[f.pack.edgeId(0)],arrivalEdgeId:f.pack.edgeId(0)};
 assert.equal(auditRouteProof(f.pack,f.proof,f.request).arrivalHistory,true);
 f.pack.restrictions=[{fromEdge:0,toEdge:1,viaNode:f.pack.edgeTo[0],viaEdges:[],only:false}];
 assert.throws(()=>auditRouteProof(f.pack,f.proof,f.request),/restriction/);
});
