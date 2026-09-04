"use strict";

/**
 * OSM administrative boundary relations for Dirt catalog regions.
 * Used to clip Geofabrik extracts to the real province/state and to own pins.
 */
const OSM_ADMIN_RELATION = {
  ab: 391186,
  bc: 390867,
  mb: 390841,
  nb: 68942,
  nl: 391196,
  ns: 390558,
  nt: 391220,
  nu: 390840,
  on: 68841,
  pe: 391115,
  qc: 61549,
  sk: 391178,
  yt: 391455,
  ak: 1116270,
  al: 161950,
  ar: 161646,
  az: 162018,
  ca: 165475,
  co: 161961,
  ct: 165794,
  de: 162110,
  fl: 162050,
  ga: 161957,
  hi: 166563,
  ia: 161650,
  id: 162116,
  il: 122586,
  in: 161816,
  ks: 161644,
  ky: 161655,
  la: 224922,
  ma: 61315,
  md: 162112,
  me: 63512,
  mi: 165789,
  mn: 165471,
  mo: 161638,
  ms: 161943,
  mt: 162115,
  nc: 224045,
  nd: 161653,
  ne: 161648,
  nh: 67213,
  nj: 224951,
  nm: 162014,
  nv: 165473,
  ny: 61320,
  oh: 162061,
  ok: 161645,
  or: 165476,
  pa: 162109,
  ri: 392915,
  sc: 224040,
  sd: 161652,
  tn: 161838,
  tx: 114690,
  ut: 161993,
  va: 224042,
  vt: 60769,
  wa: 165479,
  wi: 165466,
  wv: 162068,
  wy: 161991
};

function osmAdminRelation(regionId) {
  const id = String(regionId || "").toLowerCase();
  const relationId = OSM_ADMIN_RELATION[id];
  if (!relationId) {
    throw new Error(`no OSM admin relation for '${id}'`);
  }
  return relationId;
}

module.exports = {
  OSM_ADMIN_RELATION,
  osmAdminRelation
};
