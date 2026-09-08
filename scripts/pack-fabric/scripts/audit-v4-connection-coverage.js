#!/usr/bin/env node
"use strict";
const fs=require("node:fs"),path=require("node:path"),crypto=require("node:crypto");
const {decodeGraphV4}=require("../routing/lib/pack-v4");
const {weakComponentIds}=require("../routing/lib/legal-topology/snap");
function audit(root,id) {
  const dir=path.join(root,"packs",id);
  const manifest=JSON.parse(fs.readFileSync(path.join(dir,"pack-manifest.v2.json")));
  const bytes=fs.readFileSync(path.join(dir,manifest.graph.name));
  if(bytes.length!==manifest.graph.bytes || crypto.createHash("sha256").update(bytes).digest("hex")!==manifest.graph.sha256)throw new Error(`${id}: graph identity mismatch`);
  const pack=decodeGraphV4(bytes),components=weakComponentIds(pack,false),sizes=new Map();
  for(const component of components)sizes.set(component,(sizes.get(component)||0)+1);
  const main=[...sizes].reduce((best,row)=>row[1]>best[1]?row:best,[-1,0]);
  const sidecar=JSON.parse(fs.readFileSync(path.join(dir,"cross-pack-seams.v2.json")));
  const needed=new Set(Object.values(sidecar.neighbors).flat().map(r=>String(r.osmNodeId)));
  const nodes=new Map();
  for(let n=0;n<pack.nodeCount;n++){const osm=String(pack.osmNodeIds[n]);if(needed.has(osm))nodes.set(osm,n);}
  const neighbors={};
  for(const [neighbor,rows]of Object.entries(sidecar.neighbors)) {
    let mainProofs=0,missingNodes=0;const networks=new Set();
    for(const row of rows){const node=nodes.get(String(row.osmNodeId));if(node==null){missingNodes++;continue;}
      const c=components[node];networks.add(c);if(c===main[0])mainProofs++;}
    neighbors[neighbor]={proofs:rows.length,mainProofs,missingNodes,componentCount:networks.size,
      largestAdvertisedComponent:Math.max(0,...[...networks].map(c=>sizes.get(c)||0))};
  }
  return {id,nodes:pack.nodeCount,mainNodes:main[1],neighbors};
}
if(require.main===module){const[root,id]=process.argv.slice(2);console.log(JSON.stringify(audit(root,id)));}
module.exports={audit};
