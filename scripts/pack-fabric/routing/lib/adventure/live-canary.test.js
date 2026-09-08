"use strict";
const test=require('node:test'),assert=require('node:assert/strict');
const {buildGraphFromOsm}=require('../legal-topology/osm-graph'),{encodeFromOsmGraph,decodeGraphV4}=require('../pack-v4'),{decodeGeometryV1}=require('../pack-v2');
const {buildRideAlternatives}=require('./ride-alternatives'),{createBudget}=require('./budget');
const {canarySupported,toLiveResponse}=require('./live-canary');
function fixture(){
 const nodes=[{id:1,lon:-63.3,lat:44.7},{id:2,lon:-63.29,lat:44.7},{id:3,lon:-63.28,lat:44.7},{id:4,lon:-63.27,lat:44.7},{id:5,lon:-63.28,lat:44.71}];
 const ways=[{id:10,nodeIds:[1,2,3,4],tags:{highway:'unclassified',surface:'asphalt',access:'yes'}},{id:11,nodeIds:[2,5,4],tags:{highway:'unclassified',surface:'gravel',access:'yes'}}];
 const encoded=encodeFromOsmGraph(buildGraphFromOsm({nodes,ways}),{regionId:'ns',sourceEpoch:'test'});
 return {pack:decodeGraphV4(encoded.graphBuffer,encoded.geomBuffer),geom:decodeGeometryV1(encoded.geomBuffer),revision:'fixture',stations:[{id:'pump',lat:44.7,lon:-63.29,name:'Fuel'}],input:{mode:'from_here',anchors:[{id:'a',lat:44.7,lon:-63.3},{id:'b',lat:44.7,lon:-63.27}],legs:[{from:'a',to:'b',profile:'dirt'}],fuel:{fullRangeMeters:5000,reserveFraction:0,initialUsableMeters:1000}}};
}
const work=()=>createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:1000000});
test('profiles share the same candidate surface pool and Dirt cannot lose to Balanced',()=>{
 const f=fixture(),results={};for(const profile of ['dirt','balanced','clean']){const input=structuredClone(f.input);input.legs[0].profile=profile;results[profile]=buildRideAlternatives({...f,input,budget:work()});assert.equal(results[profile].search.poolComplete,true);}
 assert.deepEqual(results.dirt.candidates.map(c=>c.surface),results.balanced.candidates.map(c=>c.surface));
 assert.ok(results.dirt.selected.road.surface.knownDirtPercent>=results.balanced.selected.road.surface.knownDirtPercent);
 assert.ok(results.clean.selected.road.surface.pavedPercent>=results.dirt.selected.road.surface.pavedPercent);
});
test('live fuel response partitions the selected ride without rerouting or changing fuel evidence',()=>{
 const f=fixture(),pool=buildRideAlternatives({...f,budget:work()});
 const r=toLiveResponse(pool,{profile:'dirt',fuel:{windowMaxStops:4}},'fuel',[]);
 assert.equal(r.status,'complete');assert.equal(r.fuelAccessEvidence,'provisional_station_access');assert.ok(r.stops.length>0);
 assert.equal(r.routes.length,r.stops.length+1);assert.equal(r.windowComplete,true);
 assert.ok(Math.abs(r.routes.reduce((n,r)=>n+r.distanceMeters,0)-pool.selected.road.distanceMeters)<1e-6);
 assert.deepEqual(r.routes.flatMap((r,i)=>r.geometry.slice(i?1:0)),pool.selected.road.geometry);
 assert.ok(r.routes.every(r=>r.warnings[0].code==='adventure_preview'));
});
test('canary is opt-in and does not silently ignore unsupported recovery or mandatory fuel controls',()=>{
 const base={profile:'dirt',locations:[{},{}],fuel:{usableRangeMeters:1000,firstLegMaxMeters:1000}},env={DIRT_ADVENTURE_CANARY:'ns-v1'};
 assert.equal(canarySupported(base,'fuel',{}),false);assert.equal(canarySupported(base,'fuel',env),true);
 for(const extra of [{options:{avoidEdgeIds:['closed']}},{options:{arrivalEdgeId:'edge'}},{fuel:{requiredFirstStationId:'pump'}},{fuel:{minimumFuelStops:1}},{action:'debug_graph'}])assert.equal(canarySupported({...base,...extra},'fuel',env),false);
});
