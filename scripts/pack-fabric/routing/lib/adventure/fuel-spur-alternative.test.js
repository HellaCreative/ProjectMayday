"use strict";
const test=require('node:test'),assert=require('node:assert/strict');
const {fuelSpurStation,preferFuelAlternative}=require('./fuel-spur-alternative');
const route=(repeat,dirt,distance)=>({road:{distanceMeters:distance,avoidanceMeters:0,surface:{knownDirtMeters:dirt}},qualityAudit:{state:'complete',repeatedRoadMeters:repeat,repeatedKnownDirtMeters:repeat,revisitedNodes:[{firstAtMeters:100,atMeters:15100}]},fuel:{state:'provisional_station_access',plannedRefills:[{stationId:'pump',atMeters:8000,movable:true}]}});
test('investigate a substantial one-pump circuit, preserve fixed anchors and short station access',()=>{
 const r=route(7000,15000,20000);assert.equal(fuelSpurStation(r),'pump');
 r.fuel.plannedRefills[0].movable=false;assert.equal(fuelSpurStation(r),null);
 assert.equal(fuelSpurStation(route(200,15000,20000)),null);
});
test('a lower displayed dirt share can deliver more fresh dirt and less retracing',()=>{
 assert.equal(preferFuelAlternative(route(6000,15000,20000),route(100,13000,18000)),true);
});
test('never trade fuel feasibility or greater avoidance exposure for better shape',()=>{
 const original=route(6000,15000,20000),alternative=route(100,13000,18000);
 alternative.fuel.state='unverified';assert.equal(preferFuelAlternative(original,alternative),false);
 alternative.fuel.state='provisional_station_access';alternative.road.avoidanceMeters=1;assert.equal(preferFuelAlternative(original,alternative),false);
});
test('do not prefer a shorter paved ride that loses the meaningful dirt',()=>{
 assert.equal(preferFuelAlternative(route(6000,15000,20000),route(0,100,18000)),false);
});
