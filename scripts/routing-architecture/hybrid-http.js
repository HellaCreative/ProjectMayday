'use strict';
// Loopback-only capacity adapter. No production listener or app API replacement.
const http=require('node:http'),zlib=require('node:zlib'),crypto=require('node:crypto');
function wireView(base,style){
 const c=base.candidates.find(x=>x.id===base.choices[style]);
 const r=c?.route;
 return {engine:base.engine,sourceIdentity:base.sourceIdentity,profile:style,
  state:c?(base.constraints.fuel?(c.eligible?'fuel_provisional':'fuel_unresolved'):'road_only'):'incomplete',
  navigationReady:false,productProfileParity:false,scope:base.scope,poolComplete:base.poolComplete,incompleteReason:base.incompleteReason,
  selectedCandidateId:c?.id??null,proofId:c?.proofId??null,surface:c?.surface,fuel:c?.fuel,
  route:r?{distance:r.distance,weight:r.weight,steps:r.steps,edges:r.edges,points:r.points,remainingUsableMeters:r.remainingUsableMeters,escapeStation:r.escapeStation,escape:r.escape}:null,
  choices:base.choices,candidates:base.candidates.map(x=>({id:x.id,proofId:x.proofId,surface:x.surface,fuelState:x.fuel.state,eligible:x.eligible})),limitations:base.limitations};
}
async function startHybridHttp({route,stats=()=>({})}){
 const memo=new WeakMap();let pending=0,peakPending=0,bytesSent=0,responses=0;
 const server=http.createServer(async(req,res)=>{
  if(req.method==='GET'&&req.url==='/health'){res.setHeader('content-type','application/json');res.end(JSON.stringify({state:'ready',...stats()}));return;}
  if(req.method!=='POST'||req.url!=='/route'){res.statusCode=404;res.end();return;}
  if(pending>=512){res.statusCode=429;res.end('{"error":"connection_admission_full"}');return;}
  pending++;peakPending=Math.max(peakPending,pending);const controller=new AbortController(),started=performance.now();
  const abort=()=>{if(!res.writableEnded)controller.abort();};res.on('close',abort);
  try{
   let bytes=0,chunks=[];for await(const chunk of req){bytes+=chunk.length;if(bytes>128*1024)throw new Error('request_body_limit');chunks.push(chunk);}
   const q=JSON.parse(Buffer.concat(chunks).toString('utf8'));chunks=null;
   const delivery=await route(q,{signal:controller.signal});if(controller.signal.aborted)return;
   const base=delivery.base??delivery,style=q.profile;
   let styles=memo.get(base);if(!styles){styles=new Map();memo.set(base,styles);}
   let cached=styles.get(style);if(!cached){const body=wireView(base,style),plain=Buffer.from(JSON.stringify(body));cached={body,plain,gzip:zlib.gzipSync(plain),sha:crypto.createHash('sha256').update(plain).digest('hex')};styles.set(style,cached);}
   const compressed=/\bgzip\b/.test(req.headers['accept-encoding']??''),payload=compressed?cached.gzip:cached.plain;
   res.statusCode=cached.body.state==='incomplete'||cached.body.state==='fuel_unresolved'?503:200;
   res.setHeader('content-type','application/json');res.setHeader('content-length',payload.length);if(compressed)res.setHeader('content-encoding','gzip');
   res.setHeader('x-body-sha256',cached.sha);res.setHeader('x-cache-hit',String(delivery.cacheHit??base.cacheHit??false));res.setHeader('x-shared-computation',String(delivery.shared??false));
   res.setHeader('x-server-seconds',((performance.now()-started)/1000).toFixed(6));res.setHeader('x-queue-seconds',String(delivery.queueSeconds??0));
   bytesSent+=payload.length;responses++;res.end(payload);
  }catch(error){
   if(!res.destroyed){const reason=String(error.message??error);res.statusCode=/busy|queue_full|admission_full/.test(reason)?429:/deadline/.test(reason)?504:/cancel/.test(reason)?499:error instanceof TypeError||error instanceof SyntaxError||reason==='request_body_limit'?400:503;
    res.setHeader('content-type','application/json');if(res.statusCode===429)res.setHeader('retry-after','5');res.end(JSON.stringify({state:'error',error:reason}));responses++;}
  }finally{pending--;res.off('close',abort);}
 });
 server.maxConnections=512;server.headersTimeout=10000;server.requestTimeout=10000;
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 return {port:server.address().port,stats:()=>({pending,peakPending,bytesSent,responses,...stats()}),async close(){server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}};
}
module.exports={startHybridHttp,wireView};
