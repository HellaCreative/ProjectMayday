"use strict";
function allows(pack, ei, from, to, allowUnknown, startEi = -1, endEi = -1) {
  const forward = pack.edgeFrom[ei] === from && pack.edgeTo[ei] === to;
  const code = pack.edgeAccess[ei * 2 + (forward ? 0 : 1)];
  return code === 0 || (code === 1 && !!allowUnknown)
    || ((code === 3 || code === 4) && (ei === startEi || ei === endEi));
}
module.exports = { allows };
