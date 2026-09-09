"use strict";
// In-memory two-pack view. Join exact shared OSM nodes only, never proximity.
// Canonical duplicate edges collapse before restrictions are remapped, so crossing
// an overlap cannot escape a restriction by choosing the other pack's edge copy.
function joinV4(regions,{budget}) {
 if(regions.length!==2)throw new TypeError('Exactly two source regions required');
 const fail=message=>{throw new Error(`V4 join: ${message}`);};
 const first=regions[0].pack;
 for(const {pack} of regions)if(pack.graphBinaryVersion!==4||!pack.provenance?.sourceEpoch||pack.provenance.sourceEpoch!==first.provenance.sourceEpoch)fail('incompatible source epoch or dictionaries');
 const surfaceNames=[...new Set(regions.flatMap(r=>r.pack.enums.surfaceLeafNames))],roadNames=[...new Set(regions.flatMap(r=>r.pack.enums.roadClassLeafNames))];
 const nodes=new Map(),coords=[],nodeMaps=[],edgeMaps=[],sources=[],canonical=new Map(),nodeIds=[];
 let sharedNodes=0;
 regions.forEach(({pack},region)=>{
  const map=new Int32Array(pack.nodeCount),seen=new Set();nodeMaps.push(map);
  for(let i=0;i<pack.nodeCount;i++) {
   if(!budget.consume())fail(budget.snapshot().reason);
   const id=String(pack.osmNodeIds[i]);if(!id||id==='0'||seen.has(id))fail('ambiguous source node identity');seen.add(id);
   let n=nodes.get(id);const xy=[pack.nodeCoords[2*i],pack.nodeCoords[2*i+1]];
   if(n!==undefined){if(coords[2*n]!==xy[0]||coords[2*n+1]!==xy[1])fail('shared node coordinate mismatch');sharedNodes++;}
   else {n=nodeIds.length;nodes.set(id,n);nodeIds.push(id);coords.push(...xy);}
   map[i]=n;
  }
 });
 if(!sharedNodes)fail('no shared source nodes');
 const from=[],to=[],meters=[],access=[],surface=[],road=[],ids=[],aliases=[];
 regions.forEach(({pack,geom},region)=>{
  const map=new Int32Array(pack.edgeCount);edgeMaps.push(map);
  for(let i=0;i<pack.edgeCount;i++) {
   if(!budget.consume())fail(budget.snapshot().reason);
   const a=nodeMaps[region][pack.edgeFrom[i]],b=nodeMaps[region][pack.edgeTo[i]];
   const key=`${pack.osmWayIds[i]}:${nodeIds[a]}:${nodeIds[b]}`;
   const peers=canonical.get(key)||[];
   let edge=peers.find(e=>{const src=sources[e];return src.region!==region&&JSON.stringify(regions[src.region].geom.polyline(src.edge))===JSON.stringify(geom.polyline(i));});
   if(edge===undefined&&peers.some(e=>sources[e].region!==region)&&a!==b)fail('shared edge geometry mismatch');
   if(edge!==undefined) {
    const src=sources[edge],old=regions[src.region].pack;
    for(const field of ['edgeMeters','edgeLayer','edgeGrade','edgeFlags'])if(old[field]?.[src.edge]!==pack[field]?.[i])fail(`duplicate edge ${key} ${field} mismatch: ${old[field]?.[src.edge]} vs ${pack[field]?.[i]}, regions ${src.region}/${region}`);
    if(JSON.stringify(old.edgeLeaves(src.edge))!==JSON.stringify(pack.edgeLeaves(i)))fail('duplicate edge semantic mismatch');
    if(access[edge*2]!==pack.edgeAccess[i*2]||access[edge*2+1]!==pack.edgeAccess[i*2+1])fail('duplicate access mismatch');
    if(JSON.stringify(regions[src.region].geom.polyline(src.edge))!==JSON.stringify(geom.polyline(i)))fail('duplicate geometry mismatch');
   } else {
    edge=sources.length;canonical.set(key,[...peers,edge]);sources.push({region,edge:i});ids.push(`${key}#${edge}`);
    from.push(a);to.push(b);meters.push(pack.edgeMeters[i]);access.push(pack.edgeAccess[2*i],pack.edgeAccess[2*i+1]);surface.push(surfaceNames.indexOf(pack.enums.surfaceLeafNames[pack.edgeSurfaceLeaf[i]]));road.push(roadNames.indexOf(pack.enums.roadClassLeafNames[pack.edgeRoadClassLeaf[i]]));
   }
   (aliases[edge]??=[]).push(pack.edgeId(i));
   map[i]=edge;
  }
 });
 const adjacency=Array.from({length:nodeIds.length},()=>new Map());
 regions.forEach(({pack},region)=>{for(let n=0;n<pack.nodeCount;n++)for(let j=pack.nodeOffsets[n];j<pack.nodeOffsets[n+1];j++) {
  if(!budget.consume())fail(budget.snapshot().reason);
  const edge=edgeMaps[region][pack.edgeUndirectedIndex[j]],target=nodeMaps[region][pack.edgeTargets[j]];
  adjacency[nodeMaps[region][n]].set(edge,target);
 }});
 const offsets=new Int32Array(nodeIds.length+1),targets=[],edgeIndices=[];
 adjacency.forEach((arcs,n)=>{for(const [edge,target] of arcs){edgeIndices.push(edge);targets.push(target);}offsets[n+1]=targets.length;});
 const restrictions=[],seenRestrictions=new Set();
 regions.forEach(({pack},region)=>{for(const r of pack.restrictions||[]) {
  const mapped={...r,fromEdge:edgeMaps[region][r.fromEdge],toEdge:edgeMaps[region][r.toEdge],viaEdges:(r.viaEdges||[]).map(e=>edgeMaps[region][e])};
  if(r.viaNode!=null)mapped.viaNode=nodeMaps[region][r.viaNode];
  if(r.viaNodeIds)mapped.viaNodeIds=r.viaNodeIds.map(n=>nodeMaps[region][n]);
  if([mapped.fromEdge,mapped.toEdge,...mapped.viaEdges].some(e=>e==null))fail('unresolved restriction edge');
  const key=JSON.stringify(mapped);if(!seenRestrictions.has(key)){seenRestrictions.add(key);restrictions.push(mapped);}
 }});
 const pack={graphBinaryVersion:4,regionId:regions.map(r=>r.pack.regionId).join('+'),regionIds:regions.map(r=>r.pack.regionId),provenance:first.provenance,enums:{...first.enums,surfaceLeafNames:surfaceNames,roadClassLeafNames:roadNames},
  meta:{urbanCores:regions.flatMap(r=>r.pack.meta?.urbanCores||[]),settlements:regions.flatMap(r=>r.pack.meta?.settlements||[])},
  nodeCount:nodeIds.length,edgeCount:sources.length,undirectedEdgeCount:sources.length,directedArcCount:targets.length,
  nodeCoords:Float32Array.from(coords),osmNodeIds:nodeIds,osmWayIds:sources.map(s=>regions[s.region].pack.osmWayIds[s.edge]),
  nodeOffsets:offsets,edgeTargets:Int32Array.from(targets),edgeUndirectedIndex:Int32Array.from(edgeIndices),edgeFrom:Int32Array.from(from),edgeTo:Int32Array.from(to),edgeMeters:Uint32Array.from(meters),edgeAccess:Uint8Array.from(access),edgeSurfaceLeaf:Uint8Array.from(surface),edgeRoadClassLeaf:Uint8Array.from(road),restrictions,
  edgeId:e=>ids[e],edgeAliases:e=>aliases[e],edgeLeaves:e=>{const s=sources[e];return regions[s.region].pack.edgeLeaves(s.edge);},
  hasDirectedArc(a,b,e){for(let i=offsets[a];i<offsets[a+1];i++)if(this.edgeTargets[i]===b&&this.edgeUndirectedIndex[i]===e)return true;return false;}};
 const geom={polyline(e){const s=sources[e];return regions[s.region].geom.polyline(s.edge);}};
 return {pack,geom,sources,nodeMaps,edgeMaps,diagnostics:{sharedNodes,duplicateEdges:regions.reduce((n,r)=>n+r.pack.edgeCount,0)-sources.length}};
}
module.exports={joinV4};
