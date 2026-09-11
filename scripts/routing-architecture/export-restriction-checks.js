'use strict';
// Deterministic bounded walks rooted at real restrictions, including legal reversals.
const fs=require('fs'),{readPreparedJoined}=require('../pack-fabric/bench/prepared-joined-runtime'),{createV4Graph}=require('../pack-fabric/routing/lib/adventure/v4-graph');
const root=process.argv[2],r=JSON.parse(fs.readFileSync(root+'.receipt.json'));const {pack}=readPreparedJoined(root,{expectedIdentity:r.identity,manifestSha256:r.manifestSha256,geometryPaths:Object.fromEntries(r.identity.map(i=>[i.regionId,`/tmp/dirt-performance-packs/${i.regionId}/geometry.v1.bin`]))});
const g=createV4Graph(pack,{allowUnknown:true}),checks=new Map();let count=0;
function walk(node,state,history,depth){if(!depth||count>=500)return;g.forEachOutgoing(node,arc=>{if(count++>=500)return false;const key=arc.id*2+(pack.edgeFrom[arc.id]===node?0:1),path=[...history,key],t=g.transition(state,arc);checks.set(path.join(','),{walk:path,accepted:t.allowed});if(t.allowed)walk(arc.to,t.state,path,depth-1);});}
const rules=pack.restrictions;const chosen=new Set([...Array.from({length:100},(_,i)=>Math.floor(i*rules.length/100)),...rules.map((r,i)=>r.viaEdges?.length?i:-1).filter(i=>i>=0).slice(0,100)]);
for(const i of chosen){count=0;const r=rules[i];walk(pack.edgeFrom[r.fromEdge],0,[],Math.min(8,(r.viaEdges?.length||0)+4));count=0;walk(pack.edgeTo[r.fromEdge],0,[],Math.min(8,(r.viaEdges?.length||0)+4));}
fs.writeFileSync(process.argv[3],JSON.stringify([...checks.values()]));console.log(JSON.stringify({restrictions:rules.length,sampledRestrictions:chosen.size,walkChecks:checks.size}));
