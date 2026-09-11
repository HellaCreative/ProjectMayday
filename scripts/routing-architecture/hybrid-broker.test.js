'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {HybridBroker}=require('./hybrid-broker');
const q={start:[-63,45],end:[-62,46],profile:'dirt'};
const base=complete=>({poolComplete:complete,choices:{dirt:'x',balanced:'x',clean:'x'},candidates:[{id:'x',route:{steps:[{meters:100}]} }]});
function fixture(options={}){
 const pending=[],calls=[];const broker=new HybridBroker({identity:'same-graph'},{workers:1,queueLimit:1,...options,makeWorker:()=>({route:(query,{signal})=>{calls.push(query);return new Promise((resolve,reject)=>{pending.push({resolve,reject,query,signal});signal.addEventListener('abort',()=>reject(new Error('cancelled')),{once:true});});}})});
 return {broker,pending,calls};
}
const tick=()=>new Promise(resolve=>setImmediate(resolve));
test('500 simultaneous equivalent style requests share exactly one immutable pool',async()=>{
 const {broker,pending,calls}=fixture();
 const promises=Array.from({length:500},(_,i)=>broker.route({...q,profile:['dirt','balanced','clean'][i%3]}));
 await tick();assert.equal(calls.length,1);pending[0].resolve(base(true));const all=await Promise.all(promises);await tick();
 assert(all.every(x=>x.base===all[0].base));assert.equal(all.filter(x=>x.shared).length,499);
 assert.throws(()=>{all[0].base.candidates[0].route.steps[0].meters=999;},TypeError);
 const cached=await broker.route(q);assert(cached.cacheHit);assert.equal(calls.length,1);broker.close();
});
test('distinct requests respect active/queue limits, and queue time reduces execution budget',async()=>{
 const {broker,pending,calls}=fixture();const a=broker.route(q),b=broker.route({...q,start:[-64,45]});
 await assert.rejects(broker.route({...q,start:[-65,45]}),/queue_full/);await tick();assert.equal(calls.length,1);
 pending[0].resolve(base(true));await a;await tick();assert.equal(calls.length,2);assert(calls[1].timeoutMillis<90000);
 pending[1].resolve(base(true));await b;await tick();assert.equal(broker.stats().peakActive,1);assert.equal(broker.stats().queueRejected,1);broker.close();
});
test('cancelling one shared client leaves the other client and engine job intact',async()=>{
 const {broker,pending}=fixture(),controller=new AbortController();
 const a=broker.route(q,{signal:controller.signal}),b=broker.route(q);await tick();controller.abort();
 await assert.rejects(a,/cancelled/);assert.equal(pending[0].signal.aborted,false);pending[0].resolve(base(true));await b;await tick();assert.equal(broker.stats().waitingClients,0);broker.close();
});
test('cancelling the last client aborts the shared job and does not cache it',async()=>{
 const {broker,pending}=fixture(),controller=new AbortController();const result=broker.route(q,{signal:controller.signal});await tick();controller.abort();await assert.rejects(result,/cancelled/);await tick();
 assert(pending[0].signal.aborted);assert.equal(broker.stats().cacheEntries,0);assert.equal(broker.stats().active,0);broker.close();
});
test('queued expiry never starts an engine job or becomes a no-route proof',async()=>{
 const {broker,pending,calls}=fixture();const a=broker.route(q);const b=broker.route({...q,start:[-64,45],timeoutMillis:10});
 await assert.rejects(b,/deadline/);pending[0].resolve(base(true));await a;await tick();assert.equal(calls.length,1);assert.equal(broker.stats().clientsExpired,1);broker.close();
});
test('LRU byte cap and partial results do not evict roads from an active result',async()=>{
 const {broker,pending}=fixture({cacheBytes:1});const a=broker.route(q);await tick();pending[0].resolve(base(true));const r=await a;await tick();assert.equal(r.base.candidates.length,1);assert.equal(broker.stats().cacheEntries,0);
 const b=broker.route(q);await tick();pending[1].resolve(base(false));assert.equal((await b).base.poolComplete,false);assert.equal(broker.stats().cacheEntries,0);broker.close();
});
