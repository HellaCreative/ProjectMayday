"use strict";

// Representative IANA zone for pack provenance. V4 currently fails every
// conditional access edge closed at runtime, so multi-zone regions never use
// this value to decide whether a road is open.
const REGION_TIMEZONE = {
  ab: "America/Edmonton", bc: "America/Vancouver", mb: "America/Winnipeg",
  nb: "America/Moncton", nl: "America/St_Johns", ns: "America/Halifax",
  nt: "America/Yellowknife", nu: "America/Iqaluit", on: "America/Toronto",
  pe: "America/Halifax", qc: "America/Toronto", sk: "America/Regina",
  yt: "America/Whitehorse",
  ak: "America/Anchorage", al: "America/Chicago", ar: "America/Chicago",
  az: "America/Phoenix", ca: "America/Los_Angeles", co: "America/Denver",
  ct: "America/New_York", de: "America/New_York", fl: "America/New_York",
  ga: "America/New_York", hi: "Pacific/Honolulu", ia: "America/Chicago",
  id: "America/Boise", il: "America/Chicago", in: "America/Indiana/Indianapolis",
  ks: "America/Chicago", ky: "America/New_York", la: "America/Chicago",
  ma: "America/New_York", md: "America/New_York", me: "America/New_York",
  mi: "America/Detroit", mn: "America/Chicago", mo: "America/Chicago",
  ms: "America/Chicago", mt: "America/Denver", nc: "America/New_York",
  nd: "America/Chicago", ne: "America/Chicago", nh: "America/New_York",
  nj: "America/New_York", nm: "America/Denver", nv: "America/Los_Angeles",
  ny: "America/New_York", oh: "America/New_York", ok: "America/Chicago",
  or: "America/Los_Angeles", pa: "America/New_York", ri: "America/New_York",
  sc: "America/New_York", sd: "America/Chicago", tn: "America/Chicago",
  tx: "America/Chicago", ut: "America/Denver", va: "America/New_York",
  vt: "America/New_York", wa: "America/Los_Angeles", wi: "America/Chicago",
  wv: "America/New_York", wy: "America/Denver"
};

function regionTimezone(regionId) {
  const id = String(regionId || "").toLowerCase();
  const timezone = REGION_TIMEZONE[id];
  if (!timezone) throw new Error(`no timezone for '${id}'`);
  return timezone;
}

function bufferProjection(regionId, country) {
  const id = String(regionId || "").toLowerCase();
  if (id === "ak") return 3338;
  if (id === "hi") return 3759;
  return country === "canada" ? 3347 : 5070;
}

module.exports = { REGION_TIMEZONE, regionTimezone, bufferProjection };
