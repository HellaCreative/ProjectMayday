'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {createBoundsWorkspace}=require('./bounds-workspace');
const {buildLowerBounds}=require('./resource-search');
const {createBudget}=require('./budget');
const budget=()=>createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:10000});
test('sequential guidance reuse clears all prior costs and preserves exact and capped distances',()=>{
 const workspace=createBoundsWorkspace({maxBytes:80}),graph={outgoing:n=>n<3?[{from:n,to:n+1,distanceMeters:n+1}]:[]};
 let backing;
 for(const target of [3,1,2,3])for(const stopAt of [null,0])for(const factor of [1,4]) {
  const options={graph,nodeCount:4,target,stopAt,edgeCost:a=>a.distanceMeters*factor,budget:budget()};
  const expected=buildLowerBounds(options),storage=workspace.acquire(4);
  if(backing)assert.equal(storage.buffer,backing);backing=storage.buffer;
  const actual=buildLowerBounds({...options,budget:budget(),distanceStorage:storage});
  assert.deepEqual(actual.distances,expected.distances);assert.equal(actual.coverage,expected.coverage);
 }
 assert.equal(workspace.acquire(11),null);assert.equal(workspace.diagnostics().residentBytes,32);
 assert.equal(workspace.acquire(2).length,2);
 assert.throws(()=>buildLowerBounds({graph,nodeCount:4,target:3,edgeCost:a=>a.distanceMeters,budget:budget(),distanceStorage:new Float32Array(4)}),/float64/);
});
