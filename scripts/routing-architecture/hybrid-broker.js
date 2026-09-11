'use strict';
const {HybridRides,normalizeRequest,poolKey}=require('./hybrid-rides');
function freeze(value){if(value&&typeof value==='object'&&!Object.isFrozen(value)){Object.freeze(value);for(const v of Object.values(value))freeze(v);}return value;}
// One immutable graph service, bounded active itinerary jobs, exact-key sharing,
// bounded waiting jobs, and an LRU of completed pools. No road is removed.
class HybridBroker {
 constructor(engine,{workers=2,queueLimit=8,cacheBytes=64*1024*1024,ttlMillis=300000,maxClients=512,makeWorker=null}={}){
  if(!Number.isInteger(workers)||workers<1||workers>4||!Number.isInteger(queueLimit)||queueLimit<0||queueLimit>64||!Number.isFinite(cacheBytes)||cacheBytes<0)throw new TypeError('Invalid broker limits');
  this.identity=engine.identity;this.queueLimit=queueLimit;this.cacheLimit=cacheBytes;this.ttlMillis=ttlMillis;this.maxClients=maxClients;
  this.workers=Array.from({length:workers},()=>makeWorker?makeWorker():new HybridRides({runCandidate:engine.runCandidate,identity:engine.identity,strictCostMask:engine.strictCostMask,maxCacheBytes:0}));
  this.idle=this.workers.slice();this.jobs=new Map();this.queue=[];this.cache=new Map();this.bytes=0;this.clients=0;this.active=0;this.closed=false;
  this.counters={received:0,cacheHits:0,sharedRequests:0,jobsStarted:0,jobsFinished:0,queueRejected:0,clientRejected:0,clientsCancelled:0,clientsExpired:0,peakActive:0,peakQueued:0,peakClients:0,cacheEvictions:0};
 }
 stats(){return {...this.counters,active:this.active,queued:this.queue.length,waitingClients:this.clients,cacheEntries:this.cache.size,serializedCacheBytes:this.bytes,workerLimit:this.workers.length,queueLimit:this.queueLimit};}
 route(input,{signal}={}){
  this.counters.received++;
  const q=normalizeRequest(input),now=performance.now(),key=poolKey(q,this.identity);
  if(this.closed||signal?.aborted)return Promise.reject(new Error(signal?.aborted?'cancelled':'broker_closed'));
  const cached=this.cache.get(key);
  if(cached){
   if(now-cached.at<this.ttlMillis){this.cache.delete(key);this.cache.set(key,cached);this.counters.cacheHits++;return Promise.resolve({base:cached.base,cacheHit:true,shared:false,queueSeconds:0});}
   this.cache.delete(key);this.bytes-=cached.bytes;
  }
  if(this.clients>=this.maxClients){this.counters.clientRejected++;return Promise.reject(new Error('client_admission_full'));}
  let job=this.jobs.get(key),shared=!!job;
  if(!job){
   if(!this.idle.length&&this.queue.length>=this.queueLimit){this.counters.queueRejected++;return Promise.reject(new Error('selection_queue_full'));}
   job={key,q,submitted:now,deadline:now+q.timeoutMillis,watchers:new Set(),controller:new AbortController(),state:'queued'};
   this.jobs.set(key,job);this.queue.push(job);this.counters.peakQueued=Math.max(this.counters.peakQueued,this.queue.length);
  }else this.counters.sharedRequests++;
  const promise=new Promise((resolve,reject)=>{
   const w={resolve,reject,signal,shared,done:false,deadline:now+q.timeoutMillis};
   w.abort=()=>this.detach(job,w,'cancelled');
   w.timer=setTimeout(()=>this.detach(job,w,'request_deadline'),q.timeoutMillis);
   signal?.addEventListener('abort',w.abort,{once:true});job.watchers.add(w);this.clients++;this.counters.peakClients=Math.max(this.counters.peakClients,this.clients);
  });
  this.pump();return promise;
 }
 releaseWatcher(job,w){if(w.done)return false;w.done=true;clearTimeout(w.timer);w.signal?.removeEventListener('abort',w.abort);job.watchers.delete(w);this.clients--;return true;}
 detach(job,w,reason){
  if(!this.releaseWatcher(job,w))return;
  this.counters[reason==='cancelled'?'clientsCancelled':'clientsExpired']++;w.reject(new Error(reason));
  if(!job.watchers.size){
   job.controller.abort();if(this.jobs.get(job.key)===job)this.jobs.delete(job.key);
   if(job.state==='queued'){this.queue=this.queue.filter(x=>x!==job);job.state='cancelled';}
  }
 }
 settle(job,error,base){
  for(const w of [...job.watchers]){
   if(performance.now()>=w.deadline){this.detach(job,w,'request_deadline');continue;}
   if(this.releaseWatcher(job,w))error?w.reject(error):w.resolve({base,cacheHit:false,shared:w.shared,queueSeconds:(job.started-job.submitted)/1000});
  }
 }
 remember(job,base){
  if(!base.poolComplete||job.controller.signal.aborted||this.cacheLimit===0||performance.now()>=job.deadline)return;
  const bytes=Buffer.byteLength(JSON.stringify(base));if(bytes>this.cacheLimit)return;
  const old=this.cache.get(job.key);if(old){this.cache.delete(job.key);this.bytes-=old.bytes;}
  while(this.bytes+bytes>this.cacheLimit){const key=this.cache.keys().next().value;this.bytes-=this.cache.get(key).bytes;this.cache.delete(key);this.counters.cacheEvictions++;}
  this.cache.set(job.key,{base,bytes,at:performance.now()});this.bytes+=bytes;
 }
 pump(){
  while(!this.closed&&this.idle.length&&this.queue.length){
   const job=this.queue.shift();if(!job.watchers.size)continue;
   const remaining=Math.floor(job.deadline-performance.now());
   if(remaining<=0){this.settle(job,new Error('queue_deadline'));if(this.jobs.get(job.key)===job)this.jobs.delete(job.key);continue;}
   const worker=this.idle.pop();job.state='active';job.started=performance.now();this.active++;this.counters.jobsStarted++;this.counters.peakActive=Math.max(this.counters.peakActive,this.active);
   Promise.resolve().then(()=>worker.route({...job.q,profile:'dirt',timeoutMillis:remaining},{signal:job.controller.signal})).then(result=>{
    if(job.controller.signal.aborted)return;
    const base=freeze(result);this.remember(job,base);this.settle(job,null,base);
   }).catch(error=>this.settle(job,error)).finally(()=>{
    job.state='finished';this.active--;this.counters.jobsFinished++;if(this.jobs.get(job.key)===job)this.jobs.delete(job.key);this.idle.push(worker);this.pump();
   });
  }
 }
 close(){this.closed=true;for(const job of this.jobs.values()){for(const w of [...job.watchers])this.detach(job,w,'cancelled');}this.cache.clear();this.bytes=0;}
}
module.exports={HybridBroker};
