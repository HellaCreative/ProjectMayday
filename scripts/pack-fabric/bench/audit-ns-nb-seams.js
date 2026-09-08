"use strict";
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {decodeGraphV4}=require('../routing/lib/pack-v4');
const root=process.env.REBUILD_PACK_ROOT;if(!root)throw Error('REBUILD_PACK_ROOT required');
const packs={},seams={},identities={};
for(const region of ['ns','nb']) {
 const b=fs.readFileSync(path.join(root,region,'graph.v4.bin')),g=fs.readFileSync(path.join(root,region,'geometry.v1.bin'));
 packs[region]=decodeGraphV4(b,g);identities[region]=crypto.createHash('sha256').update(b).digest('hex');
 seams[region]=JSON.parse(fs.readFileSync(path.join(root,region,'cross-pack-seams.v2.json')));
}
const maps={};for(const region of ['ns','nb']) {
 const pack=packs[region],nodes=new Map(),edges=new Map();
 for(let i=0;i<pack.nodeCount;i++){const id=String(pack.osmNodeIds[i]);const list=nodes.get(id)||[];list.push(i);nodes.set(id,list);}
 for(let i=0;i<pack.edgeCount;i++)edges.set(`${pack.osmWayIds[i]}:${pack.osmNodeIds[pack.edgeFrom[i]]}:${pack.osmNodeIds[pack.edgeTo[i]]}`,i);
 maps[region]={nodes,edges};
}
const rows=[];
for(const row of seams.ns.neighbors.nb||[]) {
 const problems=[],nodes={},edges={};
 for(const region of ['ns','nb']) {
  const p=packs[region],id=region==='ns'?row.localEdgeId:row.remoteEdgeId;
  edges[region]=maps[region].edges.get(id);const candidates=maps[region].nodes.get(String(row.osmNodeId))||[];
  nodes[region]=candidates.filter(n=>p.edgeFrom[edges[region]]===n||p.edgeTo[edges[region]]===n);
  if(edges[region]==null)problems.push(region+':missing_edge');
  if(nodes[region].length!==1)problems.push(region+':ambiguous_or_missing_node');
 }
 const reciprocal=(seams.nb.neighbors.ns||[]).some(r=>r.osmNodeId===row.osmNodeId&&r.localEdgeId===row.remoteEdgeId&&r.remoteEdgeId===row.localEdgeId);
 if(!reciprocal)problems.push('missing_reciprocal_record');
 if(nodes.ns.length===1&&nodes.nb.length===1)for(let axis=0;axis<2;axis++)if(packs.ns.nodeCoords[nodes.ns[0]*2+axis]!==packs.nb.nodeCoords[nodes.nb[0]*2+axis])problems.push('coordinate_mismatch');
 const restrictionCounts={};for(const region of ['ns','nb'])restrictionCounts[region]=packs[region].restrictions.filter(r=>[r.fromEdge,r.toEdge,...(r.viaEdges||[])].includes(edges[region])).length;
 rows.push({osmNodeId:row.osmNodeId,coordinate:row.coordinate,edgeIds:[row.localEdgeId,row.remoteEdgeId],nodes,edges,restrictionCounts,problems});
}
const result={identities,records:rows.length,identityVerified:rows.filter(r=>!r.problems.length).length,flagged:rows.filter(r=>r.problems.length),restrictionBearing:rows.filter(r=>Object.values(r.restrictionCounts).some(Boolean)),rows};
const output=process.env.REBUILD_SEAM_OUTPUT||'scripts/pack-fabric/routing/candidates/rebuild-ns-nb-seams.json';fs.writeFileSync(output,JSON.stringify(result,null,2));
console.log(JSON.stringify({identities,records:result.records,identityVerified:result.identityVerified,flagged:result.flagged.length,restrictionBearing:result.restrictionBearing.length}));
