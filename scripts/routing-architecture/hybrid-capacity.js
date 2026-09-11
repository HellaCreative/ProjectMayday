'use strict';
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),zlib=require('node:zlib'),crypto=require('node:crypto');
const {monitorEventLoopDelay}=require('node:perf_hooks');
const {startHybridRides}=require('./hybrid-rides-service');
const {startHybridHttp}=require('./hybrid-http');
const {values}=require('node:util').parseArgs({options:{out:{type:'string'},dataset:{type:'string',default:'strict-wv'},mode:{type:'string',default:'baseline'},workers:{type:'string',default:'1'},scenario:{type:'string',default:'identical'},count:{type:'string',default:'500'},rate:{type:'string',default:'0.5'},'baseline-guidance':{type:'boolean',default:false}}});
const root='/Users/richardsmith/.codex/experiments/routing-architecture-20260911',out=values.out;
if(!out||fs.existsSync(out))throw new Error('Supply a new output path');
const count=Number(values.count),workers=Number(values.workers);if(!Number.isInteger(count)||count<1||count>500)throw new Error('count 1..500');
const sustained=values.scenario==='sustained',rate=Number(values.rate);
if(!['strict-wv','nsnb','wv','wv-objective'].includes(values.dataset)||!['baseline','broker'].includes(values.mode)||!['identical','warm','unique','mixed','sustained'].includes(values.scenario))throw new Error('Unknown benchmark configuration');
if(!Number.isFinite(rate)||rate<=0||rate>50)throw new Error('rate must be >0..50');
if(['mixed','sustained'].includes(values.scenario)&&!['wv','wv-objective'].includes(values.dataset))throw new Error('Mixed cases require the full unmasked six-region graph');
const rows=[],controls=new Map(),started=performance.now(),nodeCpu=process.cpuUsage(),delay=monitorEventLoopDelay({resolution:20});delay.enable();
let service,endpoint,broker,sampledNodePeak=0,stage='starting';
const sampler=setInterval(()=>{sampledNodePeak=Math.max(sampledNodePeak,process.memoryUsage().rss);},100);
const report={scenario:values.scenario,mode:values.mode,dataset:values.dataset,workers,submitted:count,stage,scope:'Local loopback HTTP. Node load client and server share a process; group RSS includes client. No hosted CPU quota/throttling or commercial qualification. Fuel remains provisional station access.'};
const rawlog=fs.createWriteStream(out+'.requests.jsonl');
function quantile(xs,p){if(!xs.length)return null;const sorted=xs.slice().sort((a,b)=>a-b);return sorted[Math.min(sorted.length-1,Math.ceil(sorted.length*p)-1)];}
function save(){
 const cpu=process.cpuUsage(nodeCpu);report.stage=stage;report.seconds=(performance.now()-started)/1000;report.completed=rows.length;report.statuses={};for(const r of rows)report.statuses[r.status]=(report.statuses[r.status]??0)+1;
 const ok=rows.filter(x=>x.status===200&&x.poolComplete&&['fuel_provisional','road_only'].includes(x.state));
 report.fullSuccess=ok.length;report.partialPoolSuccess=rows.filter(x=>x.status===200&&!x.poolComplete).length;report.successLatencySeconds={p50:quantile(ok.map(x=>x.seconds),.5),p95:quantile(ok.map(x=>x.seconds),.95),max:quantile(ok.map(x=>x.seconds),1)};
 report.successServerSeconds={p50:quantile(ok.map(x=>x.serverSeconds),.5),p95:quantile(ok.map(x=>x.serverSeconds),.95)};
 report.successQueueSeconds={p50:quantile(ok.map(x=>x.queueSeconds),.5),p95:quantile(ok.map(x=>x.queueSeconds),.95)};
 report.maxDispatchLagSeconds=rows.length?Math.max(...rows.map(x=>x.dispatchSeconds-x.scheduledSeconds)):null;
 report.cacheHits=rows.filter(x=>x.cacheHit).length;report.sharedResponses=rows.filter(x=>x.shared).length;report.responseBytes=rows.reduce((n,x)=>n+x.bytes,0);report.server=endpoint?.stats();report.sampledNodePeakRssBytes=sampledNodePeak;
 report.nodeCpuSeconds={user:cpu.user/1e6,system:cpu.system/1e6};report.eventLoopDelayMillis={p95:delay.percentile(95)/1e6,max:delay.max/1e6};report.hostedThrottling=null;
 fs.writeFileSync(out,JSON.stringify(report,null,2));fs.writeFileSync(out+'.controls.json.gz',zlib.gzipSync(JSON.stringify([...controls.values()])));
}
process.on('SIGTERM',()=>{stage='guard_interrupted';save();process.exit(143);});
async function request(port,q,id,agent){
 const began=performance.now();return new Promise(resolve=>{
  const body=JSON.stringify(q),req=http.request({host:'127.0.0.1',port,path:'/route',method:'POST',agent,headers:{'content-type':'application/json','content-length':Buffer.byteLength(body),'accept-encoding':'gzip','x-request-id':String(id)}},res=>{
   let chunks=[],bytes=0;res.on('data',x=>{chunks.push(x);bytes+=x.length;});res.on('end',()=>{
    try{const wire=Buffer.concat(chunks),plain=res.headers['content-encoding']==='gzip'?zlib.gunzipSync(wire):wire,value=JSON.parse(plain);chunks=null;
     if(res.headers['x-body-sha256']&&crypto.createHash('sha256').update(plain).digest('hex')!==res.headers['x-body-sha256'])throw new Error('Response hash mismatch');
     if(value.proofId&&!controls.has(value.proofId))controls.set(value.proofId,{query:q,result:value});
     resolve({id,status:res.statusCode,state:value.state,poolComplete:value.poolComplete,error:value.error,proofId:value.proofId,seconds:(performance.now()-began)/1000,serverSeconds:res.headers['x-server-seconds']===undefined?null:Number(res.headers['x-server-seconds']),bytes,cacheHit:res.headers['x-cache-hit']==='true',shared:res.headers['x-shared-computation']==='true',queueSeconds:Number(res.headers['x-queue-seconds']??0)});
    }catch(error){resolve({id,status:'decode_error',error:String(error),seconds:(performance.now()-began)/1000,bytes});}
   });
  });
  req.setTimeout(105000,()=>req.destroy(new Error('client_deadline')));req.on('error',error=>resolve({id,status:'transport_error',error:String(error),seconds:(performance.now()-began)/1000,bytes:0}));req.end(body);
 });
}
(async()=>{
 const strict=values.dataset==='strict-wv',small=values.dataset==='nsnb',objective=values.dataset==='wv-objective';
 const log=fs.createWriteStream(out+'.engine.log');
 try{
  service=await startHybridRides({descriptor:path.join(root,`data/verified-${small?'nsnb':'wv'}/verified-input.json`),artifact:path.join(root,strict?'data/gh-verified-wv-strict-lm-km-v2':small?'data/gh-verified-nsnb-directed-v2-objective':objective?'data/gh-verified-wv-objective-lm-km-v1':'data/gh-verified-wv-directed-v2'),objectiveLandmarks:small||objective,objectiveKilometers:objective,additiveGuidance:objective&&!values['baseline-guidance'],strictMask:strict?path.join(root,'unified-stress/blocked-source-edges.bin'):null,workers,onLog:line=>log.write(line+'\n')});
  report.command=service.command;report.buildIdentity=service.buildIdentity;
  const runCandidate=service.runCandidate;
  service.runCandidate=async(q,o)=>{
   const began=performance.now();
   try{
    const result=await runCandidate(q,o);
    const proof=result.fuel?.state==='found'?result.fuel:result.road;
    if(proof?.state==='found')fs.appendFileSync(out+'.candidate-proofs.jsonl.gz',zlib.gzipSync(JSON.stringify({query:q,result:proof})+'\n'));
    fs.appendFileSync(out+'.candidates.jsonl',JSON.stringify({query:q,wallSeconds:(performance.now()-began)/1000,state:result.state,error:result.error,resources:result.resources,
     road:result.road?{seconds:result.road.seconds,distance:result.road.distance,visited:result.road.visited,alternativesComplete:result.road.alternativesComplete}:null,
     fuel:result.fuel?{state:result.fuel.state,reason:result.fuel.reason,seconds:result.fuel.seconds,phases:result.fuel.phases,repair:result.fuel.repair,roadVisited:result.fuel.roadVisited}:null})+'\n');
    return result;
   }catch(error){fs.appendFileSync(out+'.candidates.jsonl',JSON.stringify({query:q,wallSeconds:(performance.now()-began)/1000,error:String(error)})+'\n');throw error;}
  };
  service.rides.runCandidate=service.runCandidate;
  if(values.mode==='broker'){const {HybridBroker}=require('./hybrid-broker');broker=new HybridBroker(service,{workers,queueLimit:8});}
  endpoint=await startHybridHttp({route:(q,o)=>broker?broker.route(q,o):service.rides.route(q,o),stats:()=>broker?.stats()??{baselineSingleSelection:true}});
  const agent=new http.Agent({keepAlive:true,maxSockets:500});
  const fixtures=JSON.parse(fs.readFileSync(path.join(__dirname,'../../docs/experiments/routing-performance-2026-09-10/matrix-inputs.json')));
  const mixed=['ns-short-balanced-road','ns-long-dirt-road','nsnb-balanced-road','qc-long-dirt-road'];
  const ids=sustained?[...mixed,'ns-short-balanced-road','ns-long-dirt-road','nsnb-balanced-road','wv-road']:values.scenario==='mixed'?mixed:[strict||!small?'wv-road':'nsnb-balanced-road'];
  report.fixtureSequence=ids;report.offeredRequestsPerSecond=sustained?rate:null;
  const queries=ids.map(id=>{const loc=fixtures.find(x=>x.id===id).request.locations;return {start:[loc[0].lon,loc[0].lat],end:[loc.at(-1).lon,loc.at(-1).lat],profile:'dirt',allowUnknown:false,fuel:{usableRangeMeters:193121.28,initialUsableMeters:193121.28}};});
  if(values.scenario==='warm'){stage='warming';const warm=await request(endpoint.port,queries[0],'warm',agent);report.warmControl=warm;if(warm.status!==200||!warm.poolComplete)throw new Error('Warm control did not complete');}
  stage='burst';save();const burstStart=performance.now(),burstCpu=process.cpuUsage();
  await Promise.all(Array.from({length:count},async(_,i)=>{
   const scheduledSeconds=sustained?i/rate:0;
   if(sustained)await new Promise(resolve=>setTimeout(resolve,Math.max(0,scheduledSeconds*1000-(performance.now()-burstStart))));
   const dispatchSeconds=(performance.now()-burstStart)/1000;
   const q=structuredClone(queries[i%queries.length]);
   if(['unique','mixed','sustained'].includes(values.scenario))q.start[0]+=(i+1)*0.000001;
   return request(endpoint.port,q,i,agent).then(row=>{Object.assign(row,{fixture:ids[i%ids.length],scheduledSeconds,dispatchSeconds});rows.push(row);rawlog.write(JSON.stringify(row)+'\n');if(rows.length%50===0||sustained){save();console.log(JSON.stringify({completed:rows.length,statuses:report.statuses,seconds:(performance.now()-burstStart)/1000}));}});
  }));
  const cpu=process.cpuUsage(burstCpu);report.burstNodeCpuSeconds={user:cpu.user/1e6,system:cpu.system/1e6};report.burstSeconds=(performance.now()-burstStart)/1000;stage='complete';agent.destroy();save();console.log(JSON.stringify({fullSuccess:report.fullSuccess,statuses:report.statuses,seconds:report.burstSeconds,latency:report.successLatencySeconds,server:report.server}));
 }catch(error){report.failure=String(error);stage='failed';save();throw error;}
 finally{clearInterval(sampler);delay.disable();save();rawlog.end();if(endpoint)await endpoint.close();broker?.close();if(service)report.engineExit=await service.close();report.afterDrain=endpoint?.stats();log.end();fs.writeFileSync(out,JSON.stringify(report,null,2));}
})().catch(error=>{console.error(error);process.exitCode=1;});
