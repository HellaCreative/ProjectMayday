const fs=require('fs'),crypto=require('crypto'),assert=require('assert/strict');
const base=require('path').resolve(__dirname,'../routing/lib');
const {decodeGraphV4}=require(base+'/pack-v4'),{decodeGeometryV1}=require(base+'/pack-v2'),{createBudget}=require(base+'/adventure/budget');
const root=process.env.REBUILD_PACK_ROOT;
assert.ok(root&&process.env.JOIN_BASELINE_FILE,'Set REBUILD_PACK_ROOT and JOIN_BASELINE_FILE to a trusted prior join-v4 module');
const rows=['ns','nb'].map(id=>{const g=fs.readFileSync(root+'/'+id+'/graph.v4.bin'),m=fs.readFileSync(root+'/'+id+'/geometry.v1.bin');return {pack:decodeGraphV4(g,m),geom:decodeGeometryV1(m)};});
function digest(r){
 const h=crypto.createHash('sha256');
 for(const k of Object.keys(r.pack).sort()) {const v=r.pack[k];if(typeof v==='function')continue;h.update(k);h.update(ArrayBuffer.isView(v)?Buffer.from(v.buffer,v.byteOffset,v.byteLength):JSON.stringify(v));}
 for(let i=0;i<r.pack.edgeCount;i++)h.update(JSON.stringify([r.pack.edgeId(i),r.pack.edgeAliases(i),r.pack.edgeLeaves(i),r.geom.polyline(i)]));
 for(const k of ['sources','nodeMaps','edgeMaps','diagnostics'])h.update(JSON.stringify(r[k]));
 return h.digest('hex');
}
const result=[];
for(const impl of [require('path').resolve(process.env.JOIN_BASELINE_FILE),base+'/adventure/join-v4.js']){
 const at=performance.now(),r=require(impl).joinV4(rows,{budget:createBudget({deadlineAtMs:Date.now()+60000,maxExpansions:20000000})});
 result.push({impl,ms:performance.now()-at,digest:digest(r),nodes:r.pack.nodeCount,edges:r.pack.edgeCount,arcs:r.pack.directedArcCount});
}
assert.equal(result[0].digest,result[1].digest);console.log(JSON.stringify(result,null,2));
