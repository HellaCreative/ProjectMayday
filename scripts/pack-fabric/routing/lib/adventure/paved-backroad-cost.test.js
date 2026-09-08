'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {pavedBackroadCost}=require('./paved-backroad-cost');
const {searchResourcePath}=require('./resource-search');
const {createBudget}=require('./budget');
function route(rows,extra={}){
 const arcs=rows.map(([from,to,distanceMeters,roadClassLeaf,surfaceLeaf='asphalt'],id)=>({id,from,to,distanceMeters,roadClassLeaf,surfaceLeaf}));
 const graph={outgoing:n=>arcs.filter(a=>a.from===n),stateKey:n=>String(n),transition:()=>({allowed:true,state:null}),stationAt:n=>n===1?{id:'pump'}:null};
 return searchResourcePath({graph,start:0,end:2,edgeCost:pavedBackroadCost,budget:createBudget({deadlineAtMs:Date.now()+1000,maxExpansions:10000}),...extra});
}
test('longer paved back roads beat a primary shortcut',()=>{
 assert.deepEqual(route([[0,2,1000,'primary'],[0,1,1200,'secondary'],[1,2,1200,'tertiary']]).arcs.map(a=>a.to),[1,2]);
});
test('service-road shortcut and short gravel branch do not replace paved onward road',()=>{
 for(const [road,surface] of [['service','asphalt'],['residential','gravel']])
 assert.deepEqual(route([[0,2,500,'primary'],[0,1,200,road,surface],[1,2,200,road,surface]]).arcs.map(a=>a.to),[2]);
});
test('necessary highway and fuel-access connections remain available',()=>{
 const r=route([[0,1,60,'service'],[1,2,90,'motorway']],{fuel:{usableRangeMeters:100,initialUsableMeters:70}});
 assert.equal(r.state,'found');assert.equal(r.visits.length,1);assert.deepEqual(r.arcs.map(a=>a.to),[1,2]);
});
