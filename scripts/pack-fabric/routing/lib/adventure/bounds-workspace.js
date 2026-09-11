'use strict';
// Request-owned scratch for sequential objective searches. A bound must finish
// being consumed before the next acquire. Never use this for cached bounds.
function createBoundsWorkspace({maxBytes=128*1024*1024}={}) {
 if(!Number.isSafeInteger(maxBytes)||maxBytes<0)throw new TypeError('Finite workspace byte limit required');
 let storage=null;
 return {acquire(nodeCount){
  if(!Number.isSafeInteger(nodeCount)||nodeCount<0)throw new TypeError('Valid workspace size required');
  if(nodeCount*8>maxBytes)return null; // Bypass reuse, never omit graph nodes.
  if(!storage||storage.length<nodeCount)storage=new Float64Array(nodeCount);
  return storage.length===nodeCount?storage:storage.subarray(0,nodeCount);
 },diagnostics:()=>({residentBytes:storage?.byteLength||0,maxBytes})};
}
module.exports={createBoundsWorkspace};
