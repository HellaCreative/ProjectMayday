'use strict';
const fs=require('node:fs'),path=require('node:path'),cp=require('node:child_process');
const {buildGraphFromOsm}=require('../../../pack-fabric/routing/lib/legal-topology/osm-graph');
const {encodeFromOsmGraph}=require('../../../pack-fabric/routing/lib/pack-v4');
const [binary,out]=process.argv.slice(2);if(!binary||!out||fs.existsSync(out))throw Error('Supply binary and NEW output directory');fs.mkdirSync(out,{recursive:true});
const cases=[
 {name:'curved-road-outside-endpoint-box',poly:[[-63,45],[-63,45.4],[-62.99,45]],point:[-63.0001,45.3999],found:true,legacy:false},
 {name:'near-pole-longitude-radius',poly:[[0.9,89.9],[1.1,89.9]],point:[0,89.9],found:true,legacy:false},
 {name:'broad-edge-allocation-bound',poly:[[-120,-30],[120,30]],point:[0,0],found:true},
 {name:'no-nearby-road',poly:[[-63,45],[-62.99,45]],point:[-64,44],found:false,legacy:false}
];
const reports=[];
for(const test of cases){
 const dir=path.join(out,test.name);fs.mkdirSync(dir);
 const osm={nodes:test.poly.map(([lon,lat],i)=>({id:i+1,lon,lat,tags:{}})),ways:[{id:10,nodeIds:test.poly.map((_,i)=>i+1),tags:{highway:'residential',surface:'asphalt',motorcycle:'yes'}}],relations:[]};
 const data=encodeFromOsmGraph(buildGraphFromOsm(osm),{regionId:'fix',sourceEpoch:'private-index-fixture'});
 fs.writeFileSync(path.join(dir,'graph.v4.bin'),data.graphBuffer);fs.writeFileSync(path.join(dir,'geometry.v1.bin'),data.geomBuffer);
 fs.writeFileSync(path.join(dir,'fuel.v1.json'),JSON.stringify({stations:[{id:'test-fuel',lon:test.point[0],lat:test.point[1]}]}));
 const spec=path.join(dir,'query.json');fs.writeFileSync(spec,JSON.stringify({profile:'cleanest',passes:2}));
 for(const mode of ['legacy','indexed','cached']){
  const run=cp.spawnSync(binary,['--fixture-matches',dir,spec,'5'],{encoding:'utf8',timeout:15000,env:{...process.env,DIRT_FUEL_PREPARATION:mode}});
  if(run.status!==0)throw Error(test.name+' '+run.stderr);
  fs.writeFileSync(path.join(dir,mode+'.jsonl'),run.stdout);
  const rows=run.stdout.trim().split('\n').map(JSON.parse),matches=rows.filter(x=>x.stage==='match');
  const expected=mode==='legacy'&&test.legacy!==undefined?test.legacy:test.found;
  const passed=matches.length===2&&matches.every(x=>(x.matches.length>0)===expected)&&JSON.stringify(matches[0].matches)===JSON.stringify(matches[1].matches);
  reports.push({name:test.name,mode,passed,matches:matches[0]?.matches,metrics:rows.at(-1).preparation});
 }
}
const result={passed:reports.every(x=>x.passed),checks:reports.length,reports};fs.writeFileSync(path.join(out,'result.json'),JSON.stringify(result,null,2));console.log(JSON.stringify({passed:result.passed,checks:reports.length,out}));if(!result.passed)process.exitCode=1;
