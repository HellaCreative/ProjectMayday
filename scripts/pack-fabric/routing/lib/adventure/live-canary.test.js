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
 for(const extra of [{options:{avoidEdgeIds:['closed']}},{fuel:{requiredFirstStationId:'pump'}},{fuel:{minimumFuelStops:1}},{action:'debug_graph'}])assert.equal(canarySupported({...base,...extra},'fuel',env),false);
});
test('Atlantic opt-in exposes actual region identities and unknown-access intent',()=>{
 const {routeResponse}=require('./live-canary');
 const body={profile:'dirt',locations:[{},{}],accessPolicy:{motorizedUnknown:true}};
 assert.equal(canarySupported(body,'route',{DIRT_ADVENTURE_CANARY:'ns-nb-v1'}),true);
 assert.equal(canarySupported(body,'route',{DIRT_ADVENTURE_CANARY:'unreviewed'}),false);
 const identities=[{regionId:'ns'},{regionId:'nb'}];
 assert.deepEqual(routeResponse([],'dirt',identities,{},[0,0]).debug.regionIds,['ns','nb']);
 const f=fixture(),pool=buildRideAlternatives({...f,budget:work()});
 assert.equal(toLiveResponse(pool,{...body,fuel:{windowMaxStops:4}},'fuel',identities).diagnostics.allowUnknown,true);
});

test('phone Clean highway preference stays in the replacement engine',()=>{
 const body={profile:'cleanest',locations:[{lat:44.764843,lon:-63.340218},{lat:46.792506,lon:-67.569371}],options:{avoidMotorways:true,mapZoom:10.7},fuel:{usableRangeMeters:225000,firstLegMaxMeters:225000,windowMaxStops:12,forwardFeeler:false}};
 assert.equal(canarySupported(body,'fuel',{DIRT_ADVENTURE_CANARY:'ns-nb-v1'}),true);
 assert.equal(canarySupported({...body,options:{...body.options,arrivalEdgeId:'turn-context',priorEdgeIds:['turn-context']}},'fuel',{DIRT_ADVENTURE_CANARY:'ns-nb-v1'}),true);
});

test('Clean avoids a motorway shortcut but keeps an unavoidable motorway connection',()=>{
 for(const alternative of [true,false]) {
  const nodes=[{id:1,lon:-63.30,lat:44.7},{id:2,lon:-63.29,lat:44.7},{id:3,lon:-63.28,lat:44.7},{id:4,lon:-63.27,lat:44.7},{id:5,lon:-63.285,lat:44.72}];
  const ways=[{id:10,nodeIds:[1,2],tags:{highway:'residential',surface:'asphalt'}},{id:11,nodeIds:[2,3],tags:{highway:'motorway',surface:'asphalt',oneway:'no'}},{id:12,nodeIds:[3,4],tags:{highway:'residential',surface:'asphalt'}}];
  if(alternative)ways.push({id:13,nodeIds:[2,5,3],tags:{highway:'unclassified',surface:'asphalt'}});
  const encoded=encodeFromOsmGraph(buildGraphFromOsm({nodes,ways}),{regionId:'ns',sourceEpoch:'test'});
  const options={pack:decodeGraphV4(encoded.graphBuffer,encoded.geomBuffer),geom:decodeGeometryV1(encoded.geomBuffer),revision:`motorway-${alternative}`,stations:[],input:{mode:'from_here',anchors:[{id:'a',lat:44.7,lon:-63.30},{id:'b',lat:44.7,lon:-63.27}],legs:[{from:'a',to:'b',profile:'clean'}],fuel:null},avoidMotorways:true,budget:work()};
  const result=buildRideAlternatives(options);
  assert.equal(result.state,'complete');assert.equal(result.search.poolComplete,true);
  assert.equal(result.selected.road.urbanMeters,0);
  assert.equal(result.selected.road.motorwayMeters>0,!alternative);
  assert.equal(result.selected.road.surface.pavedPercent,100);
 }
});

test('a truncated fuel candidate cannot report a fully evaluated ride pool',()=>{
 const f=fixture(),pool=buildRideAlternatives({...f,maxFuelLabels:1,budget:work()});
 assert.equal(pool.search.poolComplete,false);
 assert.ok(pool.candidates.some(c=>c.reason==='label_limit'));
});

test('unsupported Atlantic ride controls report incomplete rather than switching engines',async()=>{
 const {adventureCanaryRequest}=require('./live-canary');
 const result=await adventureCanaryRequest({profile:'balanced',locations:[{lat:44.7648,lon:-63.3402},{lat:45.9,lon:-60}],options:{avoidEdgeIds:['closed']}},'fuel',{environment:{DIRT_ADVENTURE_CANARY:'ns-nb-v1'},load:()=>{throw Error('must not load');}});
 assert.equal(result.status,'unknown');assert.equal(result.error,'adventure_unsupported_controls');assert.equal(result.diagnostics.strategy,'adventure-preview-v1');
});

test('an unfinished comparison cannot silently ship the first feasible candidate',()=>{
 const pool=buildRideAlternatives({...fixture(),budget:work()});
 pool.search.poolComplete=false;pool.search.reason='deadline';
 const response=toLiveResponse(pool,{profile:'balanced',fuel:{}},'fuel',[]);
 assert.equal(response.status,'unknown');assert.equal(response.error,'adventure_search_incomplete');assert.equal(response.windowComplete,false);
});

test('covered rides with unqualified pack data never fall back to the retired engine',async()=>{
 const {adventureCanaryRequest}=require('./live-canary');
 const body={profile:'balanced',locations:[{lat:44.7648,lon:-63.3402},{lat:45.9,lon:-60}],fuel:{usableRangeMeters:225000,firstLegMaxMeters:225000}};
 for(const data of [{pack:{graphBinaryVersion:3}},{pack:{graphBinaryVersion:4},identity:[]}]){
  const result=await adventureCanaryRequest(body,'fuel',{environment:{DIRT_ADVENTURE_CANARY:'ns-nb-v1'},load:async()=>data});
  assert.equal(result.status,'unknown');assert.equal(result.error,'adventure_pack_unqualified');
 }
});
