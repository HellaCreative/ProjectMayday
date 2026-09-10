"use strict";
// Overlap is measured on the actual packed edge. Two disjoint partial spans
// of one long edge are not a retrace. Endpoint geometry is never a free pass.
function overlaps(a,b) { return Math.min(a[1],b[1])-Math.max(a[0],b[0])>0.5; }
function containsRoadSpan(node, edge, span, previous, record) {
  let steps=0;
  while(node>=0) {
    const row=record(node);
    if(row && row.edge===edge && overlaps(row.span,span))return true;
    const next=previous(node);
    if(next===node || ++steps>10_000_000)return true;
    node=next;
  }
  return false;
}
function repeatedRoadSpan(rows) {
  const byEdge=new Map();
  for(const row of rows) {
    if(!row)continue;
    const spans=byEdge.get(row.edge)||[];
    if(spans.some(span=>overlaps(span,row.span)))return true;
    spans.push(row.span);byEdge.set(row.edge,spans);
  }
  return false;
}
module.exports={containsRoadSpan,repeatedRoadSpan};
