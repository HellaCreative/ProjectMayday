'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {validatePreferences,wanderCandidates}=require('./ride-preferences');
const row=(id,distance,exposure=0)=>({id,result:{road:{distanceMeters:distance,avoidanceMeters:exposure}}});
test('default wander retains the accepted pool exactly',()=>{const rows=[row('a',100),row('b',300)];assert.equal(wanderCandidates(rows),rows);});
test('wander expands eligible distance monotonically without overriding avoidance',()=>{const rows=[row('a',100),row('b',200),row('c',300),row('city',50,10)];assert.deepEqual(wanderCandidates(rows,0).map(r=>r.id),['a']);assert.deepEqual(wanderCandidates(rows,.5).map(r=>r.id),['a','b']);});
test('malformed preferences cannot be silently ignored',()=>{assert.equal(validatePreferences(null),null);for(const wander of [-1,2,NaN,Infinity])assert.throws(()=>validatePreferences({wander,avoidCities:true,avoidHighways:false}));assert.throws(()=>validatePreferences({wander:1,avoidCities:'false',avoidHighways:false}));});
const {buildGraphFromOsm}=require('../legal-topology/osm-graph');
const {encodeFromOsmGraph,decodeGraphV4}=require('../pack-v4');
const {decodeGeometryV1}=require('../pack-v2');
const {buildFromHere}=require('./from-here');
const {createBudget}=require('./budget');
function routeFixture(ridePreferences,roadClass='primary',urban=false) {
 const nodes=[{id:1,lon:0,lat:0},{id:2,lon:.02,lat:0},{id:3,lon:0,lat:.02},{id:4,lon:.02,lat:.02}];
 const ways=[{id:10,nodeIds:[1,2],tags:{highway:roadClass,surface:'asphalt',access:'yes'}},{id:11,nodeIds:[1,3,4,2],tags:{highway:'unclassified',surface:'asphalt',access:'yes'}}];
 const encoded=encodeFromOsmGraph(buildGraphFromOsm({nodes,ways}),{regionId:'fixture',sourceEpoch:'fixed'});
 return buildFromHere({pack:decodeGraphV4(encoded.graphBuffer,encoded.geomBuffer),geom:decodeGeometryV1(encoded.geomBuffer),revision:'prefs-fixture',stations:[],edgeCost:a=>a.distanceMeters,objectiveId:'distance',ridePreferences,
 additionalUrbanAreas:urban?[{name:'Town',minLon:.005,maxLon:.015,minLat:-.002,maxLat:.002}]:[],
 input:{mode:'from_here',anchors:[{id:'a',lat:0,lon:0},{id:'b',lat:0,lon:.02}],legs:[{from:'a',to:'b',profile:'clean'}],fuel:null},budget:createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:100000})});
}
test('highway switch changes the actual connected route',()=>{
 const direct=routeFixture({wander:1,avoidCities:false,avoidHighways:false});
 const avoid=routeFixture({wander:1,avoidCities:false,avoidHighways:true});
 assert.equal(direct.road.state,'complete');assert.equal(avoid.road.state,'complete');
 assert.ok(avoid.road.distanceMeters>direct.road.distanceMeters*2);
});
test('town switch changes the actual connected route',()=>{
 const direct=routeFixture({wander:1,avoidCities:false,avoidHighways:false},'unclassified',true);
 const avoid=routeFixture({wander:1,avoidCities:true,avoidHighways:false},'unclassified',true);
 assert.equal(direct.road.state,'complete');assert.equal(avoid.road.state,'complete');
 assert.ok(direct.road.urbanMeters>0);assert.equal(avoid.road.urbanMeters,0);
});
