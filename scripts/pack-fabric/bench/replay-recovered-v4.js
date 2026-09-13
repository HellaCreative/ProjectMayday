"use strict";
// Read-only replay. Pass an exported historical scripts/pack-fabric directory;
// no hosted API or mutable pack catalog is used.
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const code = path.resolve(process.env.RECOVERY_JS_ROOT);
const root = path.resolve(process.env.DIRT_PACK_ROOT);
const output = path.resolve(process.env.RECOVERY_OUTPUT);
const {decodeGraphV4} = require(path.join(code, 'routing/lib/pack-v4'));
const {decodeGeometryV1} = require(path.join(code, 'routing/lib/pack-v2'));
const {adventureCanaryRequest} = require(path.join(code, 'routing/lib/adventure/live-canary'));
const {joinV4} = require(path.join(code, 'routing/lib/adventure/join-v4'));
const {createBudget} = require(path.join(code, 'routing/lib/adventure/budget'));
const cases = require('./routing-oracle-cases.json');
const expectedRelease = process.env.RECOVERY_PACK_RELEASE || 'fabric-v4-20260908-02';
const cache = new Map(), joins = new Map();
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
function loadRegion(id) {
  if (cache.has(id)) return cache.get(id);
  const dir = path.join(root,id), manifest = JSON.parse(fs.readFileSync(path.join(dir,'pack-manifest.v2.json')));
  if (manifest.fabricReleaseId !== expectedRelease) throw Error('Unexpected pack identity '+id);
  for (const key of ['graph','geometry','fuel','seams']) {
    const file = manifest[key];
    if (!file) throw Error('Missing manifest identity '+key);
    const bytes = fs.readFileSync(path.join(dir,file.name));
    if(bytes.length !== file.bytes || sha(bytes) !== file.sha256) throw Error('Pack checksum mismatch '+id+'/'+file.name);
  }
  const graph = fs.readFileSync(path.join(dir,'graph.v4.bin')), geometry = fs.readFileSync(path.join(dir,'geometry.v1.bin')), fuel = fs.readFileSync(path.join(dir,'fuel.v1.json'));
  const data = {pack:decodeGraphV4(graph,geometry),geom:decodeGeometryV1(geometry),stations:JSON.parse(fuel).stations,identity:[{regionId:id,releaseId:manifest.fabricReleaseId,graphSha256:sha(graph),geometrySha256:sha(geometry),fuelSha256:sha(fuel)}]};
  cache.set(id,data); return data;
}
async function load(resolution) {
  const key = resolution.regionIds.join(','); if (joins.has(key)) return joins.get(key);
  const rows = resolution.regionIds.map(loadRegion);
  if (rows.length===1) return rows[0];
  const joined = joinV4(rows,{budget:createBudget({deadlineAtMs:Date.now()+20000,maxExpansions:20000000})});
  const stations = [...new Map(rows.flatMap(r=>r.stations).map(s=>[s.id,s])).values()];
  const data = {...joined,stations,identity:rows.flatMap(r=>r.identity)}; joins.set(key,data);return data;
}
(async()=>{
 fs.mkdirSync(output,{recursive:true}); const summary=[];
 for (const scenario of cases.scenarios) for (const profile of cases.profiles) for (const kind of ['route','fuel']) {
  const id = `${scenario.id}-${profile}-${kind}`;
  const usable = cases.tankRangeKm*1000*(1-cases.reservePercent/100);
  const body={profile,locations:[scenario.from,scenario.to],vehicle:'dual-sport-motorcycle',accessPolicy:{motorizedPermissive:true,motorizedUnknown:false},options:{sessionSeed:cases.sessionSeed,avoidMotorways:profile==='cleanest',backtrackFactor:4}};
  if(kind==='fuel') body.fuel={usableRangeMeters:usable,firstLegMaxMeters:usable,windowMaxStops:16,windowTimeBudgetMs:20000,routeFirstPlan:true,ensureDestinationFuelEscape:true};
  const began=Date.now();let result;
  try { result=await adventureCanaryRequest(body,kind,{environment:{DIRT_ADVENTURE_CANARY:'ns-nb-v1'},load}); }
  catch(e){result={status:'error',error:String(e)}}
  fs.writeFileSync(path.join(output,id+'.json'),JSON.stringify({source:process.env.RECOVERY_JS_REVISION,body,result}));
  const routes=kind==='route'&&result?.status==='complete'?[result]:result?.routes||[];
  const meters=routes.reduce((n,r)=>n+(r.distanceMeters||0),0);
  const row={id,ms:Date.now()-began,status:result?.status||'unsupported',error:result?.error,meters,dirtPercent:meters?routes.reduce((n,r)=>n+(r.distanceMeters||0)*(r.stats?.dirtPercent||0),0)/meters:null,stops:result?.stops?.map(s=>s.id)||[],windowComplete:result?.windowComplete,shapeSHA256:sha(JSON.stringify(routes.map(r=>r.geometry))),diagnostics:result?.diagnostics||result?.debug?.diagnostics};
  summary.push(row);console.log(JSON.stringify({...row,diagnostics:undefined}));
  fs.writeFileSync(path.join(output,'summary.json'),JSON.stringify({source:process.env.RECOVERY_JS_REVISION,cases,identity:[...cache.values()].flatMap(r=>r.identity),summary},null,2));
 }
})().catch(e=>{console.error(e);process.exitCode=1});
