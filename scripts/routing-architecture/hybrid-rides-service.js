'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {spawn}=require('node:child_process'),readline=require('node:readline');
const {HybridRides}=require('./hybrid-rides');
const ROOT='/Users/richardsmith/.codex/experiments/routing-architecture-20260911';
async function startHybridRides({descriptor,artifact,objectiveLandmarks=false,objectiveKilometers=false,additiveGuidance=objectiveKilometers,multiEndpoints=objectiveKilometers,strictMask=null,workers=1,onLog=()=>{}}){
 if(!Number.isSafeInteger(workers)||workers<1||workers>4)throw new TypeError('workers must be 1..4');
 if(objectiveKilometers&&!objectiveLandmarks||strictMask&&objectiveLandmarks)throw new TypeError('Incompatible landmark configuration');
 // A serving launch must never become an unplanned graph/index build.
 const required=['properties','dirt-input.identity','nodes','edges','geometry','turn_costs','location_index'];
 for(const profile of objectiveLandmarks?['distance','paved','dirt10','dirt30']:['distance'])required.push('landmarks_'+profile,'landmarks_subnetwork_'+profile);
 for(const name of required)if(!fs.statSync(path.join(artifact,name),{throwIfNoEntry:false})?.isFile())throw new Error(`Unprepared engine artifact: ${name}`);
 const buildPath=path.join(ROOT,'tools/gh-adapter/build-identity.json'),build=JSON.parse(fs.readFileSync(buildPath));
 for(const [filename,wanted] of Object.entries(build.files)){
  const h=crypto.createHash('sha256');for await(const chunk of fs.createReadStream(filename))h.update(chunk);
  if(h.digest('hex')!==wanted)throw new Error(`Stale compiled adapter: ${filename}`);
 }
 const buildIdentity=crypto.createHash('sha256').update(fs.readFileSync(buildPath)).digest('hex');
 const args=['-Xmx2g'];
 if(objectiveLandmarks)args.push('-Ddirt.objectiveLandmarks=true');
 if(objectiveKilometers)args.push('-Ddirt.objectiveLandmarkKilometers=true');
 if(additiveGuidance)args.push('-Ddirt.additiveLandmarkGuidance=true');
 if(multiEndpoints)args.push('-Ddirt.multiEndpointSearch=true');
 if(strictMask)args.push('-Ddirt.stressLandmarks=true',`-Ddirt.stressMask=${strictMask}`);
 args.push('-cp',path.join(ROOT,'tools/gh-adapter')+':'+path.join(ROOT,'tools/graphhopper-web-11.0.jar'),'ConcurrentVerifiedHopper',descriptor,artifact,String(workers));
 const child=spawn('/opt/homebrew/opt/openjdk/bin/java',args,{stdio:['pipe','pipe','pipe']});
 const waiting=new Map();let serial=0,readyResolve,readyReject,exited=false,exitStatus=null,forcedClose=false;
 const ready=new Promise((resolve,reject)=>{readyResolve=resolve;readyReject=reject;});
 const startupTimer=setTimeout(()=>{readyReject(new Error('Engine startup timeout'));child.kill();},30000);
 const fail=error=>{readyReject(error);for(const p of waiting.values())p.reject(error);waiting.clear();};
 child.on('error',fail);child.on('exit',(code,signal)=>{exited=true;exitStatus={code,signal};fail(new Error(`Engine exited: ${code??signal}`));});
 child.stdin.on('error',fail);
 readline.createInterface({input:child.stderr}).on('line',onLog);
 readline.createInterface({input:child.stdout}).on('line',line=>{
  if(line.startsWith('READY ')){clearTimeout(startupTimer);readyResolve();}
  else if(line.startsWith('RESULT ')){
   try{const v=JSON.parse(line.slice(7)),p=waiting.get(v.requestId);if(p){waiting.delete(v.requestId);v.error?p.reject(new Error(v.error)):p.resolve(v.result);}}
   catch(error){fail(error);}
  }else onLog(line);
 });
 try{await ready;}finally{clearTimeout(startupTimer);}
 const runCandidate=(query,{signal}={})=>new Promise((resolve,reject)=>{
  if(exited||signal?.aborted){reject(new Error(signal?.aborted?'cancelled':'engine_closed'));return;}
  const id=String(++serial);let timer;
  const abort=()=>child.stdin.write(JSON.stringify({cancelRequestId:id})+'\n');
  const clean=()=>{clearTimeout(timer);signal?.removeEventListener('abort',abort);};
  waiting.set(id,{resolve:v=>{clean();resolve(v);},reject:e=>{clean();reject(e);}});
  signal?.addEventListener('abort',abort,{once:true});
  timer=setTimeout(()=>{abort();const p=waiting.get(id);if(p){waiting.delete(id);p.reject(new Error('engine_response_deadline'));}child.kill();},query.timeoutMillis+5000);
  child.stdin.write(JSON.stringify({...query,hybrid:true,requestId:id})+'\n');
 });
 const graphIdentity=fs.readFileSync(path.join(artifact,'dirt-input.identity'),'utf8');
 const rides=new HybridRides({runCandidate,identity:graphIdentity+':'+buildIdentity+`:sum=${additiveGuidance}:multi=${multiEndpoints}`,strictCostMask:!!strictMask});
 return {rides,runCandidate,identity:rides.identity,strictCostMask:!!strictMask,child,buildIdentity,command:[child.spawnfile,...args],async close(){
  if(!exited){child.stdin.end();
   await new Promise(resolve=>{let hardTimer;const timer=setTimeout(()=>{forcedClose=true;child.kill();hardTimer=setTimeout(()=>child.kill('SIGKILL'),2000);},10000);child.once('exit',()=>{clearTimeout(timer);clearTimeout(hardTimer);resolve();});});
  }
  return {...exitStatus,forcedClose};
 }};
}
if(require.main===module){
 (async()=>{
  const {values}=require('node:util').parseArgs({options:{descriptor:{type:'string'},artifact:{type:'string'},'objective-landmarks':{type:'boolean'},'strict-mask':{type:'string'}}});
  if(!values.descriptor||!values.artifact)throw new Error('Supply descriptor and artifact');
  const service=await startHybridRides({descriptor:values.descriptor,artifact:values.artifact,objectiveLandmarks:values['objective-landmarks'],strictMask:values['strict-mask'],onLog:line=>process.stderr.write(line+'\n')});
  process.stdout.write('READY shared-rides-v1\n');
  try{for await(const line of readline.createInterface({input:process.stdin})){
   try{process.stdout.write('RESULT '+JSON.stringify(await service.rides.route(JSON.parse(line)))+'\n');}
   catch(error){process.stdout.write('RESULT '+JSON.stringify({state:'error',error:String(error)})+'\n');}
  }}finally{await service.close();}
 })().catch(error=>{process.stderr.write(String(error)+'\n');process.exitCode=1;});
}
module.exports={startHybridRides};
