'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {HybridRides,chooseRides,evaluateCandidate,normalizeRequest}=require('./hybrid-rides');
const base={start:[-63,45],end:[-62,46],profile:'dirt'};
const step=(kind,meters)=>({meters,surfaceKind:kind,pavedBackroadCost:meters*(kind===0?1:100),from:0,to:1,sourceKey:kind,geometry:'LINESTRING (0 0, 1 1)'});
function envelope(dirt,paved=100-dirt){return {state:'road_only',road:{distance:dirt+paved,edges:[step(1,dirt),step(0,paved)]}};}
test('existing DIRT ranking chooses 48% over 65%, and Dirt sees the same richer pool',()=>{
 const candidates=[48,65,100,0].map(n=>evaluateCandidate(String(n),envelope(n),base));
 const original=JSON.stringify(candidates);
 for(const pool of [candidates,candidates.slice().reverse()])assert.deepEqual(chooseRides(pool),{dirt:'100',balanced:'48',clean:'0'});
 assert.equal(JSON.stringify(candidates),original);
});
test('unknown surface satisfies neither side of Balanced',()=>{
 const unknown={state:'road_only',road:{distance:100,edges:[step(1,50),step(2,50)]}};
 const rows=[evaluateCandidate('unknown',unknown,base),evaluateCandidate('known',envelope(48),base)];
 assert.equal(chooseRides(rows).balanced,'known');
 assert.equal(rows[0].surface.knownDirtPercent,50);
});
test('fuel arithmetic rejects a false certificate and never upgrades provisional pump access',()=>{
 const q={...base,fuel:{usableRangeMeters:100,initialUsableMeters:50}};
 const e={state:'fuel_verified',fuel:{state:'found',distance:100,steps:[step(1,50),{from:1,to:1,meters:0,refill:'pump'},step(0,50)],escape:[step(0,20)],escapeStation:'escape',remainingUsableMeters:50}};
 const c=evaluateCandidate('ok',e,q);assert.equal(c.fuel.state,'provisional_station_access');assert.equal(c.fuel.escapeUsableMeters,30);
 e.fuel.steps[0].meters=51;e.fuel.distance=101;
 assert.throws(()=>evaluateCandidate('bad',e,q),/disagrees/);
 assert.throws(()=>evaluateCandidate('excluded',{...e,fuel:{...e.fuel,distance:100,steps:[step(1,50),{from:1,to:1,meters:0,refill:'pump'},step(0,50)]}},{...q,excludedStationIds:['escape']}),/excluded/);
});
test('fuel-unresolved richer road cannot displace a feasible ride; failure still retains a road',()=>{
 const low=evaluateCandidate('feasible',envelope(20),base);low.fuel={state:'provisional_station_access'};
 const rich=evaluateCandidate('unresolved',envelope(100),base);rich.eligible=false;rich.fuel={state:'unverified'};
 assert.equal(chooseRides([low,rich]).dirt,'feasible');assert.equal(chooseRides([rich]).dirt,'unresolved');
});
test('style edits reuse one bounded pool; fuel constraints invalidate it',async()=>{
 const calls=[],rides=new HybridRides({identity:'test',runCandidate:async q=>{calls.push(q);return envelope({dirt30:30,dirt10:65,paved:0,distance:48}[q.profile]);}});
 const dirt=await rides.route(base);assert.equal(dirt.selectedCandidateId,'dirt10');assert.equal(calls.length,4);
 const balanced=await rides.route({...base,profile:'balanced'});assert.equal(balanced.selectedCandidateId,'distance');assert.equal(balanced.cacheHit,true);assert.equal(calls.length,4);
 balanced.candidates[0].surface.knownDirtPercent=999;
 assert.notEqual((await rides.route(base)).candidates[0].surface.knownDirtPercent,999);
 await rides.route({...base,excludedStationIds:['closed-pump']});assert.equal(calls.length,8);
 await rides.route({...base,profile:'clean',fuel:{usableRangeMeters:100,initialUsableMeters:100}});assert.equal(calls.length,12);
});
test('failed candidates preserve a winner and partial pools are not cached',async()=>{
 let calls=0;const rides=new HybridRides({identity:'test',runCandidate:async q=>{calls++;if(q.profile==='dirt30')return envelope(80);throw new Error('bounded failure');}});
 const result=await rides.route(base);assert.equal(result.selectedCandidateId,'dirt30');assert.equal(result.poolComplete,false);
 await rides.route(base);assert.equal(calls,8);
});
test('cancellation cannot publish or cache a partial successful pool',async()=>{
 const controller=new AbortController();let calls=0;
 const rides=new HybridRides({identity:'test',runCandidate:async()=>{calls++;controller.abort();return envelope(90);}});
 await assert.rejects(rides.route(base,{signal:controller.signal}),/cancelled/);assert.equal(calls,1);assert.equal(rides.cache,null);
});
test('unsupported waypoints/history and missing initial fuel are explicit errors',()=>{
 for(const field of ['arrivalHistory','waypoints'])assert.throws(()=>normalizeRequest({...base,[field]:[]}),/Unsupported/);
 assert.throws(()=>normalizeRequest({...base,fuel:{usableRangeMeters:100}}),/initial/);
});
test('response cache byte limit never removes roads from the generated pool',async()=>{
 const rides=new HybridRides({identity:'test',maxCacheBytes:1,runCandidate:async()=>envelope(50)});
 const result=await rides.route(base);assert.equal(result.candidates.length,4);assert.equal(result.poolComplete,true);assert.equal(rides.cache,null);
});
