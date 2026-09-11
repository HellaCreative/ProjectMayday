"use strict";
// In-memory multi-pack view. Join exact shared OSM nodes only, never proximity.
// Canonical duplicate edges collapse before restrictions are remapped, so crossing
// an overlap cannot escape a restriction by choosing the other pack's edge copy.
function indexedView(length,read) {
 return new Proxy({}, {get:(_,key)=>key==='length'?length:/^\d+$/.test(String(key))&&Number(key)<length?read(Number(key)):undefined});
}
// Keep the packed ID accessor outside joinV4's allocation scope so retaining
// it cannot also retain temporary node maps and join scratch arrays.
function nodeIdReader(storage){return i=>String(storage[i]);}
function sourceReader(regionIds,edgeIds){return e=>({region:regionIds[e],edge:edgeIds[e]});}
function joinedReaders(regions,source,nodeIds,from,to,aliases){
 return {
  wayId:e=>{const s=source(e);return regions[s.region].pack.osmWayIds[s.edge];},
  edgeId:e=>{const s=source(e);return `${regions[s.region].pack.osmWayIds[s.edge]}:${nodeIds[from[e]]}:${nodeIds[to[e]]}#${e}`;},
  edgeAliases:e=>(aliases.get(e)||[source(e)]).map(s=>regions[s.region].pack.edgeId(s.edge)),
  edgeLeaves:e=>{const s=source(e);return regions[s.region].pack.edgeLeaves(s.edge);},
  polyline:e=>{const s=source(e);return regions[s.region].geom.polyline(s.edge);},
  coordinateRange:e=>{const s=source(e),g=regions[s.region].geom;return g.offsets&&g.coords?{coords:g.coords,start:g.offsets[s.edge],end:g.offsets[s.edge+1]}:null;}
 };
}
function joinV4(regions,{budget,compactNodes=false}) {
 if(regions.length<2)throw new TypeError('At least two source regions required');
 if(new Set(regions.map(r=>r.pack.regionId)).size!==regions.length)throw new TypeError('Duplicate source region');
 const fail=message=>{throw new Error(`V4 join: ${message}`);};
 const first=regions[0].pack;
 for(const {pack} of regions)if(pack.graphBinaryVersion!==4||!pack.provenance?.sourceEpoch||pack.provenance.sourceEpoch!==first.provenance.sourceEpoch)fail('incompatible source epoch or dictionaries');
 const surfaceNames=[...new Set(regions.flatMap(r=>r.pack.enums.surfaceLeafNames))],roadNames=[...new Set(regions.flatMap(r=>r.pack.enums.roadClassLeafNames))];
 const maxNodes=regions.reduce((n,r)=>n+r.pack.nodeCount,0),maxEdges=regions.reduce((n,r)=>n+r.pack.edgeCount,0);
 const nodes=new Map(),coords=new Float32Array(maxNodes*2),nodeMaps=[],edgeMaps=[],canonical=new Map();
 const idStorage=compactNodes?new BigInt64Array(maxNodes):null;
 const readNodeId=compactNodes?nodeIdReader(idStorage):null;
 const nodeIds=compactNodes?indexedView(maxNodes,readNodeId):[];let nodeCount=0;
 const sourceRegions=new Uint16Array(maxEdges),sourceEdges=new Int32Array(maxEdges);let edgeCount=0;
 const source=sourceReader(sourceRegions,sourceEdges);
 const shared=new Uint8Array(maxNodes),lastNodeRegion=new Uint16Array(maxNodes);
 let sharedNodes=0;
 regions.forEach(({pack},region)=>{
  const map=new Int32Array(pack.nodeCount);nodeMaps.push(map);
  for(let i=0;i<pack.nodeCount;i++) {
   if(!budget.consume())fail(budget.snapshot().reason);
   const id=String(pack.osmNodeIds[i]);if(!id||id==='0')fail('ambiguous source node identity');
   const value=compactNodes?BigInt(id):null,numeric=compactNodes?Number(value):null;
   const nodeKey=compactNodes?(Number.isSafeInteger(numeric)?numeric:value):id;
   let n=nodes.get(nodeKey);const x=pack.nodeCoords[2*i],y=pack.nodeCoords[2*i+1];
   if(n!==undefined){if(lastNodeRegion[n]===region+1)fail('ambiguous source node identity');if(coords[2*n]!==x||coords[2*n+1]!==y)fail('shared node coordinate mismatch');sharedNodes++;shared[n]=1;}
   else {n=nodeCount++;nodes.set(nodeKey,n);if(compactNodes)idStorage[n]=value;else nodeIds.push(id);coords[2*n]=x;coords[2*n+1]=y;}
   lastNodeRegion[n]=region+1;map[i]=n;
  }
 });
 if(!sharedNodes)fail('no shared source nodes');
 const from=new Int32Array(maxEdges),to=new Int32Array(maxEdges),meters=new Uint32Array(maxEdges),access=new Uint8Array(maxEdges*2),surface=new Uint8Array(maxEdges),road=new Uint8Array(maxEdges),aliases=new Map();
 regions.forEach(({pack,geom},region)=>{
  const map=new Int32Array(pack.edgeCount);edgeMaps.push(map);
  for(let i=0;i<pack.edgeCount;i++) {
   if(!budget.consume())fail(budget.snapshot().reason);
   const a=nodeMaps[region][pack.edgeFrom[i]],b=nodeMaps[region][pack.edgeTo[i]];
   // Only overlap edges need a canonical string key. Interior edges cannot
   // duplicate another region, so avoid reading/stringifying millions of IDs.
   const canShare=shared[a]&&shared[b];
   const key=canShare?`${pack.osmWayIds[i]}:${nodeIds[a]}:${nodeIds[b]}`:null;
   const existing=canShare?canonical.get(key):undefined;
   const peers=existing===undefined?null:Array.isArray(existing)?existing:[existing];
   let edge=peers?.find(e=>{const src=source(e);return src.region!==region&&JSON.stringify(regions[src.region].geom.polyline(src.edge))===JSON.stringify(geom.polyline(i));});
   if(edge===undefined&&peers?.some(e=>source(e).region!==region)&&a!==b)fail('shared edge geometry mismatch');
   if(edge!==undefined) {
    const src=source(edge),old=regions[src.region].pack;
    for(const field of ['edgeMeters','edgeLayer','edgeGrade','edgeFlags'])if(old[field]?.[src.edge]!==pack[field]?.[i])fail(`duplicate edge ${key} ${field} mismatch: ${old[field]?.[src.edge]} vs ${pack[field]?.[i]}, regions ${src.region}/${region}`);
    if(JSON.stringify(old.edgeLeaves(src.edge))!==JSON.stringify(pack.edgeLeaves(i)))fail('duplicate edge semantic mismatch');
    if(access[edge*2]!==pack.edgeAccess[i*2]||access[edge*2+1]!==pack.edgeAccess[i*2+1])fail('duplicate access mismatch');
    if(JSON.stringify(regions[src.region].geom.polyline(src.edge))!==JSON.stringify(geom.polyline(i)))fail('duplicate geometry mismatch');
   } else {
    edge=edgeCount++;if(canShare)canonical.set(key,peers?[...peers,edge]:edge);sourceRegions[edge]=region;sourceEdges[edge]=i;
    from[edge]=a;to[edge]=b;meters[edge]=pack.edgeMeters[i];access[edge*2]=pack.edgeAccess[2*i];access[edge*2+1]=pack.edgeAccess[2*i+1];surface[edge]=surfaceNames.indexOf(pack.enums.surfaceLeafNames[pack.edgeSurfaceLeaf[i]]);road[edge]=roadNames.indexOf(pack.enums.roadClassLeafNames[pack.edgeRoadClassLeaf[i]]);
   }
   // Most edges have one source. Retain extra aliases only at overlaps and
   // materialize string identities when a route actually asks for them.
   const original=source(edge);
   if(original.region!==region||original.edge!==i) {
    if(!aliases.has(edge))aliases.set(edge,[original]);
    aliases.get(edge).push({region,edge:i});
   }
   map[i]=edge;
  }
 });
 // Reserve CSR slots using source degrees, then deduplicate only within each
 // node's short adjacency list. Avoid allocating one Map per joined node.
 const capacities=new Int32Array(nodeCount);
 regions.forEach(({pack},region)=>{for(let n=0;n<pack.nodeCount;n++)capacities[nodeMaps[region][n]]+=pack.nodeOffsets[n+1]-pack.nodeOffsets[n];});
 const starts=new Int32Array(nodeCount+1);
 for(let n=0;n<nodeCount;n++)starts[n+1]=starts[n]+capacities[n];
 const targetsStorage=new Int32Array(starts[nodeCount]),edgesStorage=new Int32Array(starts[nodeCount]),counts=new Int32Array(nodeCount);
 regions.forEach(({pack},region)=>{for(let n=0;n<pack.nodeCount;n++)for(let j=pack.nodeOffsets[n];j<pack.nodeOffsets[n+1];j++) {
  if(!budget.consume())fail(budget.snapshot().reason);
  const node=nodeMaps[region][n],edge=edgeMaps[region][pack.edgeUndirectedIndex[j]],target=nodeMaps[region][pack.edgeTargets[j]];
  const end=starts[node]+counts[node];let at=starts[node];
  while(at<end&&edgesStorage[at]!==edge)at++;
  // Match Map.set semantics: retain insertion order and replace a duplicate's target.
  edgesStorage[at]=edge;targetsStorage[at]=target;if(at===end)counts[node]++;
 }});
 const offsets=new Int32Array(nodeCount+1);let used=0;
 for(let n=0;n<nodeCount;n++){
  const end=starts[n]+counts[n];
  for(let at=starts[n];at<end;at++){edgesStorage[used]=edgesStorage[at];targetsStorage[used++]=targetsStorage[at];}
  offsets[n+1]=used;
 }
 const targets=targetsStorage.subarray(0,used),edgeIndices=edgesStorage.subarray(0,used);
 const restrictions=[],seenRestrictions=new Set();
 regions.forEach(({pack},region)=>{for(const r of pack.restrictions||[]) {
  const mapped={...r,fromEdge:edgeMaps[region][r.fromEdge],toEdge:edgeMaps[region][r.toEdge],viaEdges:(r.viaEdges||[]).map(e=>edgeMaps[region][e])};
  if(r.viaNode!=null)mapped.viaNode=nodeMaps[region][r.viaNode];
  if(r.viaNodeIds)mapped.viaNodeIds=r.viaNodeIds.map(n=>nodeMaps[region][n]);
  if([mapped.fromEdge,mapped.toEdge,...mapped.viaEdges].some(e=>e==null))fail('unresolved restriction edge');
  const key=JSON.stringify(mapped);if(!seenRestrictions.has(key)){seenRestrictions.add(key);restrictions.push(mapped);}
 }});
 nodes.clear();canonical.clear();
 const readers=joinedReaders(regions,source,nodeIds,from,to,aliases);
 const pack={graphBinaryVersion:4,regionId:regions.map(r=>r.pack.regionId).join('+'),regionIds:regions.map(r=>r.pack.regionId),provenance:first.provenance,enums:{...first.enums,surfaceLeafNames:surfaceNames,roadClassLeafNames:roadNames},
  meta:{urbanCores:regions.flatMap(r=>r.pack.meta?.urbanCores||[]),settlements:regions.flatMap(r=>r.pack.meta?.settlements||[])},
  nodeCount:nodeCount,edgeCount:edgeCount,undirectedEdgeCount:edgeCount,directedArcCount:targets.length,
  nodeCoords:coords.subarray(0,nodeCount*2),osmNodeIds:compactNodes?indexedView(nodeCount,readNodeId):nodeIds,osmWayIds:indexedView(edgeCount,readers.wayId),
  nodeOffsets:offsets,edgeTargets:targets,edgeUndirectedIndex:edgeIndices,edgeFrom:from.subarray(0,edgeCount),edgeTo:to.subarray(0,edgeCount),edgeMeters:meters.subarray(0,edgeCount),edgeAccess:access.subarray(0,edgeCount*2),edgeSurfaceLeaf:surface.subarray(0,edgeCount),edgeRoadClassLeaf:road.subarray(0,edgeCount),restrictions,
  edgeId:readers.edgeId,edgeAliases:readers.edgeAliases,edgeLeaves:readers.edgeLeaves,
  hasDirectedArc(a,b,e){for(let i=this.nodeOffsets[a];i<this.nodeOffsets[a+1];i++)if(this.edgeTargets[i]===b&&this.edgeUndirectedIndex[i]===e)return true;return false;}};
 const geom={coordinateRange:readers.coordinateRange,polyline:readers.polyline};
 return {pack,geom,sources:indexedView(edgeCount,source),nodeMaps,edgeMaps,diagnostics:{sharedNodes,duplicateEdges:regions.reduce((n,r)=>n+r.pack.edgeCount,0)-edgeCount}};
}
module.exports={joinV4};
