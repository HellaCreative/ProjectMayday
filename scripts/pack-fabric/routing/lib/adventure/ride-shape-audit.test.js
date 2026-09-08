"use strict";
const test=require('node:test'),assert=require('node:assert/strict');
const {auditRideShape}=require('./ride-shape-audit'),{createBudget}=require('./budget');
const work=(n=10000)=>createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:n});
const segment=(edgeIndex,fromFraction,toFraction,distanceMeters,fromNode,toNode,surfaceLeaf='asphalt')=>({edgeIndex,fromFraction,toFraction,distanceMeters,fromNode,toNode,surfaceLeaf});
test('adjacent station-split intervals are not repeated roads',()=>{
 const r=auditRideShape({budget:work(),segments:[segment(0,0,.3,30,0,2),segment(0,.3,1,70,2,1)]});
 assert.equal(r.repeatedRoadMeters,0);assert.deepEqual(r.revisitedNodes,[]);
});
test('reverse and third traversals count prior overlap once per new traversal',()=>{
 const r=auditRideShape({budget:work(),segments:[segment(0,0,1,100,0,1),segment(0,1,.5,50,1,2),segment(0,.5,1,50,2,1)]});
 assert.equal(r.repeatedRoadMeters,100);assert.equal(r.revisitedNodes.length,1);
});
test('separate prior fragments form a union without double-counting overlaps',()=>{
 const r=auditRideShape({budget:work(),segments:[segment(0,0,.2,20,0,1),segment(0,.8,1,20,2,3),segment(0,.1,.9,80,4,5),segment(0,0,1,100,6,7)]});
 assert.ok(Math.abs(r.repeatedRoadMeters-120)<1e-8);
});
test('continuous dirt survives split edges and unknown surface breaks the run',()=>{
 const r=auditRideShape({budget:work(),segments:[segment(0,0,1,150,0,1,'gravel'),segment(1,0,1,150,1,2,'gravel'),segment(2,0,1,10,2,3,null),segment(3,0,1,50,3,4,'gravel')]});
 assert.deepEqual(r.dirtRuns.map(r=>r.distanceMeters),[300,50]);assert.equal(r.shortDirtRunCounts.under250Meters,1);
});
test('interrupted audit does not present partial metrics as complete',()=>{
 assert.equal(auditRideShape({budget:work(1),segments:[segment(0,0,1,1,0,1),segment(1,0,1,1,1,2)]}).state,'incomplete');
});
