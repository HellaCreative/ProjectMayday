'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {resolveHistory,directedArrival}=require('./arrival-history');
const {createBudget}=require('./budget');
const budget=()=>createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:10000});
const pack={edgeCount:3,edgeFrom:[0,1,2],edgeTo:[1,2,3],osmNodeIds:['100','101','102','103'],osmWayIds:['10','11','12'],edgeId:e=>['a','b','c'][e],edgeAliases:e=>[['regional-a'],['regional-b'],['regional-c']][e]};
test('regional aliases and portable joined IDs resolve to the same source roads',()=>{
 assert.deepEqual(resolveHistory(pack,['regional-a','11:101:102#934'],'11:101:102#934',budget()).edges,[0,1]);
 assert.equal(resolveHistory(pack,['missing'],'missing',budget()).reason,'arrival_edge_not_in_graph');
 assert.equal(resolveHistory(pack,['a'],'b',budget()).reason,'arrival_history_invalid');
});
test('history orientation uses a continuous source suffix and refuses ambiguous departure',()=>{
 const r=directedArrival(pack,[0,1],{edgeIndex:1,fraction:.5});
 assert.deepEqual(r.arcs,[{id:0,from:0,to:1},{id:1,from:1,to:2}]);
 assert.deepEqual(directedArrival(pack,[2,1],{edgeIndex:1,fraction:.5}).arcs,[{id:2,from:3,to:2},{id:1,from:2,to:1}]);
 assert.equal(directedArrival(pack,[1],{edgeIndex:1,fraction:.5}).reason,'arrival_direction_unknown');
 assert.equal(directedArrival(pack,[1],{edgeIndex:2,fraction:0}).reason,'arrival_snap_mismatch');
});
