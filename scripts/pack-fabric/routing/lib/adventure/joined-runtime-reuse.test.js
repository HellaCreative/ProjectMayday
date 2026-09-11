'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {sourceKey,reusableRuntime}=require('./joined-runtime-reuse');
const revisions=require('./verified-pack-revisions.json');
function fixture() {
 const releaseId='fabric-v4-20260909-02',base='https://example.test/v4/releases/'+releaseId;
 const sources=['nb','ns'].map(regionId=>({regionId,graphSource:`${base}/${regionId}/graph.v4.bin`,fuelSource:`${base}/${regionId}/fuel.v1.json`}));
 const data={pack:{graphBinaryVersion:4},identity:sources.map(s=>({...s,geometrySource:s.graphSource.replace('graph.v4.bin','geometry.v1.bin'),releaseId,...revisions[releaseId][s.regionId]}))};
 return {sources,data,cache:{sourceKey:sourceKey(sources),data}};
}
test('immutable graph reuse survives source-reader eviction without fetching or joining again',()=>{
 const f=fixture();assert.equal(reusableRuntime(f.cache,f.sources),f.data);
 assert.equal(reusableRuntime(f.cache,structuredClone(f.sources)),f.data);
});
test('region/source/byte changes and mutable paths cannot reuse a joined runtime',()=>{
 const f=fixture();
 assert.equal(reusableRuntime(f.cache,[...f.sources].reverse()),null);
 for(const field of ['graphSha256','geometrySha256','fuelSha256','graphSource','geometrySource','fuelSource','releaseId']) {
  const data=structuredClone(f.data);data.identity[0][field]='changed';
  assert.equal(reusableRuntime({...f.cache,data},f.sources),null,field);
 }
 for(const graphSource of ['/tmp/ns/graph.v4.bin','https://example.test/candidates/ns/graph.v4.bin',f.sources[0].graphSource+'?revision=next'])
  assert.equal(sourceKey([{...f.sources[0],graphSource}]),null);
 assert.equal(sourceKey([f.sources[0],f.sources[0]]),null);
});
