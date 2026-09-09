'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {buildEdgeGridFromGeom}=require('./geometry-edge-grid');
test('long rectangles retain exact candidates and edge order at every queried cell',()=>{
 const edges=[[-.2,-.2,.2,.2],[-.01,-.01,.01,.01],[-.19,-.15,.19,.15],[],[.25,.25,.26,.26]];
 const offsets=[0],coords=[];for(const edge of edges){coords.push(...edge);offsets.push(coords.length);}
 const {edgeGrid}=buildEdgeGridFromGeom({offsets,coords},edges.length);
 for(let x=-25;x<=30;x++)for(let y=-25;y<=30;y++){
  const expected=edges.flatMap((e,i)=>e.length&&x>=Math.floor(e[0]/.01)&&x<=Math.floor(e[2]/.01)&&y>=Math.floor(e[1]/.01)&&y<=Math.floor(e[3]/.01)?[i]:[]);
  assert.deepEqual(edgeGrid.get(`${x}:${y}`)||[],expected);
 }
});
test('continental ferry bounds do not allocate a cell for every ocean square',()=>{
 const {edgeGrid}=buildEdgeGridFromGeom({offsets:[0,4],coords:[-148.67,47.58,-122.35,60.82]},1);
 assert.deepEqual(edgeGrid.get('-14000:5000'),[0]);
 assert.equal(edgeGrid.get('-12000:5000'),undefined);
});
