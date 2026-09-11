'use strict';
// Tiny isolated OSM graphs, independent JS turn oracle, and the real Swift gate.
// No published fixture or pack path is written.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),cp=require('node:child_process');
const {buildGraphFromOsm}=require('../../../pack-fabric/routing/lib/legal-topology/osm-graph');
const {encodeFromOsmGraph,decodeGraphV4}=require('../../../pack-fabric/routing/lib/pack-v4');
const {createV4Graph}=require('../../../pack-fabric/routing/lib/adventure/v4-graph');
const [binary,out]=process.argv.slice(2); if(!binary||!out||fs.existsSync(out))throw Error('Supply binary and NEW output directory');
fs.mkdirSync(out,{recursive:true});
const sha=x=>crypto.createHash('sha256').update(x).digest('hex'), clone=x=>JSON.parse(JSON.stringify(x));
const points={1:[-63,45],2:[-63+1/1024,45],3:[-63+2/1024,45],4:[-63+3/1024,45],5:[-63+1/1024,45+1/1024],6:[-63+2/1024,45+1/1024]};
function fixture(name,relation,overrides={}){
 const ways=[[10,1,2],[20,2,3],[30,3,4],[40,5,2],[50,3,6]].map(([id,a,b])=>({id,nodeIds:[a,b],tags:{highway:'residential',surface:'asphalt',motorcycle:'yes',...overrides[id]}}));
 const osm={nodes:Object.entries(points).map(([id,p])=>({id:+id,lon:p[0],lat:p[1],tags:{}})),ways,relations:relation?[{id:100,type:'relation',tags:{type:'restriction',[relation.key||'restriction']:relation.kind},members:[{type:'way',ref:10,role:'from'},...relation.via.map(([type,ref])=>({type,ref,role:'via'})),{type:'way',ref:relation.to,role:'to'}]}]:[]};
 const data=encodeFromOsmGraph(buildGraphFromOsm(osm),{regionId:'fix',sourceEpoch:'isolated-continuity-fixture'});
 const dir=path.join(out,name);fs.mkdirSync(dir);
 fs.writeFileSync(path.join(dir,'graph.v4.bin'),data.graphBuffer);fs.writeFileSync(path.join(dir,'geometry.v1.bin'),data.geomBuffer);
 const pack=decodeGraphV4(data.graphBuffer,data.geomBuffer), identity=sha(Buffer.concat([data.graphBuffer,data.geomBuffer]));
 function edge(way,reverse=false){
  const e=Array.from(pack.osmWayIds).findIndex(x=>Number(x)===way);if(e<0)throw Error('Way absent '+way);
  const from=reverse?pack.edgeTo[e]:pack.edgeFrom[e],to=reverse?pack.edgeFrom[e]:pack.edgeTo[e];
  return {edgeId:pack.edgeId(e),edgeIndex:e,fromNode:from,toNode:to,meters:pack.edgeMeters[e],surface:'paved',coordinates:[[pack.nodeCoords[from*2],pack.nodeCoords[from*2+1]],[pack.nodeCoords[to*2],pack.nodeCoords[to*2+1]]]};
 }
 return {dir,pack,identity,edge};
}
function payload(f,groups){
 const refills=groups.slice(0,-1).map((g,i)=>({id:'fuel-'+i,point:g.at(-1).coordinates.at(-1)}));
 const fuel=Buffer.from(JSON.stringify({schema:'fuel.v1',stations:refills.map(x=>({id:x.id,lon:x.point[0],lat:x.point[1],name:x.id}))}));
 fs.writeFileSync(path.join(f.dir,'fuel.v1.json'),fuel);
 return {packIdentity:f.identity,fuelIdentity:sha(fuel),profile:'dirt',allowUnknown:false,rangeMeters:1000,firstMeters:1000,minimumStops:1,excludedStationIds:[],refills,
  start:groups[0][0].coordinates[0],end:groups.at(-1).at(-1).coordinates.at(-1),
  routes:groups.map(legs=>({state:'found',searchTimedOut:false,query:{start:legs[0].coordinates[0],end:legs.at(-1).coordinates.at(-1),profile:'dirt',allowUnknown:false},distanceMeters:legs.reduce((a,l)=>a+l.meters,0),legs}))};
}
function oracle(f,p,reset){
 let graph=createV4Graph(f.pack,{allowUnknown:p.allowUnknown,endpointEdges:[]}),state=0,previous;
 for(const route of p.routes){if(reset){state=0;previous=null;}
  for(const leg of route.legs){
   if(leg.edgeId.startsWith('soft-stitch')||leg.fromNode==null)continue;
   if(previous&&previous.to!==leg.fromNode)return false;
   const arc={id:leg.edgeIndex,key:leg.edgeIndex*2+(leg.fromNode===f.pack.edgeFrom[leg.edgeIndex]?0:1),from:leg.fromNode,to:leg.toNode,distanceMeters:leg.meters};
   let eligible=false;graph.forEachOutgoing(arc.from,a=>{if(a.id===arc.id&&a.to===arc.to)eligible=true;});if(!eligible)return false;
   const t=graph.transition(state,arc);if(!t.allowed)return false;state=t.state;previous=arc;
  }
 }
 return true;
}
const reports=[];
function check(name,f,p,accepted,error,expectedOracle){
 const artifact=path.join(f.dir,name+'.case');fs.mkdirSync(artifact);
 for(const asset of ['graph.v4.bin','geometry.v1.bin','fuel.v1.json'])fs.copyFileSync(path.join(f.dir,asset),path.join(artifact,asset));
 const file=path.join(artifact,'input.json');fs.writeFileSync(file,JSON.stringify(p));
 const proc=cp.spawnSync(binary,['--audit',artifact,file],{encoding:'utf8',timeout:20000});
 if(proc.status!==0)throw Error(name+' crashed: '+proc.stderr);
 const result=JSON.parse(proc.stdout.trim().split('\n').at(-1));
 const continuous=oracle(f,p,false),separate=oracle(f,p,true);
 const passed=result.accepted===accepted&&(!error||result.errors.some(x=>x.includes(error)))&&(expectedOracle===undefined||continuous===expectedOracle);
 reports.push({name,artifact,passed,expectedAccepted:accepted,continuousJSOracle:continuous,separateLegJSOracle:separate,result});
 if(!passed)console.error(JSON.stringify(reports.at(-1)));
}
const legal=fixture('legal');const l=legal.edge;
let p=payload(legal,[[l(10)],[l(20),l(30)]]);check('legal-public-fuel',legal,p,true,undefined,true);
const badNode=fixture('node-no',{kind:'no_straight_on',via:[['node',2]],to:20});
p=payload(badNode,[[badNode.edge(10)],[badNode.edge(20),badNode.edge(30)]]);check('forbidden-node-turn-at-refill',badNode,p,false,'illegal_continuation',false);
const badVia=fixture('via-no',{kind:'no_straight_on',via:[['way',20]],to:30});
p=payload(badVia,[[badVia.edge(10),badVia.edge(20)],[badVia.edge(30)]]);check('forbidden-via-way-across-refill',badVia,p,false,'illegal_continuation',false);
p=payload(badVia,[[badVia.edge(40),badVia.edge(20)],[badVia.edge(30)]]);check('other-approach-to-same-via-remains-legal',badVia,p,true,undefined,true);
const only=fixture('via-only',{kind:'only_straight_on',via:[['way',20]],to:30});
p=payload(only,[[only.edge(10),only.edge(20)],[only.edge(30)]]);check('required-via-continuation',only,p,true,undefined,true);
p=payload(only,[[only.edge(10),only.edge(20)],[only.edge(50)]]);check('forbidden-only-turn-escape',only,p,false,'illegal_continuation',false);
const vehicle=fixture('motor-vehicle-scope',{key:'restriction:motor_vehicle',kind:'no_straight_on',via:[['node',2]],to:20});
p=payload(vehicle,[[vehicle.edge(10)],[vehicle.edge(20),vehicle.edge(30)]]);check('unsupported-vehicle-mask-fails-closed',vehicle,p,false,'unsupported_restriction_vehicle_scope');
const oneway=fixture('oneway',null,{20:{oneway:'yes'}});
p=payload(oneway,[[oneway.edge(20,true)],[oneway.edge(10,true)]]);check('oneway-cannot-reverse-at-fuel',oneway,p,false,'ambiguous_or_illegal_direction',false);
const denied=fixture('denied',null,{20:{motorcycle:'private'}});
p=payload(denied,[[denied.edge(10)],[denied.edge(20),denied.edge(30)]]);check('private-road-remains-denied',denied,p,false,'ambiguous_or_illegal_direction',false);
p=payload(legal,[[l(10)],[l(20),l(30)]]);
for(const [name,edit,error] of [
 ['reduced-start-range',q=>q.firstMeters=10,'fuel_range_exceeded'],
 ['excluded-station',q=>q.excludedStationIds=['fuel-0'],'unknown_excluded'],
 ['required-station',q=>q.requiredFirstStationId='elsewhere','required_first'],
 ['minimum-stops',q=>q.minimumStops=2,'missing_required'],
 ['wrong-pack',q=>q.packIdentity='bad','invalid_identity'],
 ['wrong-fuel',q=>q.fuelIdentity='bad','invalid_identity'],
 ['unsupported-history',q=>q.arrivalHistory=['other'],'invalid_identity'],
 ['unfinished-leg',q=>q.routes[0].searchTimedOut=true,'invalid_or_unfinished'],
 ['changed-profile',q=>q.routes[0].query.profile='balanced','invalid_or_unfinished'],
 ['forged-short-meters',q=>{q.rangeMeters=q.firstMeters=5;q.routes.forEach(r=>{r.legs.forEach(e=>e.meters=1);r.distanceMeters=r.legs.length;});},'source_fuel_range_exceeded'],
 ]){const q=clone(p);edit(q);check(name,legal,q,false,error);}
