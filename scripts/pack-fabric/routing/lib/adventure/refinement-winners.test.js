'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {refinementPreservesWinners}=require('./ride-alternatives');
const result=(dirt,repeat,urban=0)=>({road:{urbanMeters:urban,surface:{knownDirtPercent:dirt,pavedPercent:100-dirt}},qualityAudit:{repeatedRoadMeters:repeat}});
test('reducing one candidate repetition cannot expose a worse winner for another style',()=>{
 const rows=[{id:'paved',result:result(0,0)},{id:'dirt30',result:result(80,471)},{id:'mixed',result:result(79.5,1163)}];
 assert.equal(refinementPreservesWinners(rows,'dirt30',result(79,0)),false);
});
test('accept a repetition improvement that preserves all style winners, reject urban degradation',()=>{
 const rows=[{id:'paved',result:result(0,0)},{id:'dirt30',result:result(80,3491)},{id:'mixed',result:result(76,1030)}];
 assert.equal(refinementPreservesWinners(rows,'dirt30',result(79.58,0)),true);
 assert.equal(refinementPreservesWinners([{id:'only',result:result(80,3491)}],'only',result(79.58,0,1)),false);
});
