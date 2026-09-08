'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {searchResourcePath,buildLowerBounds}=require('./resource-search');
const {createBudget}=require('./budget');
const budget=()=>createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:100000});
function run(rows,{stations=[],fuel=null,transition=()=>({allowed:true,state:null}),entry=9000}={}) {
 const arcs=rows.map(([from,to,distanceMeters,surfaceLeaf],id)=>({id,from,to,distanceMeters,surfaceLeaf}));
 const graph={outgoing:n=>arcs.filter(a=>a.from===n),transition,stateKey:n=>String(n),stationAt:n=>stations.includes(n)?{id:String(n)}:null};
 const edgeCost=a=>a.distanceMeters*(a.surfaceLeaf==='gravel'?1:10);
 const lowerBounds=buildLowerBounds({graph,nodeCount:Math.max(...arcs.flatMap(a=>[a.from,a.to]))+1,target:3,edgeCost,budget:budget()});
 return searchResourcePath({graph,start:0,end:3,edgeCost,budget:budget(),fuel,lowerBounds,dirtEntryCost:entry});
}
test('a short dirt branch loses to paved onward road, a continuous 15km stretch remains worthwhile',()=>{
 assert.deepEqual(run([[0,3,200,'asphalt'],[0,1,100,'gravel'],[1,3,100,'asphalt']]).arcs.map(a=>a.to),[3]);
 assert.deepEqual(run([[0,3,20000,'asphalt'],[0,1,7500,'gravel'],[1,2,7500,'gravel'],[2,3,5000,'asphalt']]).arcs.map(a=>a.to),[1,2,3]);
});
test('splitting a dirt road and refuelling mid-run do not charge another entry',()=>{
 const r=run([[0,1,60,'gravel'],[1,2,60,'gravel'],[2,3,20,'asphalt']],{stations:[1],fuel:{usableRangeMeters:100,initialUsableMeters:100}});
 assert.equal(r.state,'found');assert.equal(r.cost,9320);assert.equal(r.visits.length,1);
});
test('necessary short fuel access remains available',()=>{
 const r=run([[0,3,150,'asphalt'],[0,1,50,'gravel'],[1,3,100,'asphalt']],{stations:[1],fuel:{usableRangeMeters:110,initialUsableMeters:60}});
 assert.equal(r.state,'found');assert.deepEqual(r.arcs.map(a=>a.to),[1,3]);
});
test('arrival surface must remain part of dominance state',()=>{
 const r=run([[0,1,900,'asphalt'],[0,2,500,'gravel'],[2,1,500,'gravel'],[1,3,2000,'gravel']]);
 assert.deepEqual(r.arcs.map(a=>a.to),[2,1,3]);assert.equal(r.cost,12000);
});
test('a continuity preference cannot bypass turn restrictions',()=>{
 const r=run([[0,3,200,'asphalt'],[0,1,100,'gravel'],[1,3,100,'asphalt']],{transition:(_s,a)=>({allowed:a.id!==0,state:null})});
 assert.deepEqual(r.arcs.map(a=>a.to),[1,3]);
});
