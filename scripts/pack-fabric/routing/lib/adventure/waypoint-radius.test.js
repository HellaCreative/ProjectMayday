'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {waypointRadiusMeters}=require('./waypoint-radius');
const {tapRadiusMeters}=require('../legal-topology/tap-radius');
test('coarse rider area selection expands while street precision and explicit limits remain',()=>{
 assert.ok(waypointRadiusMeters({zoom:8,lat:45})>10000);
 assert.equal(waypointRadiusMeters({zoom:4,lat:45}),20000);
 assert.equal(waypointRadiusMeters({zoom:16,lat:45}),tapRadiusMeters({zoom:16,lat:45,graphBinaryVersion:4}));
 assert.equal(waypointRadiusMeters({zoom:8,lat:45,requestedMeters:500}),500);
 assert.equal(waypointRadiusMeters({lat:45}),550);
});
