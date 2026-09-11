'use strict';
// Local experiment only. Pages unchanged geometry bytes, not topology or fuel data.
// Missing pages are read on demand; no road is excluded by the working-set cap.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {spawnSync}=require('node:child_process');
const {decodeGraphV4,decodeGeometryV1}=require('../routing/lib/pack-v4');
const {buildFromHere}=require('../routing/lib/adventure/from-here');
const {createBudget}=require('../routing/lib/adventure/budget');
const {surfaceKind}=require('../routing/lib/adventure/surface');
function pagedGeometry(file,capacity){
 const fd=fs.openSync(file,'r'),head=Buffer.alloc(16);fs.readSync(fd,head,0,16,0);
 const count=head.readUInt32LE(8),offsetBytes=Buffer.alloc((count+1)*4);
 fs.readSync(fd,offsetBytes,0,offsetBytes.length,16);
 const offsets=new Uint32Array(offsetBytes.buffer,offsetBytes.byteOffset,count+1);
 const dataAt=16+offsetBytes.length,pageEdges=1000,pages=new Map();
 const stats={reads:0,bytesRead:0,residentBytes:0,peakResidentBytes:0,peakResidentEdges:0};
 function range(e){
  if(!Number.isInteger(e)||e<0||e>=count)throw Error('Invalid geometry edge');
  const key=Math.floor(e/pageEdges);let page=pages.get(key);
  if(page){pages.delete(key);pages.set(key,page);}
  else{
   while(pages.size>=capacity/pageEdges){const first=pages.keys().next().value;stats.residentBytes-=pages.get(first).buffer.length;pages.delete(first);}
   const first=key*pageEdges,last=Math.min(count,first+pageEdges),start=offsets[first],end=offsets[last];
   const buffer=Buffer.alloc((end-start)*4);let read=0;
   while(read<buffer.length){const n=fs.readSync(fd,buffer,read,buffer.length-read,dataAt+start*4+read);if(!n)throw Error('Truncated geometry');read+=n;}
   page={buffer,start,coords:new Float32Array(buffer.buffer,buffer.byteOffset,buffer.length/4)};pages.set(key,page);
   stats.reads++;stats.bytesRead+=buffer.length;stats.residentBytes+=buffer.length;
   stats.peakResidentBytes=Math.max(stats.peakResidentBytes,stats.residentBytes);
   stats.peakResidentEdges=Math.max(stats.peakResidentEdges,Math.min(count,pages.size*pageEdges));
  }
  return {coords:page.coords,start:offsets[e]-page.start,end:offsets[e+1]-page.start};
 }
 return {coordinateRange:range,polyline(e){const r=range(e),out=[];for(let i=r.start;i<r.end;i+=2)out.push([r.coords[i],r.coords[i+1]]);return out;},stats,close(){fs.closeSync(fd);}};
}
if(process.argv[2]!=='--child'){
 const [root,out]=process.argv.slice(2);if(!root||!out)throw Error('Usage: node --expose-gc bench/compare-geometry-working-set.js PACK_DIRECTORY OUTPUT');
 const rows=[];
 for(const cap of [0,5000,10000,30000]){
  const run=spawnSync(process.execPath,['--expose-gc',__filename,'--child',root,String(cap)],{encoding:'utf8',timeout:180000,maxBuffer:1024*1024});
  if(run.status!==0)throw Error(run.stderr||run.error||run.stdout);
  const row=JSON.parse(run.stdout);rows.push(row);console.log(JSON.stringify(row));
 }
 const baseline=rows[0];for(const row of rows){row.matchesBaseline=row.signature===baseline.signature;if(!row.matchesBaseline||row.road!=='complete'||!['provisional_station_access','verified'].includes(row.fuel))process.exitCode=1;}
 fs.writeFileSync(out,JSON.stringify({scope:'Geometry-only local disk paging; graph, indexes, restrictions and fuel remain resident. Not a corridor or production performance qualification.',rows},null,2));
}else{
 const root=process.argv[3],cap=Number(process.argv[4]),at=performance.now();
 const file=path.join(root,'geometry.v1.bin');let geometryBytes=fs.readFileSync(file);
 const graphBytes=fs.readFileSync(path.join(root,'graph.v4.bin'));
 const pack=decodeGraphV4(graphBytes,geometryBytes),identity=crypto.createHash('sha256').update(graphBytes).digest('hex');
 const geom=cap?pagedGeometry(file,cap):decodeGeometryV1(geometryBytes);geometryBytes=null;global.gc();
 const loadMs=performance.now()-at,residentAfterLoad=process.memoryUsage().rss;
 const stations=JSON.parse(fs.readFileSync(path.join(root,'fuel.v1.json'))).stations;
 const start=performance.now(),deadlineAtMs=Date.now()+120000;
 const anchors=process.env.PAGING_ANCHORS?JSON.parse(process.env.PAGING_ANCHORS):[{id:'a',lat:44.76481,lon:-63.34024},{id:'b',lat:45.39330,lon:-62.18066}];
 const usable=Number(process.env.PAGING_USABLE_METERS||162000);
 const result=buildFromHere({input:{mode:'from_here',anchors,legs:[{from:'a',to:'b',profile:'dirt',allowUnknown:false}],fuel:{fullRangeMeters:usable,reserveFraction:0,initialUsableMeters:usable}},pack,geom,stations,revision:identity,objectiveId:'dirt-30',edgeCost:a=>a.distanceMeters*(surfaceKind(a.surfaceLeaf)==='dirt'?1:30),fuelHeuristicWeight:2,maxFuelLabels:400000,fuelFirst:true,allowPassingRefillAdvisory:true,allowRepeatedPassingRoute:true,useAvoidanceLowerBounds:true,budget:createBudget({deadlineAtMs,maxExpansions:200000000})});
 const proof={segments:result.road.segments,stops:result.fuel.plannedRefills,escape:result.fuel.destinationEscape};
 console.log(JSON.stringify({capacity:cap||'full',identity,edges:pack.edgeCount,loadMs:Math.round(loadMs),searchMs:Math.round(performance.now()-start),residentAfterLoadMiB:Math.round(residentAfterLoad/1048576),peakProcessMiB:Math.round(process.resourceUsage().maxRSS/1024),geometry:geom.stats||{residentBytes:fs.statSync(file).size},road:result.road.state,fuel:result.fuel.state,reason:result.fuel.reason,distanceMeters:result.road.distanceMeters,stops:result.fuel.plannedRefills?.length,timing:result.timing,signature:crypto.createHash('sha256').update(JSON.stringify(proof)).digest('hex')}));
 geom.close?.();
}
