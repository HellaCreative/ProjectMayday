"use strict";
function regionalHopOwner(start, end, fallback) {
  const pair = p => Array.isArray(p.between) ? p.between.map(x => String(x).toLowerCase()) : [];
  const a = pair(start), b = pair(end);
  if (a.length && b.length) {
    const shared = [...new Set(a.filter(x => b.includes(x)))];
    if (shared.length !== 1) throw new Error("Regional seam pair has no unique shared pack");
    return shared[0];
  }
  const rider = a.length ? end : start;
  const owner = rider.resolvedRegionId || rider.regionIdHint || fallback;
  const seam = a.length ? a : b;
  if (seam.length && !seam.includes(owner)) throw new Error("Rider region does not meet the adjacent seam");
  return owner;
}
module.exports = { regionalHopOwner };
