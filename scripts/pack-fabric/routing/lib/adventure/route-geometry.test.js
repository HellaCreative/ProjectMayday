"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {pointFromMatch,materializeRoute}=require("./route-geometry");
const {createBudget}=require("./budget");
const budget=()=>createBudget({deadlineAtMs:Date.now()+10000,maxExpansions:10000});
const pack={edgeFrom:[0,1],edgeTo:[1,2],edgeId:i=>`edge-${i}`};
const geom={polyline:i=>i===0?[[0,0],[.005,.005],[.01,0]]:[[.01,0],[.02,0]]};
const arc=(id,from,to,distanceMeters,extra={})=>({id,from,to,distanceMeters,surfaceLeaf:"gravel",...extra});
test("route geometry preserves a curved source edge in its travel direction",()=>{
  const result=materializeRoute({pack,geom,budget:budget(),result:{state:"found",arcs:[arc(1,2,1,1000),arc(0,1,0,1500)],visits:[]}});
  assert.equal(result.state,"complete");
  assert.deepEqual(result.geometry,[[.02,0],[.01,0],[.005,.005],[0,0]]);
  assert.equal(result.distanceMeters,2500);
});
test("partial source geometry begins and ends at the selected interior positions",()=>{
  const result=materializeRoute({pack,geom,budget:budget(),result:{state:"found",arcs:[arc(0,3,4,750,{fromFraction:.25,toFraction:.75})],visits:[]}});
  assert.equal(result.geometry.length,3);
  assert.ok(Math.abs(result.geometry[0][0]-.0025)<1e-8);
  assert.ok(Math.abs(result.geometry[2][0]-.0075)<1e-8);
  assert.deepEqual(result.geometry[1],[.005,.005]);
});
test("nonjoining arcs cannot be painted as a straight connection",()=>{
  assert.throws(()=>materializeRoute({pack,geom,budget:budget(),result:{state:"found",arcs:[arc(0,0,1,1),arc(1,2,1,1)]}}),/Disconnected/);
});
test("snap distance is normalized against actual polyline rather than rounded edge length",()=>{
  const point=pointFromMatch("a",{edgeIndex:1,distanceAlongM:555.9746332227937},geom,budget());
  assert.ok(Math.abs(point.fraction-.5)<1e-8);
});
