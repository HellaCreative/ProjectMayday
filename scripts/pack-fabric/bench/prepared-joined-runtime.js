'use strict';
// Private server-side sidecar experiment. This is NOT a V4 pack or pack release.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {decodeGeometryV1}=require('../routing/lib/pack-v4');
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
const types={Int32Array,Uint32Array,Uint16Array,Uint8Array,Float32Array,BigInt64Array};
const schema='dirt-prepared-join-experiment-v1';
function indexed(length,read){return new Proxy({length},{get:(o,k)=>typeof k==='string'&&/^(0|[1-9][0-9]*)$/.test(k)?Number(k)<length?read(Number(k)):undefined:o[k]});}
function writePreparedJoined(root,{joined,regions,identity}) {
 if(require('node:os').endianness()!=='LE')throw Error('Prepared v1 requires little-endian runtime');
 fs.mkdirSync(root,{recursive:false});
 const p=joined.pack,sections={};let bytes=0;
 const write=(name,value)=>{
  const b=Buffer.from(value.buffer,value.byteOffset,value.byteLength),file=name+'.bin';fs.writeFileSync(path.join(root,file),b);
  sections[name]={file,type:value.constructor.name,length:value.length,bytes:b.length,sha256:hash(b)};bytes+=b.length;
 };
 for(const name of ['nodeCoords','nodeOffsets','edgeTargets','edgeUndirectedIndex','edgeFrom','edgeTo','edgeMeters','edgeAccess','edgeSurfaceLeaf','edgeRoadClassLeaf'])write(name,p[name]);
 function ids(name,count,read){const a=new BigInt64Array(count);for(let i=0;i<count;i++)a[i]=BigInt(read(i));write(name,a);}
 ids('nodeIds',p.nodeCount,i=>p.osmNodeIds[i]);ids('wayIds',p.edgeCount,i=>p.osmWayIds[i]);
 const sourceRegions=new Uint16Array(p.edgeCount),sourceEdges=new Uint32Array(p.edgeCount),aliasFrom=new Uint32Array(p.edgeCount),aliasTo=new Uint32Array(p.edgeCount),leafIds=new Uint32Array(p.edgeCount);
 const dictionary=[],lookup=new Map(),aliasOverrides=[];
 for(let e=0;e<p.edgeCount;e++) {
  const src=joined.sources[e],source=regions[src.region].pack;
  sourceRegions[e]=src.region;sourceEdges[e]=src.edge;aliasFrom[e]=source.edgeFrom[src.edge];aliasTo[e]=source.edgeTo[src.edge];
  const value=p.edgeLeaves(e),key=JSON.stringify(value);let id=lookup.get(key);
  if(id===undefined){id=dictionary.length;lookup.set(key,id);dictionary.push(value);}leafIds[e]=id;
  const aliases=p.edgeAliases(e),ordinary=`w${p.osmWayIds[e]}:${aliasFrom[e]}:${aliasTo[e]}`;
  if(aliases.length!==1||aliases[0]!==ordinary)aliasOverrides.push([e,aliases]);
 }
 for(const [name,value] of Object.entries({sourceRegions,sourceEdges,aliasFrom,aliasTo,leafIds}))write(name,value);
 const manifest={schema,identity,joinSourceSha256:hash(fs.readFileSync(path.join(__dirname,'../routing/lib/adventure/join-v4.js'))),nodeCount:p.nodeCount,edgeCount:p.edgeCount,regionId:p.regionId,regionIds:p.regionIds,provenance:p.provenance,enums:p.enums,meta:p.meta,restrictions:p.restrictions,sections,dictionary,aliasOverrides};
 const text=JSON.stringify(manifest),manifestSha256=hash(text);fs.writeFileSync(path.join(root,'joined-runtime.experimental.json'),text);
 return {root,schema,identity,manifestSha256,sectionBytes:bytes,manifestBytes:Buffer.byteLength(text),leafPatterns:dictionary.length,aliasOverrides:aliasOverrides.length};
}
function readers(data,geometries,aliases,dictionary) {
 const source=e=>geometries[data.sourceRegions[e]],local=e=>data.sourceEdges[e];
 return {edgeId:e=>`${data.wayIds[e]}:${data.nodeIds[data.edgeFrom[e]]}:${data.nodeIds[data.edgeTo[e]]}#${e}`,
  edgeAliases:e=>aliases.get(e)?.slice()||[`w${data.wayIds[e]}:${data.aliasFrom[e]}:${data.aliasTo[e]}`],
  edgeLeaves:e=>({...dictionary[data.leafIds[e]]}),
  polyline:e=>source(e).polyline(local(e)),
  coordinateRange:e=>{const g=source(e),i=local(e);return {coords:g.coords,start:g.offsets[i],end:g.offsets[i+1]};}};
}
function readPreparedJoined(root,{expectedIdentity,manifestSha256,geometryPaths}) {
 if(require('node:os').endianness()!=='LE')throw Error('Prepared v1 requires little-endian runtime');
 const started=performance.now(),raw=fs.readFileSync(path.join(root,'joined-runtime.experimental.json'));
 if(hash(raw)!==manifestSha256)throw Error('Prepared join manifest identity mismatch');
 const m=JSON.parse(raw);
 if(m.schema!==schema||JSON.stringify(m.identity)!==JSON.stringify(expectedIdentity))throw Error('Prepared join source identity mismatch');
 if(m.joinSourceSha256!==hash(fs.readFileSync(path.join(__dirname,'../routing/lib/adventure/join-v4.js'))))throw Error('Prepared join algorithm changed');
 const data={};let bytes=raw.length;
 for(const [name,s] of Object.entries(m.sections)) {
  if(s.file!==name+'.bin'||!types[s.type])throw Error('Invalid prepared section');
  const b=fs.readFileSync(path.join(root,s.file));bytes+=b.length;
  if(b.length!==s.bytes||hash(b)!==s.sha256||b.length!==s.length*types[s.type].BYTES_PER_ELEMENT)throw Error('Prepared join section identity mismatch '+name);
  data[name]=new types[s.type](b.buffer,b.byteOffset,s.length);
 }
 const geometries=m.identity.map(id=>{
  const raw=fs.readFileSync(geometryPaths[id.regionId]);bytes+=raw.length;
  if(hash(raw)!==id.geometrySha256)throw Error('Prepared geometry identity mismatch');
  return decodeGeometryV1(raw);
 });
 const r=readers(data,geometries,new Map(m.aliasOverrides),m.dictionary);
 const pack={graphBinaryVersion:4,regionId:m.regionId,regionIds:m.regionIds,provenance:m.provenance,enums:m.enums,meta:m.meta,nodeCount:m.nodeCount,edgeCount:m.edgeCount,undirectedEdgeCount:m.edgeCount,directedArcCount:data.edgeTargets.length,
  ...data,osmNodeIds:indexed(m.nodeCount,i=>String(data.nodeIds[i])),osmWayIds:indexed(m.edgeCount,i=>String(data.wayIds[i])),restrictions:m.restrictions,edgeId:r.edgeId,edgeAliases:r.edgeAliases,edgeLeaves:r.edgeLeaves,
  hasDirectedArc(from,to,e){for(let i=this.nodeOffsets[from];i<this.nodeOffsets[from+1];i++)if(this.edgeTargets[i]===to&&this.edgeUndirectedIndex[i]===e)return true;return false;}};
 return {pack,geom:{polyline:r.polyline,coordinateRange:r.coordinateRange},identity:m.identity,diagnostics:{readBytes:bytes,readValidateDecodeMs:performance.now()-started,sidecarBytes:raw.length+Object.values(m.sections).reduce((n,s)=>n+s.bytes,0)}};
}
module.exports={writePreparedJoined,readPreparedJoined};