const half=l(20),mid=half.coordinates[0].map((v,i)=>(v+half.coordinates[1][i])/2),a={...half,fromNode:null,toNode:null,meters:half.meters/2,coordinates:[half.coordinates[0],mid]},b={...half,fromNode:null,toNode:null,meters:half.meters/2,coordinates:[mid,half.coordinates[1]]};
p=payload(legal,[[l(10),a],[b,l(30)]]);check('same-edge-fuel-split',legal,p,true);
const reversal={...b,coordinates:[mid,half.coordinates[0]]};
p=payload(legal,[[l(10),a],[reversal,l(40,true)]]);check('unproved-mid-edge-turnaround',legal,p,false,'disconnected_or_unproved');
// A fuel coordinate alone cannot turn an unmapped straight line into access.
p=payload(legal,[[l(10)],[l(20),l(30)]]);
const original=p.refills[0].point,off=[original[0],original[1]+1/2048];p.refills[0].point=off;
const fuel=Buffer.from(JSON.stringify({schema:'fuel.v1',stations:[{id:'fuel-0',lon:off[0],lat:off[1]}]}));fs.writeFileSync(path.join(legal.dir,'fuel.v1.json'),fuel);p.fuelIdentity=sha(fuel);
const stitch=(coords)=>({edgeId:'soft-stitch-fuel',meters:55,coordinates:coords});
p.routes[0].query.end=off;p.routes[0].legs.push(stitch([original,off]));p.routes[0].distanceMeters+=55;
p.routes[1].query.start=off;p.routes[1].legs.unshift(stitch([off,original]));p.routes[1].distanceMeters+=55;
check('unmapped-pump-approach',legal,p,false);
const result={passed:reports.every(x=>x.passed),checks:reports.length,reports,scope:'Isolated OSM fixture bytes. Continuous JS restriction oracle versus actual Swift publication gate; not real station access or full phone fuel qualification.'};
fs.writeFileSync(path.join(out,'result.json'),JSON.stringify(result,null,2));console.log(JSON.stringify({passed:result.passed,checks:reports.length,out}));if(!result.passed)process.exitCode=1;
