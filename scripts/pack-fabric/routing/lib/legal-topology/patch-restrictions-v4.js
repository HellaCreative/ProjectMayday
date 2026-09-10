"use strict";
const {decodeGraphV4}=require("../pack-v4");
function encodeRestriction(r) {
  if(r.viaWayIds.length!==r.viaEdges.length)throw new Error("Mismatched via path");
  const b=Buffer.alloc(32+12*r.viaEdges.length);
  b.writeBigInt64LE(BigInt(r.osmRelationId),0);b.writeUInt8(r.kind,8);b.writeUInt8(r.only?2:0,9);
  b.writeUInt16LE(r.viaEdges.length,10);b.writeUInt32LE(r.fromEdge,12);b.writeUInt32LE(r.toEdge,16);
  b.writeInt32LE(r.viaNode,20);b.writeUInt16LE(r.vehicleMask,26);b.writeInt32LE(-1,28);
  r.viaEdges.forEach((e,i)=>{b.writeBigInt64LE(BigInt(r.viaWayIds[i]),32+12*i);b.writeInt32LE(e,40+12*i);});
  return b;
}
function replaceSection(input,startField,endField,bytes) {
  const start=input.readUInt32LE(startField),end=input.readUInt32LE(endField),delta=bytes.length-(end-start);
  const out=Buffer.concat([input.subarray(0,start),bytes,input.subarray(end)]);
  for(let field=24;field<=136;field+=4) {
    const before=input.readUInt32LE(field);
    if(before>=end)out.writeUInt32LE(before+delta,field);
  }
  return out;
}
function patchRestrictionsV4(input,repairs,revision) {
  const byId=new Map(repairs.map(r=>[String(r.relation.id),r]));
  if(byId.size!==repairs.length||repairs.some(r=>r.error||!["resolved","quarantine"].includes(r.type)))throw new Error("Invalid correction set");
  const chunks=[],seen=new Set();let at=input.readUInt32LE(120),count=input.readUInt32LE(at),newCount=0;at+=4;
  for(let i=0;i<count;i++) {
    const length=32+12*input.readUInt16LE(at+10),id=input.readBigInt64LE(at).toString(),repair=byId.get(id);
    if(!repair){chunks.push(input.subarray(at,at+length));newCount++;}
    else if(!seen.has(id)) {
      seen.add(id);
      for(const row of repair.replacementRows||[]){chunks.push(encodeRestriction(row));newCount++;}
    }
    at+=length;
  }
  if(seen.size!==byId.size)throw new Error("Correction relation not present in graph");
  const head=Buffer.alloc(4);head.writeUInt32LE(newCount);
  let output=replaceSection(input,120,124,Buffer.concat([head,...chunks]));
  const access=output.readUInt32LE(112);
  for(const r of repairs)if(r.type==="quarantine")for(const row of r.excludedEdges) {
    for(let d=0;d<2;d++) {
      if(output[access+row.edge*2+d]!==row.priorAccess[d])throw new Error("Access precondition changed");
      output[access+row.edge*2+d]=2;
    }
  }
  const provenance=JSON.parse(output.subarray(output.readUInt32LE(128),output.readUInt32LE(132)));
  provenance.restrictionRevision=revision;
  output=replaceSection(output,128,132,Buffer.from(JSON.stringify(provenance)));
  const decoded=decodeGraphV4(output);
  if(decoded.restrictions.length!==newCount)throw new Error("Restriction round-trip failed");
  return output;
}
module.exports={patchRestrictionsV4};
