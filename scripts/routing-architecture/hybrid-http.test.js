'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {startHybridHttp}=require('./hybrid-http');
const fixture={engine:'test',sourceIdentity:'pinned',constraints:{fuel:{usableRangeMeters:1000}},poolComplete:true,
 choices:{dirt:'a',balanced:'b',clean:'b'},candidates:['a','b'].map(id=>({id,proofId:id,eligible:true,fuel:{state:'provisional_station_access'},route:{distance:100,steps:[{meters:100}]}}))};
test('HTTP returns the requested style from a shared pool with provisional fuel and cache evidence',async()=>{
 const server=await startHybridHttp({route:async()=>({base:fixture,cacheHit:true,shared:false,queueSeconds:0})});
 try{
  const response=await fetch(`http://127.0.0.1:${server.port}/route`,{method:'POST',body:JSON.stringify({profile:'clean'})});
  const body=await response.json();assert.equal(response.status,200);assert.equal(body.proofId,'b');assert.equal(body.state,'fuel_provisional');assert.equal(body.navigationReady,false);
  assert.equal(response.headers.get('x-cache-hit'),'true');assert.equal(response.headers.get('content-encoding'),'gzip');
  assert(body.candidates.every(x=>!x.route));assert.equal(body.route.steps.length,1);
 }finally{await server.close();}
});
test('overload and deadline are distinct failures and never become no-route evidence',async()=>{
 for(const [error,status] of [['selection_queue_full',429],['request_deadline',504]]){
  const server=await startHybridHttp({route:async()=>{throw new Error(error);}});
  try{const r=await fetch(`http://127.0.0.1:${server.port}/route`,{method:'POST',body:'{}'});assert.equal(r.status,status);assert.deepEqual(await r.json(),{state:'error',error});if(status===429)assert.equal(r.headers.get('retry-after'),'5');}
  finally{await server.close();}
 }
});
test('unfinished and malformed requests cannot masquerade as complete fuel routes',async()=>{
 const server=await startHybridHttp({route:async()=>({...fixture,poolComplete:false,candidates:[],choices:{}})});
 try{
  const r=await fetch(`http://127.0.0.1:${server.port}/route`,{method:'POST',body:'{"profile":"dirt"}'});assert.equal(r.status,503);assert.equal((await r.json()).state,'incomplete');
  const bad=await fetch(`http://127.0.0.1:${server.port}/route`,{method:'POST',body:'{'});assert.equal(bad.status,400);
 }finally{await server.close();}
});
test('disconnect cancels the abandoned HTTP subscriber',async()=>{
 let observed;const server=await startHybridHttp({route:async(q,{signal})=>{observed=signal;await new Promise(resolve=>signal.addEventListener('abort',resolve,{once:true}));throw new Error('cancelled');}});
 try{
  const controller=new AbortController(),response=fetch(`http://127.0.0.1:${server.port}/route`,{method:'POST',body:'{}',signal:controller.signal}).catch(()=>null);
  const deadline=performance.now()+1000;while(!observed&&performance.now()<deadline)await new Promise(r=>setTimeout(r,5));assert(observed);
  controller.abort();await response;
  while(!observed.aborted&&performance.now()<deadline)await new Promise(r=>setTimeout(r,5));assert(observed.aborted);
 }finally{await server.close();}
});
