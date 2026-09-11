'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {attachDeferredEdgeGrid}=require('./deferred-edge-grid');
const {buildEdgeGridFromGeom}=require('./geometry-edge-grid');
test('decoded-pack consumers do not build a legacy grid; snapping and spread consumers still receive the exact grid',()=>{
 const geom={offsets:[0,4,8],coords:[0,0,.01,0,-1,-1,1,1]},expected=buildEdgeGridFromGeom(geom,2);let calls=0;
 const runtime=attachDeferredEdgeGrid({pack:{},geom,loadDiagnostics:{gridMs:0}},geom,2,(...args)=>{calls++;return buildEdgeGridFromGeom(...args);});
 const row={pack:runtime.pack,geom:runtime.geom};assert.equal(row.geom,geom);assert.equal(calls,0);
 assert.equal(runtime.GRID,expected.GRID);assert.equal(calls,1);
 for(const key of ['0:0','100:100','-100:-100','800:800'])assert.deepEqual(runtime.edgeGrid.get(key),expected.edgeGrid.get(key));
 assert.equal({...runtime}.edgeGrid,runtime.edgeGrid);assert.equal(calls,1);assert.equal(runtime.loadDiagnostics.gridDeferred,false);
});
test('deferred legacy index does not publish a failed build',()=>{
 let calls=0;const runtime=attachDeferredEdgeGrid({loadDiagnostics:{}},{},0,()=>{if(++calls===1)throw Error('failed');return {edgeGrid:new Map(),GRID:.01};});
 assert.throws(()=>runtime.edgeGrid,/failed/);assert.equal(runtime.loadDiagnostics.gridDeferred,true);
 assert.equal(runtime.edgeGrid.size,0);assert.equal(calls,2);
});
