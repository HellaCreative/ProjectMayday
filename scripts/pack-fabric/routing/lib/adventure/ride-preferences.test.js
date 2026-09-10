'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {validatePreferences,wanderEdgeCost}=require('./ride-preferences');
test('maximum wander retains accepted objective exactly',()=>{const base=a=>a.distanceMeters;assert.equal(wanderEdgeCost(base),base);});
test('lower wander raises extra-distance cost continuously without erasing surface preference',()=>{
 const base=a=>a.distanceMeters*(a.surface==='dirt'?1:30);
 const costs=[0,.25,.5,.75,1].map(w=>wanderEdgeCost(base,w));
 for(const cost of costs)assert.ok(cost({distanceMeters:100,surface:'dirt'})<cost({distanceMeters:100,surface:'paved'}));
 const extra=costs.map(cost=>cost({distanceMeters:200,surface:'dirt'})-cost({distanceMeters:100,surface:'dirt'}));
 for(let i=1;i<extra.length;i++)assert.ok(extra[i]<extra[i-1]);
});
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

test('return-road preference is optional and validated',()=>{
 const plain={wander:1,avoidCities:true,avoidHighways:false};
 assert.deepEqual(validatePreferences(plain),plain);
 assert.equal(validatePreferences({...plain,preferDifferentRoads:true}).preferDifferentRoads,true);
 assert.throws(()=>validatePreferences({...plain,preferDifferentRoads:'yes'}));
});
