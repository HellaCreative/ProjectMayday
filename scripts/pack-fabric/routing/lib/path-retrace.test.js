"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {containsRoadSpan,repeatedRoadSpan}=require("./path-retrace");
test("retrace follows packed spans, including partial endpoints, rather than whole edge IDs",()=>{
 const rows=[null,{edge:7,span:[0,25]},{edge:8,span:[0,100]}],prev=[-1,0,1];
 assert.equal(containsRoadSpan(2,7,[20,80],n=>prev[n],n=>rows[n]),true);
 assert.equal(containsRoadSpan(2,7,[25,80],n=>prev[n],n=>rows[n]),false);
 assert.equal(containsRoadSpan(2,9,[0,100],n=>prev[n],n=>rows[n]),false);
 assert.equal(repeatedRoadSpan([...rows,{edge:7,span:[25,80]}]),false);
 assert.equal(repeatedRoadSpan([...rows,{edge:7,span:[0,25]}]),true);
});
