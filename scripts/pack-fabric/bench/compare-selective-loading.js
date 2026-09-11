'use strict';
// LOCAL/PRIVATE ONLY. No API route imports this experiment.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),v8=require('node:v8');
const {spawnSync}=require('node:child_process');
const {decodeGraphV4,decodeGeometryV1}=require('../routing/lib/pack-v4');
const {buildFromHere}=require('../routing/lib/adventure/from-here');
const {createBudget}=require('../routing/lib/adventure/budget');
const {surfaceKind}=require('../routing/lib/adventure/surface');
const {buildUrbanExposure}=require('../routing/lib/adventure/urban-exposure');
const {createPreparationCache}=require('../routing/lib/adventure/preparation-cache');
const {createReverseCostCache}=require('../routing/lib/adventure/reverse-cost-cache');
const {createStationMatchCache}=require('../routing/lib/adventure/station-match-cache');
const {createTargetBoundsCache}=require('../routing/lib/adventure/target-bounds-cache');
const {buildIndexData,restoreIndex}=require('./working-set/spatial-index');
const {openGeometry}=require('./working-set/geometry');
const {openGraph}=require('./working-set/demand-graph');
const {joinV4}=require('../routing/lib/adventure/join-v4');
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
const work=()=>createBudget({deadlineAtMs:Date.now()+120000,maxExpansions:200000000});
const defaultAnchors=[{id:'a',lat:44.76481,lon:-63.34024},{id:'b',lat:45.39330,lon:-62.18066}];
function identityOne(root) {
  // Streaming verification is separately charged. It still reads EVERY byte;
  // only a trusted immutable install receipt could remove this per-process pass.
  const at=performance.now(),ids={},block=Buffer.alloc(1024*1024);let bytes=0;
  for(const file of ['graph.v4.bin','geometry.v1.bin','fuel.v1.json']) {
    const fd=fs.openSync(path.join(root,file),'r'),h=crypto.createHash('sha256');
    try {let n;while((n=fs.readSync(fd,block,0,block.length,null))){h.update(block.subarray(0,n));bytes+=n;}}
    finally {fs.closeSync(fd);}ids[file]=h.digest('hex');
  }
  return {ids,bytes,ms:performance.now()-at};
}
function identity(root) {
  const regions=root.split(',').map(directory=>({directory,...identityOne(directory)}));
  return {regions,ids:regions.map(r=>r.ids),bytes:regions.reduce((n,r)=>n+r.bytes,0),ms:regions.reduce((n,r)=>n+r.ms,0)};
}
function load(root,checked,capacity=0,demand=false) {
  const regions=[],stations=new Map();let readBytes=0;
  for(const [i,directory] of root.split(',').entries()) {
    let pack,reader;
    if(demand) {reader=openGraph(path.join(directory,'graph.v4.bin'),Math.floor(capacity/checked.regions.length)*64,checked.ids[i]['geometry.v1.bin']);pack=reader.pack;}
    else {
      const g=fs.readFileSync(path.join(directory,'graph.v4.bin'));readBytes+=g.length;
      if(g.subarray(g.readUInt32LE(136),g.readUInt32LE(136)+32).toString('hex')!==checked.ids[i]['geometry.v1.bin'])throw new Error('Graph/geometry mismatch');
      pack=decodeGraphV4(g);
    }
    const geom=capacity?openGeometry(path.join(directory,'geometry.v1.bin'),Math.floor(capacity/checked.regions.length)):
      decodeGeometryV1(fs.readFileSync(path.join(directory,'geometry.v1.bin')));
    if(!capacity)readBytes+=fs.statSync(path.join(directory,'geometry.v1.bin')).size;
    const f=fs.readFileSync(path.join(directory,'fuel.v1.json'));readBytes+=f.length;
    for(const s of JSON.parse(f).stations) {
      const prior=stations.get(s.id);
      if(prior&&(prior.lat!==s.lat||prior.lon!==s.lon))throw new Error('Conflicting shared station');
      stations.set(s.id,s);
    }
    regions.push({pack,geom,reader});
  }
  const at=performance.now(),joined=regions.length>1?joinV4(regions,{budget:work()}):regions[0],joinMs=performance.now()-at;
  if(capacity)Object.defineProperty(joined.geom,'workingSetStats',{get(){
    const sum={};for(const r of regions)for(const [key,value] of Object.entries(r.geom.stats))sum[key]=(sum[key]||0)+value;
    return sum;
  }});
  return {...joined,joinMs,readBytes,topologyStats:()=>regions.map(r=>r.reader?.stats||null),stations:[...stations.values()],close(){for(const r of regions){r.geom.close?.();r.reader?.close();}}};
}
function preparedCache(data) {
  let entry=null;
  return {prepare({pack,geom,revision,areas,budget}) {
    const key=JSON.stringify(areas);
    if(!budget.check())return {state:'incomplete',reason:budget.snapshot().reason};
    if(entry&&entry.pack===pack&&entry.geom===geom&&entry.revision===revision&&entry.key===key)
      return {state:'complete',cacheHit:true,prepared:entry.prepared};
    const index=restoreIndex(data,pack,geom),urban=buildUrbanExposure({pack,geom,areas,budget,index});
    if(urban.state!=='complete')return urban;
    const prepared={index,urban,revision};entry={pack,geom,revision,key,prepared};
    return {state:'complete',cacheHit:false,prepared};
  }};
}
function invoke(args) {
  const r=spawnSync(process.execPath,['--expose-gc',__filename,...args],{encoding:'utf8',timeout:300000,maxBuffer:4*1024*1024});
  if(r.status!==0)throw new Error(r.stderr||String(r.error)||r.stdout);
  return JSON.parse(r.stdout);
}
if(!process.argv[2]?.startsWith('--')) {
  const [root,out]=process.argv.slice(2);
  if(!root||!out)throw new Error('Usage: node bench/compare-selective-loading.js PACK_DIRECTORY OUTPUT.json');
  const artifact=out+'.index',prepared=invoke(['--prepare',root,artifact]);
  console.log(JSON.stringify({prepared}));
  const rows=[];
  for(const mode of (process.env.PAGING_MODES||'full,indexed-full,indexed-5000,indexed-10000,indexed-30000,demand-5000,demand-10000,demand-30000').split(',')) {
    const row=invoke(['--run',root,artifact,mode,prepared.artifactSha256]);rows.push(row);console.log(JSON.stringify(row));
  }
  const baseline=rows[0];
  if(baseline.mode!=='full')throw new Error('A full baseline must run first');
  for(const row of rows)for(let i=0;i<row.runs.length;i++) {
    const r=row.runs[i],b=baseline.runs[i];
    r.matchesBaseline=r.signature===b.signature;
    r.fuelCoverageComplete=r.road==='complete'&&['verified','provisional_station_access'].includes(r.fuel);
    if(!r.matchesBaseline||!r.fuelCoverageComplete)process.exitCode=1;
  }
  fs.writeFileSync(out,JSON.stringify({scope:'Private geometry/topology paging + persistent exact spatial preparation. Demand topology uses a separate byte cap (64 bytes per geometry-cap edge), not a bound on unique explored road IDs. Restrictions, fuel, and spatial/reverse indexes remain resident. Current preparation and joins still touch the whole topology. Fresh-process verification reads all source bytes. Local filesystem measurements are not remote range-request costs or live qualification.',prepared,config:{directories:root.split(','),anchors:JSON.parse(process.env.PAGING_ANCHORS||JSON.stringify(defaultAnchors)),
      usableMeters:Number(process.env.PAGING_USABLE_METERS||162000),edit:JSON.parse(process.env.PAGING_EDIT_ANCHOR||'null'),
      overrides:JSON.parse(process.env.PAGING_OPTIONS||'{}'),modes:rows.map(r=>r.mode)},rows},null,2));
} else if(process.argv[2]==='--prepare') {
  const root=process.argv[3],out=process.argv[4],at=performance.now(),checked=identity(root);
  const loaded=load(root,checked),{pack,geom}=loaded,data=buildIndexData(pack,geom,work());
  if(data.state!=='complete')throw new Error('Incomplete spatial preparation');
  const artifact=v8.serialize({schema:1,identity:checked.ids,data});fs.writeFileSync(out,artifact);
  console.log(JSON.stringify({identity:checked.ids,ms:performance.now()-at,verification:checked,readBytes:checked.bytes+loaded.readBytes,
    joinMs:loaded.joinMs,artifactBytes:artifact.length,artifactSha256:hash(artifact),peakProcessMiB:process.resourceUsage().maxRSS/1024}));
} else {
  const root=process.argv[3],artifact=process.argv[4],mode=process.argv[5],at=performance.now(),checked=identity(root);
  const cap=Number(mode.split('-')[1]),paged=Number.isFinite(cap)&&cap>0;
  const loaded=load(root,checked,paged?cap:0,mode.startsWith('demand-')),{pack,geom,stations}=loaded;
  let data=null,indexBytes=0;
  if(mode!=='full') {
    const bytes=fs.readFileSync(artifact);
    if(hash(bytes)!==process.argv[6])throw new Error('Corrupt preparation artifact');
    const record=v8.deserialize(bytes);indexBytes=bytes.length;
    if(record.schema!==1||JSON.stringify(record.identity)!==JSON.stringify(checked.ids))throw new Error('Stale preparation identity');
    data=record.data;
  }
  const preparationCache=data?preparedCache(data):createPreparationCache(),reverseCostCache=createReverseCostCache(),
    stationMatchCache=createStationMatchCache(),avoidanceBoundsCache=createTargetBoundsCache();
  const edgeCost=a=>a.distanceMeters*(surfaceKind(a.surfaceLeaf)==='dirt'?1:30);
  global.gc();const loadMs=performance.now()-at,rssAfterLoadMiB=process.memoryUsage().rss/1048576;
  const anchors=process.env.PAGING_ANCHORS?JSON.parse(process.env.PAGING_ANCHORS):defaultAnchors;
  const usable=Number(process.env.PAGING_USABLE_METERS||162000),runs=[];
  const edit=process.env.PAGING_EDIT_ANCHOR?JSON.parse(process.env.PAGING_EDIT_ANCHOR):null;
  for(let repeat=0;repeat<(edit?3:2);repeat++) {
    const selected=repeat===2?[anchors[0],{...edit,id:'b'}]:anchors;
    const before=performance.now(),prior={...geom.workingSetStats};
    const result=buildFromHere({input:{mode:'from_here',anchors:selected,legs:[{from:'a',to:'b',profile:'dirt',allowUnknown:false}],
      fuel:{fullRangeMeters:usable,reserveFraction:0,initialUsableMeters:usable}},pack,geom,stations,revision:hash(JSON.stringify(checked.ids)),
      objectiveId:'dirt-30',edgeCost,fuelHeuristicWeight:2,maxFuelLabels:400000,fuelFirst:true,allowPassingRefillAdvisory:true,
      allowRepeatedPassingRoute:true,useAvoidanceLowerBounds:true,...JSON.parse(process.env.PAGING_OPTIONS||'{}'),budget:work(),preparationCache,reverseCostCache,stationMatchCache,avoidanceBoundsCache});
    const proof={road:result.road,stops:result.fuel.plannedRefills,escape:result.fuel.destinationEscape};
    runs.push({kind:repeat===0?'cold-request':repeat===1?'identical-repeat':'edited-destination',searchMs:performance.now()-before,
      road:result.road.state,fuel:result.fuel.state,reason:result.fuel.reason,stage:result.stage,distanceMeters:result.road.distanceMeters,
      stops:result.fuel.plannedRefills?.map(s=>s.stationId||s.id||s),timing:result.timing,signature:hash(JSON.stringify(proof)),
      geometry:paged?{...geom.workingSetStats,requestBytes:geom.workingSetStats.bytesRead-prior.bytesRead,requestReads:geom.workingSetStats.reads-prior.reads}:null,
      cacheHits:{preparation:result.provenance.preparationCacheHit,stations:result.provenance.stationMatchingCacheHit,reverse:result.provenance.reversePreparationCacheHit},
      topology:structuredClone(loaded.topologyStats()),reverse:reverseCostCache.diagnostics(),rssMiB:process.memoryUsage().rss/1048576});
  }
  const sourceBytes=checked.regions.map(r=>Object.fromEntries(Object.keys(r.ids).map(file=>[file,fs.statSync(path.join(r.directory,file)).size])));
  console.log(JSON.stringify({mode,identity:checked.ids,edges:pack.edgeCount,nodes:pack.nodeCount,sourceBytes,verification:checked,
    loadMs,joinMs:loaded.joinMs,loadedReadBytes:loaded.readBytes,rssAfterLoadMiB,indexBytes,peakProcessMiB:process.resourceUsage().maxRSS/1024,runs}));loaded.close();
}
