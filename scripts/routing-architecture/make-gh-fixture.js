'use strict';
const fs=require('fs'),path=require('path'),crypto=require('crypto');
const {buildGraphFromOsm}=require('../pack-fabric/routing/lib/legal-topology/osm-graph');
const {encodeFromOsmGraph,decodeGraphV4}=require('../pack-fabric/routing/lib/pack-v4');
const {surfaceKind}=require('../pack-fabric/routing/lib/adventure/surface');const {compile}=require('./directed-restrictions');
const root=process.argv[2];fs.mkdirSync(root,{recursive:true});
const nodes=Array.from({length:6},(_,i)=>({id:i+1,lon:-63+i*.01,lat:45+(i%2)*.01}));
const ways=[[1,2],[2,3],[3,4],[3,5],[4,6],[5,6]].map((nodeIds,i)=>({id:i+10,nodeIds,tags:{highway:'unclassified',access:'yes',surface:i%2?'gravel':'asphalt'}}));
const b=encodeFromOsmGraph(buildGraphFromOsm({nodes,ways}),{regionId:'ns',sourceEpoch:'fixture'});const pack=decodeGraphV4(b.graphBuffer,b.geomBuffer);
pack.restrictions=[{fromEdge:0,viaEdges:[1],toEdge:2,only:false,viaNode:1}];
const sections={};function write(n,a){let v=Buffer.from(a.buffer,a.byteOffset,a.byteLength);fs.writeFileSync(path.join(root,n+'.bin'),v);sections[n]={file:n+'.bin',type:Buffer.isBuffer(a)?"Uint8Array":a.constructor.name,bytes:v.length,sha256:crypto.createHash('sha256').update(v).digest('hex')};}
for(let n of ['nodeCoords','edgeFrom','edgeTo','edgeMeters','edgeAccess','edgeSurfaceLeaf','edgeRoadClassLeaf'])write(n,pack[n]);write('sourceRegions',new Uint16Array(pack.edgeCount));write('sourceEdges',Uint32Array.from({length:pack.edgeCount},(_,i)=>i));fs.writeFileSync(path.join(root,'geometry.bin'),b.geomBuffer);
fs.writeFileSync(path.join(root,'verified-input.json'),JSON.stringify({root,nodeCount:pack.nodeCount,edgeCount:pack.edgeCount,sections,geometryPaths:[path.join(root,'geometry.bin')],surfaceKinds:pack.enums.surfaceLeafNames.map(l=>({paved:0,dirt:1,unknown:2}[surfaceKind(l)])),roadClasses:pack.enums.roadClassLeafNames,restrictions:compile(pack)}));
const {createV4Graph}=require('../pack-fabric/routing/lib/adventure/v4-graph');const graph=createV4Graph(pack,{allowUnknown:true});const checks=[];
function visit(node,state,history,depth){if(!depth)return;graph.forEachOutgoing(node,arc=>{const key=arc.id*2+(pack.edgeFrom[arc.id]===node?0:1),walk=[...history,key],next=graph.transition(state,arc);checks.push({walk,accepted:next.allowed});if(next.allowed)visit(arc.to,next.state,walk,depth-1);});}
for(let n=0;n<pack.nodeCount;n++)visit(n,0,[],6);fs.writeFileSync(path.join(root,'walk-checks.json'),JSON.stringify(checks));
