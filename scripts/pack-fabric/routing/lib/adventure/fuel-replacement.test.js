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

const {buildFuelReplacement}=require('./fuel-replacement');
const {routeResponse}=require('./live-canary');
function replace(f,overrides={}) {
 const body={profile:'balanced',fuel:{requiredFirstStationId:'pump',usableRangeMeters:5000,firstLegMaxMeters:2000,windowMaxStops:4,...overrides}};
 return buildFuelReplacement({body,options:{...f,budget:work()},identity:[],routeResponse,toLiveResponse});
}
test('replacement preserves canonical pump and continuous fuel-bounded chain',()=>{
 const f=fixture();f.input.fuel.initialUsableMeters=2000;
 const result=replace(f);
 assert.equal(result.status,'complete',JSON.stringify(result));
 assert.equal(result.stops[0].id,'pump');
 assert.equal(result.routes.length,result.stops.length+1);
 assert.ok(result.routes[0].distanceMeters<=2000);
 assert.deepEqual(result.routes[0].geometry.at(-1),result.routes[1].geometry[0]);
 assert.equal(result.windowComplete,true);
});
test('replacement rejects insufficient remaining fuel and unknown identity',()=>{
 const f=fixture();f.input.fuel.initialUsableMeters=2000;
 assert.equal(replace(f,{firstLegMaxMeters:10}).status,'unknown');
 assert.equal(replace(f,{requiredFirstStationId:'missing'}).error,'replacement_station_unavailable');
});
test('replacement returns no partial geometry on unproved continuation',()=>{
 const f=fixture();f.input.fuel.initialUsableMeters=2000;let calls=0;
 const result=buildFuelReplacement({body:{profile:'balanced',fuel:{requiredFirstStationId:'pump',usableRangeMeters:5000,firstLegMaxMeters:2000,windowMaxStops:4}},
 options:{...f,budget:work()},identity:[],routeResponse,toLiveResponse,build:o=>{if(++calls===1){assert.deepEqual(o.stations.map(s=>s.id),["pump"]);return buildRideAlternatives(o)}return {search:{poolComplete:false}}}});
 assert.equal(result.error,'replacement_continuation_unproved');assert.deepEqual(result.routes,[]);
});

test('explicit replacement accepts an individually proved ride when another objective is unproved',()=>{
 const f=fixture();f.input.fuel.initialUsableMeters=2000;
 const result=buildFuelReplacement({body:{profile:'balanced',fuel:{requiredFirstStationId:'pump',usableRangeMeters:5000,firstLegMaxMeters:2000,windowMaxStops:4}},
 options:{...f,budget:work()},identity:[],routeResponse,toLiveResponse,build:o=>{const pool=buildRideAlternatives(o);return {...pool,search:{...pool.search,poolComplete:false}}}});
 assert.equal(result.status,'complete');assert.equal(result.diagnostics.adventure.search.poolComplete,false);
});
