'use strict';
// Compile existing V4 only/no semantics into explicit forbidden directed walks.
// GH's upstream restriction expander will consume these walks, not infer seams.
const {restrictionAppliesToMotorcycle}=require('../pack-fabric/routing/lib/legal-topology/restrictions');
function compile(pack) {
 const from=e=>pack.edgeFrom[e],to=e=>pack.edgeTo[e],end=k=>k%2?from(k>>1):to(k>>1),start=k=>k%2?to(k>>1):from(k>>1);
 const incoming=(e,n)=>to(e)===n?e*2:from(e)===n?e*2+1:(()=>{throw Error('Disconnected incoming restriction');})();
 const outgoing=(e,n)=>from(e)===n?e*2:to(e)===n?e*2+1:(()=>{throw Error('Disconnected outgoing restriction');})();
 const no=new Map(),only=new Map();
 function addNo(keys){no.set(keys.join(','),keys);}
 function addOnly(keys,kind="via"){const group=kind+":"+keys[0];let root=only.get(group);if(!root){root={first:keys[0],children:new Map()};only.set(group,root);}let node=root;for(const k of keys.slice(1)){if(!node.children.has(k))node.children.set(k,{children:new Map()});node=node.children.get(k);}node.terminal=true;}
 for(const r of pack.restrictions||[]) {
  if(!restrictionAppliesToMotorcycle(r))continue;
  let via=r.viaEdges||[],entry=r.viaNode;const a=Number(r.fromEdge),b=Number(r.toEdge);
  if(r.only&&via.length===1&&Number(via[0])===a) {
   const forward=pack.edgeAccess[a*2]===0&&pack.edgeAccess[a*2+1]===2,reverse=pack.edgeAccess[a*2]===2&&pack.edgeAccess[a*2+1]===0;
   const en=forward?from(a):to(a),ex=forward?to(a):from(a),attachment=[from(b),to(b)].filter(n=>n===from(a)||n===to(a));
   if((forward||reverse)&&en!==ex&&entry===en&&attachment.length===1&&attachment[0]===ex){via=[];entry=ex;}
  }
  if(!via.length) {
   const nodes=entry!=null?[Number(entry)]:(r.viaNodeIds||[]).map(Number);if(!nodes.length)throw Error('Unresolved via node');
   for(const n of nodes){const keys=[incoming(a,n),outgoing(b,n)];if(r.only)addOnly(keys,"node");else addNo(keys);}
   continue;
  }
  const sequence=[a,...via.map(Number),b],firstVia=sequence[1],shared=[from(a),to(a)].filter(n=>n===from(firstVia)||n===to(firstVia));
  if(shared.length===1)entry=shared[0];
  else if(a===firstVia||!Number.isInteger(entry)||!shared.includes(entry))throw Error('Ambiguous via entry');
  const keys=[incoming(a,entry)];let node=entry;
  for(const e of sequence.slice(1)){if(from(e)===to(e))throw Error('Ambiguous via loop');const key=outgoing(e,node);keys.push(key);node=end(key);}
  (r.only?addOnly:addNo)(keys);
 }
 function visit(node,prefix) {
  if(!node.children.size)return; // completed shorter rule does not release other active longer rules
  const at=end(prefix.at(-1));
  for(let i=pack.nodeOffsets[at];i<pack.nodeOffsets[at+1];i++) {
   const key=outgoing(pack.edgeUndirectedIndex[i],at);
   if(!node.children.has(key))addNo([...prefix,key]);
  }
  for(const [key,child] of node.children)visit(child,[...prefix,key]);
 }
 for(const trie of only.values())visit(trie,[trie.first]);
 return [...no.values()].map(keys=>{
  const viaNodes=keys.slice(0,-1).map(end);for(let i=1;i<keys.length;i++)if(start(keys[i])!==viaNodes[i-1])throw Error('Noncontinuous restriction walk');
  return {keys,viaNodes};
 });
}
module.exports={compile};
