"use strict";
// Runs the unchanged historical oracle protocol against exported historical API
// handlers. Every graph/fuel read is served from the specified local pack root.
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),{spawn}=require('node:child_process');
const code=path.resolve(process.env.RECOVERY_JS_ROOT),root=path.resolve(process.env.DIRT_PACK_ROOT),out=path.resolve(process.env.RECOVERY_OUTPUT);
fs.mkdirSync(out,{recursive:true});
const cases=require('./routing-oracle-cases.json');
let handlers,active='setup',serial=0;
const server=http.createServer(async(req,res)=>{
 if(req.url.startsWith('/api/')){
  let text='';for await(const part of req)text+=part;
  req.body=JSON.parse(text);res.status=n=>{res.statusCode=n;return res};
  res.json=result=>{fs.writeFileSync(path.join(out,`${active}-${++serial}.json`),JSON.stringify({endpoint:req.url,body:req.body,result}));res.setHeader('Content-Type','application/json');res.end(JSON.stringify(result));return res};
  try{await handlers[req.url.slice(5)](req,res)}catch(e){res.status(500).json({status:'error',error:String(e)})}
  return;
 }
 const match=req.url.match(/\/(ns|nb)\/(graph\.v4\.bin|geometry\.v1\.bin|fuel\.v1\.json|cross-pack-seams\.v2\.json|pack-manifest\.v2\.json)$/);
 if(!match){res.statusCode=404;return res.end('No local fixture')}
 const bytes=fs.readFileSync(path.join(root,match[1],match[2]));res.setHeader('Content-Length',bytes.length);res.end(bytes);
});
(async()=>{
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const local=`http://127.0.0.1:${server.address().port}`;
 process.env.ROUTING_GRAPH_CDN_BASE=local+'/v4/candidates/fabric-v4-20260908-02';
 process.env.R2_REGION_BASE_OVERRIDES=JSON.stringify({ns:process.env.ROUTING_GRAPH_CDN_BASE,nb:process.env.ROUTING_GRAPH_CDN_BASE});
 process.env.ROUTING_VERIFIED_GRAPH_PATH_OVERRIDES=JSON.stringify(Object.fromEntries(['ns','nb'].map(r=>[r,path.join(root,r,'graph.v4.bin')])));
 process.env.ROUTING_USE_REGIONAL='1';process.env.DIRT_V4_REGIONS='ns,nb';process.env.DIRT_ADVENTURE_CANARY='ns-nb-v1';
 process.env.SOURCE_VERSION=process.env.RECOVERY_JS_REVISION;
 handlers={'route':require(path.join(code,'api/route')),'fuel-chain':require(path.join(code,'api/fuel-chain'))};
 const summary=[];
 try {
  for(const scenario of cases.scenarios)for(const profile of cases.profiles){
   active=`${scenario.id}-${profile}`;serial=0;
   const result=await new Promise(resolve=>{
    const child=spawn(process.execPath,[path.join(__dirname,'run-routing-oracle.js'),'--scenario',scenario.id,'--profile',profile],{env:{...process.env,DIRT_API_ROOT:local+'/api'}});
    let stdout='',stderr='';child.stdout.on('data',b=>stdout+=b);child.stderr.on('data',b=>stderr+=b);
    child.on('exit',exitCode=>resolve({exitCode,stdout,stderr}));
   });
   fs.writeFileSync(path.join(out,active+'-oracle.json'),JSON.stringify(result));
   summary.push({id:active,...result});console.log(JSON.stringify({id:active,exitCode:result.exitCode}));
   fs.writeFileSync(path.join(out,'summary.json'),JSON.stringify({source:process.env.RECOVERY_JS_REVISION,method:'Unchanged run-routing-oracle.js; local historical API handlers; accepted V4 NS/NB bytes',summary},null,2));
  }
 } finally { server.closeAllConnections();server.close(); }
})().catch(e=>{console.error(e);server.close();process.exitCode=1});
